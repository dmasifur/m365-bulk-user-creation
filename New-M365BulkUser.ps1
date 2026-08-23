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
}

process {
}

end {
}
