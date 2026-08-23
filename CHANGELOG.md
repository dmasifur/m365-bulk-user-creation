# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-23

### Added

- Bulk user creation from a CSV or from piped objects, via Microsoft Graph.
- Read-only pre-flight phase that validates input and resolves every referenced
  license SKU, group, and manager before anything is written to the tenant.
- License assignment, group membership, and manager assignment, each isolated so
  one failure does not abandon the others.
- `-WhatIf` support that prints the fully resolved plan for each user.
- Exponential-backoff retry for throttled (`429`) and transient `5xx` Graph responses.
- Per-run CSV log recording every row's outcome, including `Partial` for accounts
  created but not fully configured.
- Optional credential report (`-CredentialReportPath`), written separately from the
  run log; passwords are never written to disk otherwise.
- Cryptographically random password generation with guaranteed complexity classes
  and ambiguous glyphs excluded.
- Per-run caching of SKU, group, and manager lookups.
- Pester suite for the tenant-free helpers, plus PSScriptAnalyzer and Pester in CI
  on Ubuntu and Windows.

### Fixed

- `Microsoft.Graph.Users.Actions` was missing from the module requirements, so
  licensing failed after accounts had already been created.
- Results were emitted to the pipeline twice — once as each row was processed and
  again from the `end` block — producing duplicates for any downstream consumer.

[Unreleased]: https://github.com/dmasifur/m365-bulk-user-creation/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dmasifur/m365-bulk-user-creation/releases/tag/v1.0.0
