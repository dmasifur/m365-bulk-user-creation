---
name: Bug report
about: Something did not behave as documented
title: ''
labels: bug
assignees: ''
---

**What happened**

A clear description of the behaviour, and what you expected instead.

**Reproduction**

The command you ran, with any tenant-specific values redacted:

```powershell
./New-M365BulkUser.ps1 -CsvPath ./users.csv -WhatIf
```

A minimal CSV that triggers it, if the input is relevant. **Use example.com or
contoso.com — do not paste real UPNs, domains, or tenant IDs.**

**Run log**

The relevant rows from the run log CSV, redacted. Do not attach a credential report.

**Environment**

- PowerShell version: `$PSVersionTable.PSVersion`
- Microsoft Graph SDK version: `(Get-Module Microsoft.Graph.Authentication -ListAvailable).Version`
- OS:
