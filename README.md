# AWS S3 ingestion into Microsoft Sentinel GCC High

## Start with the Microsoft-package route

**[Commercial-package mirror: step-by-step product-group guide](PRODUCT-GROUP-PACKAGE-WALKTHROUGH.md)**

This route starts with Microsoft's actual commercial AWS S3 PowerShell ZIP,
preserves its files/provisioning functions, changes the government destination
identity constants, and executes the original interactive CloudTrail setup.
The missing GCC High connector UI is replaced by a native government ARM request.

**Live verified November 4, 2026:** the actual package-created path delivered
**25 CloudTrail events into a separate GCC High test workspace**. Latest saved
ingestion: **18:52:34 UTC**. The guide distinguishes this from the earlier
CloudFormation experiment and discloses the final console-pause handling.

The guide explains every prompt, what calls what, the exact source/hash and
changes, real errors/recovery, resource read-back, and isolated-workspace
verification. Customer identifiers and unredacted screenshots are not public.

### What the script does

[Invoke-AwsSentinelGcch.ps1](Invoke-AwsSentinelGcch.ps1) provides:

| Mode | Purpose |
|---|---|
| Inspect | Read government workspace/context and connector inventory |
| PrepareAws | Extract the pinned commercial ZIP and update active government constants; does not execute provisioning |
| Connect | Preflight actual AWS outputs and PUT/GET the native government connector |
| Verify | Require real account-filtered events from the government Logs API |

You still run Microsoft's `ConfigAwsConnector.ps1` interactively after PrepareAws.
The setup tools are not continuous log relays: CloudTrail, S3, SQS and Microsoft's
Sentinel collector continue working after the administrator closes the terminal.

**Scope: CloudTrail management events only.** Other AWS log types/tables are
not automatically enabled and are not covered by this live validation.
AWS GovCloud source preparation is locally tested, not live-certified here.

### Prerequisites

- PowerShell 7+, Azure CLI authenticated in AzureUSGovernment.
- AWS CLI v2 with approved temporary authentication and a saved profile region.
- Approved AWS provisioning, Sentinel connector and workspace-query permissions.
- Microsoft's commercial ZIP, downloaded separately using the guide and verified
  against its pinned SHA-256. It is not redistributed here.

[Fourteen regression tests](Tests/Test-AwsSentinelGcch.ps1) cover context guards,
errors, WhatIf, trust, duplicate consumers, idempotency, exact payload/read-back,
real-query shapes, and both commercial ZIP variants. They also hash every
non-constants file to detect unintentional provisioning-code changes.

## Earlier CloudFormation experiment

[Original CloudFormation + REST walkthrough](PRODUCT-GROUP-WALKTHROUGH.md)
and [parameterized reproduction template](cloudtrail-gcch-reproduction.yaml)
document a separate earlier experiment. Its verified CloudTrail events proved
native ingestion capability, **not execution of Microsoft's package**.
Do not mix that earlier evidence with the package-based validation.

## Important support boundary

The tested government backend uses **2025-10-01-preview**. Tested stable
versions rejected `AmazonWebServicesS3`. Working preview functionality does not
restore support to deprecated Content hub content or establish Microsoft
production support, all-table parity, exactly-once ingestion, or a service SLA.

Confirm production support and compliance authorization with Microsoft and your
organization. Do not share queues between workspaces, silently broaden trust,
reuse production resources for experiments, or publish credential caches.
