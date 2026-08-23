#Requires -Version 7.2
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.5.0' }

<#
    Unit tests for the self-contained helpers inside New-M365BulkUser.ps1.

    The script cannot be dot-sourced: it has a param block and signs in to Graph
    in its begin block. Instead the helper function definitions are lifted out of
    the source with the PowerShell parser and loaded into a dynamic module, which
    gives them a real script scope for $script:Results to live in.

    Only helpers that need no tenant are covered. The resolvers (Resolve-SkuId,
    Resolve-GroupId, Resolve-ManagerId, Test-UserExists) are thin wrappers over
    Graph cmdlets and are verified against a test tenant, not here.
#>

BeforeAll {
    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'New-M365BulkUser.ps1')).Path

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$parseErrors)

    if ($parseErrors) {
        throw "New-M365BulkUser.ps1 failed to parse: $($parseErrors[0].Message)"
    }

    $wanted = @('Get-PropertyValue', 'New-RandomPassword', 'Add-Result', 'Invoke-GraphWithRetry')

    $definitions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true) | Where-Object { $wanted -contains $_.Name }

    $found = @($definitions.Name)
    foreach ($name in $wanted) {
        if ($found -notcontains $name) { throw "Helper '$name' was not found in the script." }
    }

    # $script:Results is state the script sets up in its begin block; the module
    # needs its own copy for Add-Result to append to.
    $moduleSource = @(
        '$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()'
        ($definitions.Extent.Text -join "`n`n")
    ) -join "`n`n"

    New-Module -Name M365BulkUserHelpers -ScriptBlock ([scriptblock]::Create($moduleSource)) |
        Import-Module -Force

    function Reset-ResultLog {
        & (Get-Module M365BulkUserHelpers) { $script:Results.Clear() }
    }

    function Get-ResultLog {
        & (Get-Module M365BulkUserHelpers) { , $script:Results.ToArray() }
    }
}

AfterAll {
    Remove-Module M365BulkUserHelpers -Force -ErrorAction SilentlyContinue
}

Describe 'Get-PropertyValue' {
    It 'returns the value of a populated property' {
        $row = [pscustomobject]@{ DisplayName = 'Ada Lovelace' }
        Get-PropertyValue -InputObject $row -Name 'DisplayName' | Should -Be 'Ada Lovelace'
    }

    It 'trims surrounding whitespace' {
        $row = [pscustomobject]@{ DisplayName = "  Ada Lovelace `t" }
        Get-PropertyValue -InputObject $row -Name 'DisplayName' | Should -Be 'Ada Lovelace'
    }

    It 'returns null when the property is absent' {
        $row = [pscustomobject]@{ DisplayName = 'Ada Lovelace' }
        Get-PropertyValue -InputObject $row -Name 'JobTitle' | Should -BeNullOrEmpty
    }

    It 'returns null for an empty value' {
        $row = [pscustomobject]@{ JobTitle = '' }
        Get-PropertyValue -InputObject $row -Name 'JobTitle' | Should -BeNullOrEmpty
    }

    It 'returns null for a whitespace-only value' {
        $row = [pscustomobject]@{ JobTitle = "   `t " }
        Get-PropertyValue -InputObject $row -Name 'JobTitle' | Should -BeNullOrEmpty
    }

    It 'treats an absent column and a blank cell identically' {
        $absent = Get-PropertyValue -InputObject ([pscustomobject]@{ A = 1 }) -Name 'Department'
        $blank  = Get-PropertyValue -InputObject ([pscustomobject]@{ Department = '  ' }) -Name 'Department'
        $absent | Should -Be $blank
    }
}

Describe 'New-RandomPassword' {
    It 'produces a password of the requested length' -ForEach @(12, 16, 32, 64) {
        (New-RandomPassword -Length $_).Length | Should -Be $_
    }

    It 'includes at least one character from every complexity class' {
        # Sampled rather than checked once: the guarantee must hold every time.
        foreach ($i in 1..100) {
            $password = New-RandomPassword -Length 12
            $password | Should -Match '[A-Z]'
            $password | Should -Match '[a-z]'
            $password | Should -Match '[0-9]'
            $password | Should -Match '[!@#$%^&*\-_=+?]'
        }
    }

    It 'excludes glyphs that are ambiguous when read aloud' {
        # Case matters here: 'l' and 'O' are excluded while 'L' and 'o' are not,
        # so the comparison has to be ordinal rather than -BeLike or -Match.
        $forbidden = '0', '1', 'I', 'O', 'l', 'o'
        $sample = -join (1..100 | ForEach-Object { New-RandomPassword -Length 32 })

        foreach ($char in $forbidden) {
            $sample.IndexOf($char, [System.StringComparison]::Ordinal) |
                Should -Be -1 -Because "'$char' is easily misheard"
        }
    }

    It 'keeps the unambiguous members of those glyph pairs' {
        # 'L' and 'i' are legible in print, and dropping them would shrink the
        # alphabet for no benefit.
        $sample = -join (1..200 | ForEach-Object { New-RandomPassword -Length 32 })
        $sample.IndexOf('L', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
        $sample.IndexOf('i', [System.StringComparison]::Ordinal) | Should -BeGreaterThan -1
    }

    It 'does not place the guaranteed class characters in a fixed order' {
        # Without the shuffle, every password would start upper/lower/digit/symbol.
        $firstFour = 1..50 | ForEach-Object { (New-RandomPassword -Length 16).Substring(0, 4) }
        ($firstFour | Where-Object { $_ -cmatch '^[A-Z][a-z][0-9]' }).Count | Should -BeLessThan 50
    }

    It 'does not repeat a password across many calls' {
        $passwords = 1..200 | ForEach-Object { New-RandomPassword -Length 16 }
        ($passwords | Select-Object -Unique).Count | Should -Be 200
    }

    It 'rejects a length outside the supported range' -ForEach @(11, 65) {
        { New-RandomPassword -Length $_ } | Should -Throw
    }
}

Describe 'Add-Result' {
    BeforeEach {
        Reset-ResultLog
    }

    It 'returns a record carrying every run-log column' {
        $record = Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Created' -Actions 'Created account'

        $record.UserPrincipalName | Should -Be 'ada@contoso.com'
        $record.Status            | Should -Be 'Created'
        $record.Actions           | Should -Be 'Created account'
        $record.Timestamp         | Should -Not -BeNullOrEmpty
        $record.PSObject.Properties.Name | Should -Contain 'Message'
    }

    It 'appends the record to the run log' {
        $null = Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Created'
        $null = Add-Result -UserPrincipalName 'alan@contoso.com' -Status 'Skipped'

        $log = Get-ResultLog
        $log.Count | Should -Be 2
        $log.UserPrincipalName | Should -Be @('ada@contoso.com', 'alan@contoso.com')
    }

    It 'flattens multiple actions into one semicolon-separated column' {
        $record = Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Created' `
            -Actions 'Created account', 'Licensed SPE_E3', 'Manager set'

        $record.Actions | Should -Be 'Created account; Licensed SPE_E3; Manager set'
    }

    It 'leaves Actions empty when none are supplied' {
        (Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Failed').Actions |
            Should -BeNullOrEmpty
    }

    It 'accepts every status the run log can report' -ForEach @('Created', 'Skipped', 'Failed', 'Partial', 'WhatIf') {
        { Add-Result -UserPrincipalName 'ada@contoso.com' -Status $_ } | Should -Not -Throw
    }

    It 'rejects a status outside the known set' {
        { Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Maybe' } | Should -Throw
    }

    It 'produces a sortable ISO-8601 timestamp' {
        (Add-Result -UserPrincipalName 'ada@contoso.com' -Status 'Created').Timestamp |
            Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
    }
}

Describe 'Invoke-GraphWithRetry' {
    BeforeAll {
        # The wrapped scriptblock runs in a child scope, so a plain counter
        # variable would be copied on write and stay at zero out here. A [ref]
        # is mutated rather than reassigned, so the count survives.
        function New-GraphError {
            param([System.Net.HttpStatusCode]$StatusCode)
            $response = [System.Net.Http.HttpResponseMessage]::new($StatusCode)
            [Microsoft.PowerShell.Commands.HttpResponseException]::new("$StatusCode", $response)
        }
    }

    It 'returns the value of the wrapped call' {
        Invoke-GraphWithRetry { 'result' } | Should -Be 'result'
    }

    It 'calls the wrapped scriptblock exactly once when it succeeds' {
        $calls = [ref]0
        Invoke-GraphWithRetry { $calls.Value++; 'ok' } | Should -Be 'ok'
        $calls.Value | Should -Be 1
    }

    It 'rethrows a non-transient failure without retrying' {
        $calls = [ref]0
        { Invoke-GraphWithRetry -MaxAttempts 4 -ScriptBlock { $calls.Value++; throw 'Insufficient privileges' } } |
            Should -Throw '*Insufficient privileges*'

        $calls.Value | Should -Be 1 -Because 'a permission error will not succeed on a retry'
    }

    It 'retries a throttling response and gives up after MaxAttempts' {
        $calls = [ref]0
        $throttled = {
            $calls.Value++
            throw (New-GraphError -StatusCode ([System.Net.HttpStatusCode]::TooManyRequests))
        }

        # MaxAttempts 2 keeps this to a single ~2 second backoff.
        { Invoke-GraphWithRetry -MaxAttempts 2 -ScriptBlock $throttled } | Should -Throw
        $calls.Value | Should -Be 2
    }

    It 'stops retrying as soon as the call succeeds' {
        $calls = [ref]0
        $flaky = {
            $calls.Value++
            if ($calls.Value -lt 2) {
                throw (New-GraphError -StatusCode ([System.Net.HttpStatusCode]::ServiceUnavailable))
            }
            'recovered'
        }

        Invoke-GraphWithRetry -MaxAttempts 4 -ScriptBlock $flaky | Should -Be 'recovered'
        $calls.Value | Should -Be 2
    }
}

Describe 'New-M365BulkUser.ps1' {
    BeforeAll {
        $script:sourcePath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'New-M365BulkUser.ps1')).Path
        $script:sourceText = Get-Content -LiteralPath $script:sourcePath -Raw
    }

    It 'parses without error' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:sourcePath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'declares every Graph module whose cmdlets it calls' -ForEach @(
        'Microsoft.Graph.Authentication'
        'Microsoft.Graph.Users'
        'Microsoft.Graph.Users.Actions'
        'Microsoft.Graph.Groups'
        'Microsoft.Graph.Identity.DirectoryManagement'
    ) {
        $script:sourceText | Should -BeLike "*ModuleName='$_'*"
    }

    It 'supports -WhatIf' {
        (Get-Command -Name $script:sourcePath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'exposes the documented parameters' -ForEach @(
        'CsvPath', 'InputObject', 'TenantId', 'PasswordLength',
        'LogPath', 'CredentialReportPath', 'SkipDomainCheck'
    ) {
        (Get-Command -Name $script:sourcePath).Parameters.Keys | Should -Contain $_
    }
}
