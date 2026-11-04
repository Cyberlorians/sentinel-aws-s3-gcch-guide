# Deploy AWS CloudTrail to Microsoft Sentinel GCC High

**Start here for a new deployment. Follow Steps 1-8 in order.**
This is the single deployment path in this repository; you do not need to
follow the investigation documents or deploy a CloudFormation template.

**Scope:** AWS **commercial**, region **us-east-1**, to a Sentinel-enabled
**Azure Government / GCC High workspace**, destination table **AWSCloudTrail**.
This procedure enables CloudTrail **management events only**.

**Before approval:** this uses the tested `2025-10-01-preview` connector API.
It does not restore a deprecated Content hub solution or establish Microsoft
production support. Confirm support, data-transfer authorization and billing
with your organization/Microsoft before deploying. Another management-event
trail can incur duplicate-copy charges, plus S3, SQS and Sentinel charges.

**Already deployed? Do not create the AWS resources again.** To check an
existing deployment, use its government target in Step 3 and run Step 8.
The AWS sign-in in Step 4 is not needed for that read-only ingestion check.

## What you actually run

There are **two entry-point scripts**, not one unattended installer:

| Script | When you use it |
|---|---|
| [Invoke-AwsSentinelGcch.ps1](Invoke-AwsSentinelGcch.ps1), supplied here | Check the target; prepare Microsoft's package; register the connector; verify data |
| `ConfigAwsConnector.ps1`, downloaded from Microsoft in Step 5 | Run once interactively to create the AWS resources |

```text
Prepare package -> run Microsoft's AWS setup -> connect to GCC High -> verify data
```

Microsoft's package contains helper files. **Do not launch those files one by
one, edit the government constants manually, or run the other log-type scripts.**
The two entry points above handle that. No Content hub installation is required
for this path.

## 1. Download this repository and open PowerShell 7

1. On this GitHub page, select **Code -> Download ZIP**.
2. Extract it under `C:\tools\awssentinel`.
3. Open **PowerShell 7**, not Windows PowerShell 5.1.
4. Change to the extracted folder containing `Invoke-AwsSentinelGcch.ps1`.
   With the default ZIP folder name:

```powershell
Set-Location 'C:\tools\awssentinel\sentinel-aws-s3-gcch-guide-main'
$ErrorActionPreference = 'Stop'
$setupFolder = (Get-Location).Path
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Open PowerShell 7.' }
if (-not (Test-Path -LiteralPath '.\Invoke-AwsSentinelGcch.ps1')) {
    throw 'Open the extracted repository folder before continuing.'
}
```

**Keep this PowerShell window open for all remaining steps.** The commands
reuse variables from earlier steps. If you extract elsewhere, adjust only
the `Set-Location` path.

Install these first if missing:
[PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows),
[Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows),
and [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
The browser-login command below needs AWS CLI **2.32.0+**; the live test used
**2.39.3**. Browser sign-in alone does not authenticate either CLI.

## 2. Choose the government workspace

1. Sign in to <https://portal.azure.us/>.
2. Open **Log Analytics workspaces**. For a clean validation, create a
   dedicated workspace in an approved government region; the test used
   **US Gov Virginia**.
3. Open **Microsoft Sentinel** and add/enable that workspace. Review billing.
4. Record the **subscription ID**, **resource group** and **workspace name**.
5. In **Microsoft Entra ID -> Overview**, record the **tenant ID**.

Use an account permitted to read the workspace/onboarding/provider information,
read/create Sentinel data connectors, and query workspace logs. The helper does
not create the workspace or enable Sentinel for you.

Do not use a workspace already ingesting the same AWS account's CloudTrail data
to prove a new connection: old data could make the new connection look healthy.

## 3. Sign in to Azure Government and check the target

Enter your organization's values when prompted:

```powershell
az cloud set --name AzureUSGovernment
if ($LASTEXITCODE -ne 0) { throw 'Cannot select Azure Government.' }
$tenantId = Read-Host 'Government tenant ID'
az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure Government login failed.' }

$target = @{
    TenantId       = $tenantId
    SubscriptionId = Read-Host 'Government subscription ID'
    ResourceGroup  = Read-Host 'Workspace resource group'
    WorkspaceName  = Read-Host 'Workspace name'
}
$inspection = .\Invoke-AwsSentinelGcch.ps1 @target -Mode Inspect
$inspection | Format-List Cloud, Workspace, WorkspaceId, Location, ApiVersion
$workspaceId = $inspection.WorkspaceId
```

**Stop and check:** Cloud must be `AzureUSGovernment`, and the workspace must
be the one you selected. Copy the printed **WorkspaceId** for Step 6.
It is the workspace **customer ID**, not the tenant ID or subscription ID.
If Inspect fails, resolve that error before proceeding.

## 4. Sign in to the AWS source account

Open <https://console.aws.amazon.com/> and confirm the intended account.
Use approved IAM/federated administration with provisioning permissions for
IAM, S3, SQS and CloudTrail, plus the package's EC2 region check. Use a dedicated
CLI profile and temporary credentials, not root or new long-lived access keys.

This procedure uses AWS CLI browser login. If your organization requires
another temporary sign-in method, replace only the `aws login` command below
with its approved profile sign-in command. Keep the identity/region checks.

```powershell
$awsTarget = @{
    AwsPartition = 'aws'
    AwsAccountId = Read-Host 'AWS source account ID (12 digits)'
    AwsRegion    = 'us-east-1'
}
$awsProfile = Read-Host 'Dedicated AWS CLI profile name'
aws login --profile $awsProfile --region $awsTarget.AwsRegion
if ($LASTEXITCODE -ne 0) { throw 'AWS CLI login failed.' }
aws configure set region $awsTarget.AwsRegion --profile $awsProfile
if ($LASTEXITCODE -ne 0) { throw 'Cannot save AWS profile region.' }

$env:AWS_PROFILE = $awsProfile
$env:AWS_REGION = $awsTarget.AwsRegion
$env:AWS_DEFAULT_REGION = $awsTarget.AwsRegion
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'

$identityText = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) { throw 'AWS CLI authentication failed.' }
$identity = $identityText | ConvertFrom-Json
if ($identity.Account -ne $awsTarget.AwsAccountId) { throw 'Wrong AWS account.' }
if ($identity.Arn -like 'arn:aws:iam::*:root') {
    throw 'Use an approved IAM/federated administrator, not root.'
}
$savedRegion = aws configure get region --profile $awsProfile
if ($LASTEXITCODE -ne 0 -or $savedRegion -ne 'us-east-1') {
    throw 'The upstream script requires us-east-1 saved on this CLI profile.'
}
$identity | Format-List Account, Arn
```

**Stop and check:** the printed account/identity must be authorized for this
deployment. Keep `aws login` running until browser approval/callback finishes.
Do not reuse an old callback URL. The saved profile region is required even
when the environment variables are set.

## 5. Download and prepare Microsoft's commercial package

This step changes **local files only**. It does not create AWS resources.

```powershell
$zip = Join-Path $setupFolder 'ConfigAwsS3DataConnectorScripts.zip'
if (-not (Test-Path -LiteralPath $zip)) {
    Invoke-WebRequest `
      -Uri 'https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/DataConnectors/AWS-S3/ConfigAwsS3DataConnectorScripts.zip' `
      -OutFile $zip
}
$expected = '0586346CA75A79F04E59AFAD778499F50F1C1383A4672A3405CB3E132DC2377F'
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
    throw 'Microsoft package differs from the reviewed version. Stop for review.'
}
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget -Mode PrepareAws
```

**Expected:** a new `prepared-aws-to-gcch` folder beside the helper.
It contains the complete Microsoft package, with the government destination
identity constants set for you. Provisioning functions are unchanged.

If that folder already exists, preparation stops rather than overwriting it.
Do not delete/recreate resources or rerun AWS setup merely to clear that error;
first establish whether this deployment was already completed.

## 6. Run Microsoft's AWS setup once

**This is the AWS write step.** Choose **new dedicated** role, bucket, standard
SQS queue, notification and trail names. Check IAM, S3, SQS and CloudTrail in
the AWS console to ensure they are not existing production resources. An
access-denied response is not proof that a resource is absent.

```powershell
Write-Host "Workspace customer ID to enter: $workspaceId"
Push-Location (Join-Path $setupFolder 'prepared-aws-to-gcch')
try {
    .\ConfigAwsConnector.ps1 -AwsLogType CloudTrail
}
finally {
    Pop-Location
}
```

Answer the prompts as follows; substitute only your new resource names:

| Prompt | Answer |
|---|---|
| Role name | Your new role name beginning `OIDC_` |
| Azure Sentinel External ID / Workspace ID | **WorkspaceId printed in Step 3** |
| S3 bucket name | Your new globally unique bucket name |
| Create missing bucket | `y`, only after checking account/name/absence |
| SQS name | Your new standard queue name, not FIFO |
| Enable KMS for CloudTrail | `n` for this tested procedure |
| Enable trail/policy for all organization accounts | `n` |
| Notification name | Your new notification name |
| Override the default notification prefix | `n` |
| CloudTrail name | Your new dedicated trail name |
| Enable CloudTrail data events | `n` |
| Multi-region trail | `y` |
| Press any key | Press a key in the interactive console |

**Do not close the window. Copy the final role ARN and SQS URL.** You need
both in Step 7. A finished prompt alone does not establish successful setup.
If errors occurred, stop and inspect them before continuing.

In the AWS console, confirm:

- **IAM -> role -> Trust relationships:** government audience and
  `MicrosoftSentinel_<your-workspace-customer-ID>` session binding.
- **S3 -> bucket -> Properties -> Event notifications:** your dedicated
  queue, `AWSLogs/<your-account-ID>/CloudTrail/` prefix and `.gz` suffix.
- **CloudTrail -> trail:** Logging, correct bucket, multi-region Yes, then
  successful **Last log file delivered**. Delivery may not be immediate.

Do not receive, delete or purge queue messages while checking the setup.
The tested package defaults leave CloudTrail log file validation disabled
and optional SSE-KMS off; review integrity/encryption requirements before
production use rather than silently treating these defaults as hardened.

## 7. Connect those AWS outputs to GCC High

**This is the government connector write step.** Run it back in the repository
folder, not inside `prepared-aws-to-gcch`. The Step 6 block returns you there.

First enter the **actual outputs** and run the read-only preview:

```powershell
$connection = @{
    RoleArn    = Read-Host 'Exact role ARN printed by Microsoft setup'
    SqsUrl     = Read-Host 'Exact SQS URL printed by Microsoft setup'
    AwsProfile = $awsProfile
}
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect -WhatIf
```

**Stop and check:** the preview must pass its AWS trust/queue checks and target
the intended government workspace. `WhatIf` does **not** create a connector.
If everything matches, run:

```powershell
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect
```

**Expected:** `Backend connector saved: <ID>` and request/response JSON files
beside the helper. An identical existing connector may instead report that it
already exists. Neither message proves ingestion; continue to Step 8.

Do not create another queue/connector when a request times out. Inspect the
existing state first using Inspect and the
[timeout recovery explanation](PRODUCT-GROUP-PACKAGE-WALKTHROUGH.md#10-register-those-actual-outputs-in-government-sentinel).
Do not share this queue with another workspace.

## 8. Verify real ingestion

Wait for CloudTrail file delivery, then run:

```powershell
.\Invoke-AwsSentinelGcch.ps1 @target -Mode Verify `
  -AwsAccountId (Read-Host 'AWS source account ID (12 digits)') `
  -LookbackHours 2 | ConvertTo-Json -Depth 30
```

**Success means actual rows plus a newly saved `gcch-ingestion-evidence.json`.**
That file contains the exact workspace customer ID, executed query, UTC
verification time and results. Sum the `Events` column: grouped rows are not
individual event counts. An old evidence file from a previous run is not proof
that a failed current check succeeded.

Enter the same AWS source account ID used in Step 4. For an existing deployment
where you skipped Step 4, enter that deployment's source account ID.

An empty result/error means **not verified**. Do not redeploy to fix an
initial empty query. Check source delivery, wait a few minutes, and rerun only
Verify. The live test needed eight checks before returning real events; that
is an observation, not an ingestion SLA.

You can also query the target workspace's **Logs** at
<https://portal.azure.us/>. A new workspace might not yet appear in the
Defender workspace selector; do not query a different workspace as proof.

Once verification succeeds, **if you signed in to AWS in Step 4**, finish with:

```powershell
aws logout --profile $awsProfile
if ($LASTEXITCODE -ne 0) { throw 'Temporary AWS CLI logout failed.' }
```

Skip logout if you did not sign in to AWS for a read-only check.
No scheduled task, local web server or continuously running PowerShell process
is needed. CloudTrail -> S3 -> SQS -> Microsoft's collector -> AWSCloudTrail
continues after the terminal closes. Resources remain chargeable until retired
through approved cleanup.

## Troubleshooting

| Symptom | Action |
|---|---|
| Azure cloud/tenant/workspace error | Correct Step 3; do not bypass the guard |
| AWS login callback says Bad Request | Keep a fresh `aws login` command running and complete its new browser approval; do not reuse an old callback |
| Bucket `InvalidLocationConstraint` | Check the saved profile region in Step 4; do not patch provisioning code to guess a region |
| Prepared folder already exists | Inspect whether setup already ran; preparation deliberately refuses overwrite |
| Trust, account, queue or duplicate-consumer rejection | Stop and correct the intended bindings; do not broaden trust or duplicate consumers |
| API kind/version failure or PUT timeout | Stop and inspect; use the detailed recovery guide, not new random IDs |
| No AWSCloudTrail table/rows yet | Not verified; check delivery and retry Verify without rebuilding the AWS path |

## Optional: explanation, evidence and cleanup

**The eight steps above are the complete deployment procedure.**
These links are reference only.

- [How it works, actual test evidence, errors and cleanup](PRODUCT-GROUP-PACKAGE-WALKTHROUGH.md):
  the longer product-group record, including the two government identity changes.
  The first saved live proof contained **25 real events** on November 4, 2026,
  latest ingestion **18:52:34 UTC**.
- [Regression tests](Tests/Test-AwsSentinelGcch.ps1): 14 checks; not an installation step.
- [Historical CloudFormation experiment](PRODUCT-GROUP-WALKTHROUGH.md):
  background only, **not required and not the deployment procedure above**.

Other tables/log types, live AWS GovCloud source deployment, production-scale
behavior and exactly-once ingestion are outside this validation.
