# New-M365BulkUser

[![CI](https://github.com/dmasifur/m365-bulk-user-creation/actions/workflows/ci.yml/badge.svg)](https://github.com/dmasifur/m365-bulk-user-creation/actions/workflows/ci.yml)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bulk-provisions Microsoft 365 users from a CSV via Microsoft Graph — creating the
account, assigning a license, adding group membership, and setting a manager — and
reports precisely what happened to every row.

The problem with most bulk-creation scripts is what they leave behind when they fail
halfway: some accounts created, some licensed, no record of which. This one resolves
every license SKU, group, and manager in a **read-only pre-flight pass** before it
writes anything, so a misspelled group name or an unlicensed SKU surfaces while the
tenant is still untouched. Combined with `-WhatIf`, that gives you a full dry run.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [CSV format](#csv-format)
- [Usage](#usage)
- [Output](#output)
- [Security notes](#security-notes)
- [Testing](#testing)
- [License](#license)

---

## How it works

Three phases, in order:

| Phase | Writes to tenant | What it does |
|---|---|---|
| **1. Pre-flight** | No | Validates required columns and UPN shape, checks the UPN suffix against the tenant's verified domains, skips accounts that already exist, and resolves every SKU part number, group display name, and manager UPN to an object ID. |
| **2. Provision** | Yes | Creates each account with a generated password, then applies usage location, license, groups, and manager. |
| **3. Report** | No | Writes a per-user run log, and optionally a separate credential report. |

Design decisions worth knowing:

- **Rows fail independently.** A bad row is recorded and skipped; the rest of the batch
  still runs. You are never left guessing which half went through.
- **Existing accounts are skipped, not modified.** Re-running after a partial failure is
  safe — it will not overwrite attributes on accounts that already exist.
- **Post-creation steps are isolated.** If licensing succeeds but a group add fails, the
  account is reported as `Partial` with the specific failure attached, rather than the
  whole thing rolling over into a generic error.
- **Throttling is handled.** Graph rate-limits bulk writes; `429` and transient `5xx`
  responses are retried with exponential backoff. Permission and validation errors are
  rethrown immediately instead of being retried pointlessly.
- **Lookups are cached.** A 500-row import sharing one SKU and a few groups makes a
  handful of Graph calls, not a few thousand.
- **Passwords are cryptographically random.** `RandomNumberGenerator`, one character
  guaranteed from each complexity class, then shuffled. Ambiguous glyphs (`0`/`O`,
  `1`/`l`/`I`) are excluded, because these get read aloud over the phone.

## Requirements

- **PowerShell 7.2** or later
- **Microsoft Graph PowerShell SDK 2.15.0** or later — these modules:
  `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`,
  `Microsoft.Graph.Users.Actions`, `Microsoft.Graph.Groups`,
  `Microsoft.Graph.Identity.DirectoryManagement`
- A signing-in account with **User Administrator** or higher (creating users and
  assigning licenses both require it)

Delegated scopes requested at sign-in:

| Scope | Used for |
|---|---|
| `User.ReadWrite.All` | Creating accounts, assigning licenses, setting the manager |
| `GroupMember.ReadWrite.All` | Adding group membership |
| `Organization.Read.All` | Reading subscribed SKUs and seat counts |
| `Directory.Read.All` | Resolving groups and verified domains |

## Quick start

```powershell
# Install the Graph modules (once)
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users,
               Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups,
               Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser

git clone https://github.com/dmasifur/m365-bulk-user-creation.git
cd m365-bulk-user-creation

# Dry run first — always
./New-M365BulkUser.ps1 -CsvPath ./samples/users.csv -WhatIf
```

## CSV format

Only `DisplayName` and `UserPrincipalName` are required. Every other column is optional
and simply skipped when blank — a blank cell never overwrites anything with an empty
string. See [samples/users.csv](samples/users.csv) for a working file.

| Column | Required | Notes |
|---|---|---|
| `DisplayName` | **Yes** | |
| `UserPrincipalName` | **Yes** | Suffix must be a verified domain unless `-SkipDomainCheck` |
| `MailNickname` | No | Defaults to the part of the UPN before `@` |
| `GivenName` | No | |
| `Surname` | No | |
| `JobTitle` | No | |
| `Department` | No | |
| `OfficeLocation` | No | |
| `MobilePhone` | No | |
| `CompanyName` | No | |
| `City` | No | |
| `Country` | No | Free text display value, distinct from `UsageLocation` |
| `UsageLocation` | Conditional | Two-letter ISO 3166-1 code. **Required if a license is assigned** |
| `LicenseSkuPartNumber` | No | e.g. `SPE_E3`, `ENTERPRISEPACK`. Must exist in the tenant |
| `Groups` | No | Semicolon-separated display names. Dynamic groups are rejected |
| `ManagerUserPrincipalName` | No | Must already exist in the tenant |

To find the SKU part numbers available in your tenant:

```powershell
Connect-MgGraph -Scopes Organization.Read.All
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits,
    @{ n = 'Enabled'; e = { $_.PrepaidUnits.Enabled } }
```

## Usage

**Dry run.** Runs the full pre-flight pass and prints exactly what each user would get,
without writing anything:

```powershell
./New-M365BulkUser.ps1 -CsvPath ./users.csv -WhatIf
```

**Real run, with a credential report:**

```powershell
./New-M365BulkUser.ps1 -CsvPath ./users.csv -CredentialReportPath ./creds.csv -Verbose
```

**Straight from objects, no CSV:**

```powershell
Import-Csv ./hr-export.csv |
    Where-Object StartDate -le (Get-Date) |
    ./New-M365BulkUser.ps1
```

**Against a specific tenant** (needed when your account is a guest in several):

```powershell
./New-M365BulkUser.ps1 -CsvPath ./users.csv -TenantId contoso.onmicrosoft.com
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-CsvPath` | — | Input CSV path |
| `-InputObject` | — | User objects instead of a CSV; accepts pipeline input |
| `-TenantId` | Default tenant | Tenant ID or verified domain to sign in against |
| `-PasswordLength` | `16` | Generated password length (12–64) |
| `-LogPath` | `./BulkUserCreate_<timestamp>.csv` | Run log destination |
| `-CredentialReportPath` | *(none)* | Write generated passwords here. Omit and they never touch disk |
| `-SkipDomainCheck` | Off | Skip UPN suffix validation against verified domains |
| `-WhatIf` / `-Confirm` | — | Standard `ShouldProcess` support |

## Output

The run log records one row per input row, whatever the outcome:

| Column | Description |
|---|---|
| `Timestamp` | ISO-8601, sortable |
| `UserPrincipalName` | The UPN, or `row N` if the row had no usable UPN |
| `Status` | `Created`, `Skipped`, `Failed`, `Partial`, or `WhatIf` |
| `Actions` | What actually succeeded, semicolon-separated |
| `Message` | Failure detail, where there is one |

`Partial` is the status worth watching: the account exists but at least one of license,
groups, or manager did not apply. Those rows need a targeted fix, not a re-run.

The same records are returned as objects, so you can pipe them:

```powershell
$results = ./New-M365BulkUser.ps1 -CsvPath ./users.csv
$results | Where-Object Status -in 'Failed', 'Partial' | Format-Table
```

## Security notes

- **Passwords stay in memory by default.** They are only written to disk when you pass
  `-CredentialReportPath`, and then to a file separate from the run log — so the run log
  can be shared freely.
- **The credential report is a secret.** Distribute over a secure channel and delete it
  once passwords are handed over. `.gitignore` excludes `*creds*.csv` and
  `BulkUserCreate_*.csv` so neither can be committed by accident.
- **Every account is created with `ForceChangePasswordNextSignIn`**, so a generated
  password is only ever a one-time value.
- **No credentials are stored by the script.** Authentication is delegated to
  `Connect-MgGraph`, which handles the interactive sign-in and token cache.
- Group display names are escaped before going into the OData filter.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
```

The suite covers the helpers that need no tenant: password complexity and glyph
exclusion (asserted over many samples, since a one-shot check cannot catch a broken
guarantee), CSV value normalisation, the run-log record shape, and the retry predicate.

The Graph resolvers are deliberately **not** mocked. Mocking `Get-MgGroup` would test the
mock rather than the behaviour; those paths are verified against a test tenant. CI runs
the suite plus PSScriptAnalyzer on Ubuntu and Windows.

## License

[MIT](LICENSE)
