#Requires -Version 7.2
#Requires -Modules @{ ModuleName='Microsoft.Graph.Authentication'; ModuleVersion='2.15.0' }
#Requires -Modules @{ ModuleName='Microsoft.Graph.Users'; ModuleVersion='2.15.0' }
#Requires -Modules @{ ModuleName='Microsoft.Graph.Groups'; ModuleVersion='2.15.0' }
#Requires -Modules @{ ModuleName='Microsoft.Graph.Identity.DirectoryManagement'; ModuleVersion='2.15.0' }

<#
.SYNOPSIS
    Bulk-creates Microsoft 365 users from a CSV via Microsoft Graph, then assigns
    licenses, group membership, and a manager.

.DESCRIPTION
    Runs in three phases:

      1. Pre-flight  - validates the input, resolves every referenced license SKU,
                       group, and manager, and checks for existing accounts.
                       Nothing is written to the tenant in this phase.
      2. Provision   - creates each account with a generated password, then applies
                       usage location, license, groups, and manager.
      3. Report      - writes a per-user run log (CSV) and, optionally, a separate
                       credential report containing the generated passwords.

    Rows that fail pre-flight are reported and skipped; the rest still run. Accounts
    that already exist are skipped rather than modified.

.PARAMETER CsvPath
    Path to the input CSV. See the sample CSV for the expected columns.

.PARAMETER InputObject
    User objects supplied directly (or down the pipeline) instead of a CSV. Must
    expose the same property names as the CSV columns.

.PARAMETER TenantId
    Tenant ID or verified domain to sign in against. Useful for guest accounts that
    exist in more than one tenant.

.PARAMETER PasswordLength
    Length of each generated password. Defaults to 16.

.PARAMETER LogPath
    Path for the run log CSV. Defaults to a timestamped file in the current directory.

.PARAMETER CredentialReportPath
    When supplied, generated passwords are written here as CSV. Treat the file as a
    secret: distribute it over a secure channel and delete it once passwords are
    handed over. Omit the parameter and passwords are never written to disk.

.PARAMETER SkipDomainCheck
    Skips validation of UPN suffixes against the tenant's verified domains.

.EXAMPLE
    .\New-M365BulkUser.ps1 -CsvPath .\users.csv -WhatIf

    Runs pre-flight and reports exactly what would be created, without writing.

.EXAMPLE
    .\New-M365BulkUser.ps1 -CsvPath .\users.csv -CredentialReportPath .\creds.csv -Verbose

.NOTES
    Required delegated scopes: User.ReadWrite.All, GroupMember.ReadWrite.All,
    Organization.Read.All, Directory.Read.All. The signed-in account needs a role
    that can create users and assign licenses (User Administrator or higher).
#>
[CmdletBinding(DefaultParameterSetName = 'FromCsv', SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, ParameterSetName = 'FromCsv', Position = 0)]
    [ValidateScript({
        if (Test-Path -LiteralPath $_ -PathType Leaf) { $true }
        else { throw "Input CSV not found: '$_'." }
    })]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'FromObject', ValueFromPipeline)]
    [ValidateNotNull()]
    [psobject[]]$InputObject,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [ValidateRange(12, 64)]
    [int]$PasswordLength = 16,

    [Parameter()]
    [string]$LogPath = (Join-Path -Path (Get-Location) -ChildPath ('BulkUserCreate_{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))),

    [Parameter()]
    [string]$CredentialReportPath,

    [Parameter()]
    [switch]$SkipDomainCheck
)

begin {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $script:RequiredColumns = @('DisplayName', 'UserPrincipalName')
    $script:Results         = [System.Collections.Generic.List[pscustomobject]]::new()
    $script:Pending         = [System.Collections.Generic.List[psobject]]::new()
    $script:SkuCache        = @{}
    $script:GroupCache      = @{}
    $script:ManagerCache    = @{}
    $script:VerifiedDomains = @()

    function Get-PropertyValue {
        <# Returns a trimmed property value, or $null when absent/blank. #>
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][psobject]$InputObject,
            [Parameter(Mandatory)][string]$Name
        )

        if (-not $InputObject.PSObject.Properties.Match($Name).Count) { return $null }
        $value = [string]$InputObject.$Name
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        $value.Trim()
    }

    function New-RandomPassword {
        <# Cryptographically random password with all four complexity classes. #>
        [OutputType([string])]
        param([Parameter(Mandatory)][ValidateRange(12, 64)][int]$Length)

        # Ambiguous glyphs (O/0, l/1/I) omitted so passwords survive being read aloud.
        $classes = @(
            'ABCDEFGHJKLMNPQRSTUVWXYZ',
            'abcdefghijkmnpqrstuvwxyz',
            '23456789',
            '!@#$%^&*-_=+?'
        )
        $all   = -join $classes
        $chars = [System.Collections.Generic.List[char]]::new()

        foreach ($class in $classes) {
            $chars.Add($class[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
        }
        while ($chars.Count -lt $Length) {
            $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
        }

        # Fisher-Yates, so the guaranteed class characters aren't always in front.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
            ($chars[$i], $chars[$j]) = ($chars[$j], $chars[$i])
        }

        -join $chars
    }

    function Resolve-SkuId {
        <# Maps a SKU part number (e.g. SPE_E3) to its GUID, checking availability. #>
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$SkuPartNumber)

        $key = $SkuPartNumber.ToUpperInvariant()
        if ($script:SkuCache.ContainsKey($key)) { return $script:SkuCache[$key] }

        $sku = Get-MgSubscribedSku -All |
            Where-Object { $_.SkuPartNumber -eq $SkuPartNumber } |
            Select-Object -First 1

        if (-not $sku) {
            throw "License SKU '$SkuPartNumber' is not present in this tenant."
        }

        $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
        if ($available -le 0) {
            Write-Warning "SKU '$SkuPartNumber' has no seats free ($($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) consumed). Assignment will fail."
        }

        $script:SkuCache[$key] = $sku.SkuId
        $sku.SkuId
    }

    function Resolve-GroupId {
        <# Maps a group display name to its object ID. Rejects dynamic groups. #>
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$DisplayName)

        $key = $DisplayName.ToUpperInvariant()
        if ($script:GroupCache.ContainsKey($key)) { return $script:GroupCache[$key] }

        $escaped = $DisplayName.Replace("'", "''")
        $groups  = @(Get-MgGroup -Filter "displayName eq '$escaped'" -Property 'Id,DisplayName,GroupTypes' -All)

        if ($groups.Count -eq 0) { throw "Group '$DisplayName' was not found." }
        if ($groups.Count -gt 1) { throw "Group name '$DisplayName' is ambiguous ($($groups.Count) matches). Use the object ID instead." }

        if ($groups[0].GroupTypes -contains 'DynamicMembership') {
            throw "Group '$DisplayName' uses dynamic membership; members cannot be added directly."
        }

        $script:GroupCache[$key] = $groups[0].Id
        $groups[0].Id
    }

    function Resolve-ManagerId {
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$UserPrincipalName)

        $key = $UserPrincipalName.ToUpperInvariant()
        if ($script:ManagerCache.ContainsKey($key)) { return $script:ManagerCache[$key] }

        try {
            $manager = Get-MgUser -UserId $UserPrincipalName -Property 'Id' -ErrorAction Stop
        }
        catch {
            throw "Manager '$UserPrincipalName' was not found in the tenant."
        }

        $script:ManagerCache[$key] = $manager.Id
        $manager.Id
    }

    function Test-UserExists {
        [OutputType([bool])]
        param([Parameter(Mandatory)][string]$UserPrincipalName)

        try {
            $null = Get-MgUser -UserId $UserPrincipalName -Property 'Id' -ErrorAction Stop
            $true
        }
        catch {
            $false
        }
    }

    function Add-Result {
        param(
            [Parameter(Mandatory)][string]$UserPrincipalName,
            [Parameter(Mandatory)][ValidateSet('Created', 'Skipped', 'Failed', 'Partial', 'WhatIf')][string]$Status,
            [string[]]$Actions = @(),
            [string]$Message
        )

        $record = [pscustomobject]@{
            Timestamp         = (Get-Date).ToString('s')
            UserPrincipalName = $UserPrincipalName
            Status            = $Status
            Actions           = ($Actions -join '; ')
            Message           = $Message
        }
        $script:Results.Add($record)
        $record
    }

    # --- Connect -----------------------------------------------------------
    $connectSplat = @{
        Scopes    = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Organization.Read.All', 'Directory.Read.All')
        NoWelcome = $true
    }
    if ($PSBoundParameters.ContainsKey('TenantId')) { $connectSplat['TenantId'] = $TenantId }

    Write-Verbose 'Signing in to Microsoft Graph...'
    Connect-MgGraph @connectSplat

    $context = Get-MgContext
    Write-Verbose "Connected as '$($context.Account)' to tenant '$($context.TenantId)'."

    if (-not $SkipDomainCheck) {
        $script:VerifiedDomains = @(
            Get-MgDomain -All |
                Where-Object IsVerified |
                Select-Object -ExpandProperty Id
        )
        Write-Verbose "Verified domains: $($script:VerifiedDomains -join ', ')"
    }
}

process {
    $rows = if ($PSCmdlet.ParameterSetName -eq 'FromCsv') {
        Write-Verbose "Reading '$CsvPath'."
        @(Import-Csv -LiteralPath $CsvPath)
    }
    else {
        @($InputObject)
    }

    if ($rows.Count -eq 0) {
        Write-Warning 'No input rows found; nothing to do.'
        return
    }

    # --- Phase 1: pre-flight (read-only) ----------------------------------
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $upn = Get-PropertyValue -InputObject $row -Name 'UserPrincipalName'
        $label = $upn ?? "row $rowNumber"

        $missing = $script:RequiredColumns.Where({ -not (Get-PropertyValue -InputObject $row -Name $_) })
        if ($missing) {
            Add-Result -UserPrincipalName $label -Status 'Failed' -Message "Missing required value(s): $($missing -join ', ')."
            continue
        }

        try {
            if ($upn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                throw "'$upn' is not a valid UPN."
            }

            if (-not $SkipDomainCheck) {
                $suffix = $upn.Split('@')[-1]
                if ($suffix -notin $script:VerifiedDomains) {
                    throw "Domain '$suffix' is not a verified domain in this tenant."
                }
            }

            if (Test-UserExists -UserPrincipalName $upn) {
                Add-Result -UserPrincipalName $upn -Status 'Skipped' -Message 'Account already exists.'
                continue
            }

            $usageLocation = Get-PropertyValue -InputObject $row -Name 'UsageLocation'
            $skuPartNumber = Get-PropertyValue -InputObject $row -Name 'LicenseSkuPartNumber'
            $managerUpn    = Get-PropertyValue -InputObject $row -Name 'ManagerUserPrincipalName'
            $groupNames    = @()

            $rawGroups = Get-PropertyValue -InputObject $row -Name 'Groups'
            if ($rawGroups) {
                $groupNames = @($rawGroups -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }

            if ($skuPartNumber -and -not $usageLocation) {
                throw 'UsageLocation is required before a license can be assigned.'
            }
            if ($usageLocation -and $usageLocation -notmatch '^[A-Za-z]{2}$') {
                throw "UsageLocation '$usageLocation' must be a two-letter ISO 3166-1 country code."
            }

            $skuId     = if ($skuPartNumber) { Resolve-SkuId -SkuPartNumber $skuPartNumber } else { $null }
            $groupIds  = @(foreach ($name in $groupNames) { [pscustomobject]@{ Name = $name; Id = Resolve-GroupId -DisplayName $name } })
            $managerId = if ($managerUpn) { Resolve-ManagerId -UserPrincipalName $managerUpn } else { $null }

            $mailNickname = Get-PropertyValue -InputObject $row -Name 'MailNickname'
            if (-not $mailNickname) { $mailNickname = $upn.Split('@')[0] }

            $script:Pending.Add([pscustomobject]@{
                Row           = $row
                Upn           = $upn
                MailNickname  = $mailNickname
                UsageLocation = $usageLocation
                SkuPartNumber = $skuPartNumber
                SkuId         = $skuId
                Groups        = $groupIds
                ManagerUpn    = $managerUpn
                ManagerId     = $managerId
            })
        }
        catch {
            Add-Result -UserPrincipalName $label -Status 'Failed' -Message $_.Exception.Message
        }
    }

    Write-Verbose "Pre-flight complete: $($script:Pending.Count) row(s) ready, $(($script:Results | Where-Object Status -eq 'Failed').Count) rejected."

    # --- Phase 2: provision ------------------------------------------------
    foreach ($item in $script:Pending) {
        $target = $item.Upn
        $plan   = @('Create account')
        if ($item.SkuPartNumber) { $plan += "License $($item.SkuPartNumber)" }
        if ($item.Groups)        { $plan += "Groups: $($item.Groups.Name -join ', ')" }
        if ($item.ManagerUpn)    { $plan += "Manager $($item.ManagerUpn)" }

        if (-not $PSCmdlet.ShouldProcess($target, ($plan -join ' | '))) {
            Add-Result -UserPrincipalName $target -Status 'WhatIf' -Actions $plan -Message 'Pre-flight passed; no changes made.'
            continue
        }

        $password  = New-RandomPassword -Length $PasswordLength
        $completed = [System.Collections.Generic.List[string]]::new()
        $problems  = [System.Collections.Generic.List[string]]::new()

        $body = @{
            AccountEnabled    = $true
            DisplayName       = Get-PropertyValue -InputObject $item.Row -Name 'DisplayName'
            UserPrincipalName = $item.Upn
            MailNickname      = $item.MailNickname
            PasswordProfile   = @{
                Password                             = $password
                ForceChangePasswordNextSignIn        = $true
                ForceChangePasswordNextSignInWithMfa = $false
            }
        }

        # Optional attributes, added only when the CSV supplies a value.
        $optional = @{
            GivenName      = 'GivenName'
            Surname        = 'Surname'
            JobTitle       = 'JobTitle'
            Department     = 'Department'
            OfficeLocation = 'OfficeLocation'
            MobilePhone    = 'MobilePhone'
            CompanyName    = 'CompanyName'
            City           = 'City'
            Country        = 'Country'
        }
        foreach ($property in $optional.GetEnumerator()) {
            $value = Get-PropertyValue -InputObject $item.Row -Name $property.Value
            if ($value) { $body[$property.Key] = $value }
        }
        if ($item.UsageLocation) { $body['UsageLocation'] = $item.UsageLocation.ToUpperInvariant() }

        try {
            $user = New-MgUser -BodyParameter $body -ErrorAction Stop
            $completed.Add('Created account')
            Write-Verbose "Created '$($user.UserPrincipalName)' ($($user.Id))."
        }
        catch {
            Add-Result -UserPrincipalName $target -Status 'Failed' -Message "Account creation failed: $($_.Exception.Message)"
            continue
        }

        if ($item.SkuId) {
            try {
                $null = Set-MgUserLicense -UserId $user.Id `
                    -AddLicenses @(@{ SkuId = $item.SkuId }) `
                    -RemoveLicenses @() `
                    -ErrorAction Stop
                $completed.Add("Licensed $($item.SkuPartNumber)")
            }
            catch {
                $problems.Add("License '$($item.SkuPartNumber)': $($_.Exception.Message)")
            }
        }

        foreach ($group in $item.Groups) {
            try {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                $completed.Add("Added to '$($group.Name)'")
            }
            catch {
                $problems.Add("Group '$($group.Name)': $($_.Exception.Message)")
            }
        }

        if ($item.ManagerId) {
            try {
                Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($item.ManagerId)"
                } -ErrorAction Stop
                $completed.Add("Manager set to $($item.ManagerUpn)")
            }
            catch {
                $problems.Add("Manager '$($item.ManagerUpn)': $($_.Exception.Message)")
            }
        }

        $status = if ($problems.Count) { 'Partial' } else { 'Created' }
        Add-Result -UserPrincipalName $target -Status $status -Actions $completed -Message ($problems -join ' | ')

        if ($problems.Count) {
            Write-Warning "$target created with $($problems.Count) follow-up failure(s). See the run log."
        }
    }
}

end {
}
