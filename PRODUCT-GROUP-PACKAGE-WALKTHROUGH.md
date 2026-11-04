# Mirror Microsoft's commercial AWS package for Sentinel GCC High

**Deploying a new environment? Start with the [deployment README](README.md).**
It provides one ordered procedure with the required commands and answers.
This longer document explains the implementation and records the actual lab
run; it is not an additional set of steps to execute after the README.

## What this guide is, and what it replaces

This is the **actual commercial-package execution path**, not the earlier
CloudFormation substitute.

The earlier CloudFormation experiment proved that native CloudTrail ingestion
could work in Azure Government. It did not prove the commercial PowerShell
package could do the provisioning. This separate experiment downloads the real
commercial package, changes its government destination identity constants,
executes its original interactive CloudTrail entry point, and registers the
resulting role/queue with the government native connector API.

**Verified November 4, 2026:** the actual mirrored commercial package provisioned
the AWS path, native connector PUT/GET succeeded, and an isolated government
workspace returned **25 real CloudTrail events**. The saved query completed at
**18:53:18 UTC**; its latest ingestion was **18:52:34 UTC**.
This is package-only end-to-end evidence, not the earlier CloudFormation result.

The [earlier CloudFormation walkthrough](PRODUCT-GROUP-WALKTHROUGH.md) remains
historical evidence of a different path. Its 74/210-event proof is not
reused as evidence for this package run.

## 1. Understand what keeps running

```text
Administrator's PC, during setup only:
  mirrored Microsoft ConfigAwsConnector.ps1
    -> ConfigCloudTrailDataConnector.ps1
      -> original Utils/*.ps1
        -> AWS CLI
          -> AWS IAM, S3, SQS, CloudTrail APIs

Administrator's PC, during Sentinel registration only:
  Invoke-AwsSentinelGcch.ps1 -Mode Connect
    -> AWS CLI read-only identity/trust/queue checks
    -> Azure CLI REST PUT/GET
      -> Azure Government Microsoft.SecurityInsights/dataConnectors

After setup, without the PC:
  CloudTrail -> S3 log files -> SQS file notifications
    -> Microsoft's Sentinel collector assumes the government-bound AWS role
      -> reads the files -> AWSCloudTrail in the government workspace
```

### What calls what, in execution order

The original main file dot-sources the helpers/constants, checks PowerShell and
AWS CLI, opens its CSV log, then dispatches `-AwsLogType CloudTrail` to the
CloudTrail file. The concrete stages below come from that preserved source:

| Caller / function | AWS CLI/API surface | What the administrator sees |
|---|---|---|
| `Utils/HelperFunctions.ps1`: `Test-AwsConfiguration` | `aws ec2 describe-regions` | AWS CLI configuration check |
| `Utils/AwsResourceCreator.ps1`: `New-OidcProvider` | IAM get-provider; create/add-audience only if required | Existing correct government provider was reused in this lab |
| Same file: `New-ArnRole` | IAM get/create-role with generated trust policy | New role and workspace ID prompts |
| Same file: `New-S3Bucket` | S3 head/create-bucket; saved CLI region lookup | New bucket and confirmation prompts |
| Same file: `New-SQSQueue` | SQS create-queue; then get-URL/get-attributes | Dedicated queue prompt and actual queue URL/ARN |
| `Utils/AwsPoliciesUpdate.ps1`: `Update-SQSPolicy` | SQS get/set-queue-attributes | S3 can notify; dedicated role can receive/delete/change visibility/get URL |
| CloudTrail file plus `Update-S3Policy` | Build CloudTrail/role statements, S3 get/put-bucket-policy | Object-read and CloudTrail-delivery policy |
| `Utils/AwsResourceCreator.ps1`: `Enable-S3EventNotification` | S3 get/put-bucket-notification-configuration | Queue destination, account prefix and `.gz` suffix |
| `ConfigCloudTrailDataConnector.ps1` final stages | CloudTrail get/create-trail, optional settings, update-trail, start-logging | New trail, data-event choice, multi-region choice, Logging |
| Wrapper `Connect`, after the upstream script | Government ARM native dataConnectors PUT/GET | Saved government connector using the actual role and queue |
| Wrapper `Verify`, after delivery | Government Logs query API | Real AWSCloudTrail rows, or an explicit failure |

`Utils/CommonAwsPolicies.ps1` supplies reusable policy documents;
`Utils/AwsSentinelTag.ps1` supplies resource tags;
`Enviornment/EnviornmentConstants.ps1` supplies destination identity and source
partition constants. Other log-type files are not invoked by this CloudTrail
selection. Optional KMS and organization-wide branches were answered **No**,
not executed and assumed successful.

The wrapper does not replace Microsoft's AWS provisioning functions. Its
PrepareAws mode only extracts/corrects a copy. You run Microsoft's main script
separately. Connect replaces the missing government portal Add connection step.
Verify asks the government Logs API for real data.

One connection selects one destination table. This test configures **CloudTrail
management events only**, not VPC Flow Logs, GuardDuty findings, or CloudWatch.
Those source entry points remain in the package but have not been live-tested
in this experiment.

## 2. Establish the test boundaries

For a product-group reproduction, use:

- The intended AWS source account and region. This live source is AWS
  **commercial**, region **us-east-1**, not AWS GovCloud.
- New dedicated role, bucket, standard queue, notification, and trail names.
- A **separate Sentinel-enabled government test workspace**, if the existing
  workspace already receives the same account's CloudTrail data.

Why a separate workspace? The same AWS events can be copied by two trails.
Seeing them in the old workspace would not tell us which connector delivered
them. The isolated workspace has only the package-created AWS connection, so
its real events can be attributed to this path.

Do not change existing commercial or government queue consumers, bucket
notifications, IAM roles, or trails. A correct government OIDC provider can be
shared: the upstream function reads its audience list and leaves an
already-present audience alone.

This adds a management-event trail and may incur duplicate-copy charges.
Workspace ingestion, S3 and SQS also incur costs. Use approved permissions and
data export authorization.

## 3. Gather the values before running a script

1. Sign in to <https://portal.azure.us/>.
2. Open **Log Analytics workspaces**.
3. Use a new isolated workspace for this reproduction, or an explicitly
   reviewed existing target. For a new workspace, select **Create**, choose
   the approved subscription/resource group, a unique name, and a supported
   government region. The live test used **US Gov Virginia**.
4. Open **Microsoft Sentinel**, select **Create/Add**, and enable Sentinel on
   that workspace. Review billing before enabling.
5. In the workspace's **Overview**, copy its **Workspace ID** (customer ID),
   resource name, resource group and subscription ID.
6. In **Microsoft Entra ID -> Overview**, record the organization tenant ID.
7. Open <https://console.aws.amazon.com/> separately.
8. Confirm the AWS account ID and **us-east-1** region.

The organization tenant, subscription, and workspace customer ID are different.
The Microsoft government service identity below is not your organization tenant.

The live automation created the isolated workspace with ARM
`Microsoft.OperationalInsights/workspaces` API `2022-10-01`, then enabled
`Microsoft.SecurityInsights/onboardingStates/default` with API `2024-03-01`
and body `{"properties":{"customerManagedKey":false}}`. No Content hub solution
was required to create that onboarding state.

## 4. Install tools and authenticate

Required: PowerShell 7+, Azure CLI, AWS CLI v2.
For browser-based temporary AWS CLI sign-in, use AWS CLI 2.32.0 or later.
The live package test used AWS CLI **2.39.3**.

Use an approved IAM/federated administrator, SSO profile, or other approved
temporary credential mechanism. Do not create long-lived keys for this test.
The lab operator explicitly approved an existing root session through AWS's
browser login; that was a lab-specific choice, not a production recommendation.
Root credentials/tokens must never be embedded in scripts or evidence.

Open PowerShell 7 in the downloaded repository folder:

```powershell
$ErrorActionPreference = 'Stop'
az cloud set --name AzureUSGovernment
if ($LASTEXITCODE -ne 0) { throw 'Cannot select Azure Government.' }
$tenantId = Read-Host 'Government organization tenant ID'
az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed.' }

$target = @{
    TenantId       = $tenantId
    SubscriptionId = Read-Host 'Government subscription ID'
    ResourceGroup  = Read-Host 'Workspace resource group'
    WorkspaceName  = Read-Host 'Isolated government workspace name'
}
$awsTarget = @{
    AwsPartition = 'aws'
    AwsAccountId = Read-Host 'AWS source account ID (12 digits)'
    AwsRegion    = 'us-east-1'
}
$awsProfile = Read-Host 'Dedicated AWS CLI profile name'
aws login --profile $awsProfile --region $awsTarget.AwsRegion
if ($LASTEXITCODE -ne 0) { throw 'AWS login failed.' }

# The upstream package explicitly calls "aws configure get region".
# An environment variable alone did NOT satisfy that prerequisite in the live test.
aws configure set region $awsTarget.AwsRegion --profile $awsProfile
if ($LASTEXITCODE -ne 0) { throw 'Cannot save test profile region.' }
$env:AWS_PROFILE = $awsProfile
$env:AWS_REGION = $awsTarget.AwsRegion
$env:AWS_DEFAULT_REGION = $awsTarget.AwsRegion
$env:AWS_PAGER = ''
$env:AWS_CLI_AUTO_PROMPT = 'off'

$identityText = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) { throw 'AWS CLI authentication is not working.' }
$identity = $identityText | ConvertFrom-Json
if ($identity.Account -ne $awsTarget.AwsAccountId) { throw 'Wrong AWS account.' }
aws configure get region --profile $awsProfile
if ($LASTEXITCODE -ne 0) { throw 'AWS profile region is missing.' }
.\Invoke-AwsSentinelGcch.ps1 @target -Mode Inspect | ConvertTo-Json -Depth 20
```

Check the printed identity and government workspace/customer ID.
Do not proceed on a wrong account/cloud/workspace or missing onboarding state.
Browser console sign-in by itself does not authenticate AWS CLI. During
`aws login`, keep the command running until the callback completes; reusing an
old callback URL after stopping the command will not create credentials.

Credentials belong in AWS CLI's normal protected profile/cache locations,
not the repository or handover ZIP. Never save a browser authorization code,
token, password, or credentials file in deployment evidence.

## 5. Download the actual commercial package

This is the commercial ZIP, **not** `ConfigAwsS3DataConnectorScriptsGov.zip`:

```powershell
$zip = Join-Path $PWD 'ConfigAwsS3DataConnectorScripts.zip'
if (Test-Path -LiteralPath $zip) {
    throw 'Archive already exists. Inspect its checksum instead of overwriting.'
}
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/DataConnectors/AWS-S3/ConfigAwsS3DataConnectorScripts.zip' `
  -OutFile $zip
$expected = '0586346CA75A79F04E59AFAD778499F50F1C1383A4672A3405CB3E132DC2377F'
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
    throw 'Commercial package changed. Review it before changing the pinned hash.'
}
```

The source `master` URL is mutable. The hash identifies the reviewed artifact
from November 4, 2026; it is not a promise that future downloads are identical.
The commercial outer ZIP contains:

```text
ConfigAwsComToAzureCom.zip
ConfigAwsGovToAzureCom.zip
```

The AWS-commercial variant used live is `ConfigAwsComToAzureCom.zip`.
Its extracted baseline has **19 files**, including
`CloudWatchLambdaFunction_V2.py`. The previously downloaded Gov variant lacked
that V2 file. We therefore did not assume the government ZIP was identical.
Original upstream notices/files are retained; the ZIP is fetched from Microsoft,
not redistributed in the public repository.

## 6. Make only the government destination changes

```powershell
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget -Mode PrepareAws -WhatIf
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget -Mode PrepareAws
```

The output folder for this source is `prepared-aws-to-gcch`.
Existing prepared folders are not overwritten. Use a deliberate fresh
OutputDirectory if an old folder exists.

PrepareAws now selects the **commercial baseline ZIP** and preserves every
file. Only active assignments in `Enviornment\EnviornmentConstants.ps1` are
updated. Inactive commented examples and all provisioning code are preserved.

| Active variable | Commercial baseline | Government destination |
|---|---|---|
| SentinelClientId | `api://1462b192-27f7-4cb9-8523-0f4ecb54b47e` | `api://d4230588-5f84-4281-a9c7-2c15194b28f7` |
| SentinelTenantId | `33e01921-4d64-4f8c-a055-5bdaffd5e33d` | `cab8a31a-1906-4287-a0d8-4eef66b95f6e` |
| CloudEnv | `Com` | `Com` unchanged |
| AwsCloudResource | `arn:aws` | `arn:aws` unchanged |

Two active values change because the **destination** changes. The AWS source
is still commercial. Do not change the source partition merely because the
destination is GCC High. AWS GovCloud source preparation is covered by local
tests but has not been live-executed here.

The live run made the same two active changes directly in a full commercial
package copy, plus relabelled the active block's comment. It preserved all 19
files and all provisioning code. The optional helper was then updated to
reproduce that commercial-baseline preparation rather than the old Gov ZIP path.

## 7. Check names and existing providers in the AWS console

1. **IAM -> Identity providers:** inspect the government provider URL
   `sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/`.
   If present, confirm government audience
   `api://d4230588-5f84-4281-a9c7-2c15194b28f7`.
2. **IAM -> Roles:** ensure the new `OIDC_` role name does not exist.
3. **S3 -> Buckets:** ensure the new bucket name does not exist.
4. **SQS -> Queues:** ensure the new standard queue name does not exist.
5. **CloudTrail -> Trails:** ensure the new trail name does not exist.

Use names that clearly identify this isolated package test. Stop on collisions:
the upstream package can reuse/modify existing resources. An access-denied
response does not prove a resource is absent. Do not accept reuse of a
production role/bucket/trail just to advance past a prompt.

## 8. Execute Microsoft's original main script

```powershell
$prepared = Join-Path $PWD 'prepared-aws-to-gcch'
Push-Location $prepared
try {
    .\ConfigAwsConnector.ps1 -AwsLogType CloudTrail
}
finally {
    Pop-Location
}
```

Run from the prepared directory: its helper paths are relative.
Read every prompt and error. The CloudTrail entry point calls the original
OIDC/role, bucket, queue, policy, notification, and trail helpers. It does not
create the Sentinel backend connector; its final role/queue/table output is
the handoff to that separate step.

The live automation supervised the original process through redirected stdin
and answered one stage at a time. This did not replace provisioning functions
with mocks. A normal admin can run it directly in an interactive terminal.

### Prompt-by-prompt decisions

| Upstream prompt/stage | Admin supplies | Why |
|---|---|---|
| Role name | A new name beginning `OIDC_` | Separate trust from existing connections |
| Azure Sentinel External ID / Workspace ID | **Isolated government workspace customer ID** | Creates `MicrosoftSentinel_<ID>` role-session binding |
| S3 bucket name | New globally unique bucket name | Keeps logs/policies away from existing sources |
| Create missing bucket | `y`, only after absence/account checks | The package creates it through S3 API |
| SQS name | New standard queue name | Prevents competing consumers |
| Enable KMS | `n` for this first parity test | Avoids adding an untested KMS/key-policy branch |
| Enable trail/policy for all organization accounts | `n` | No organization-wide expansion |
| Notification name | A new descriptive rule name | Identifies this notification |
| Override default notification prefix | `n` | Keeps `AWSLogs/<ACCOUNT-ID>/CloudTrail/` |
| CloudTrail name | New dedicated trail name | Avoids changing an existing trail |
| Enable CloudTrail data events | `n` | Matches management-event scope |
| Multi-region trail | `y` | Collects management activity across enabled regions |
| Press any key | Acknowledge in an interactive console | Terminal-only pause after final outputs |

### Actual failure and recovery during execution

The first bucket attempt failed:

```text
aws s3api create-bucket ... --create-bucket-configuration LocationConstraint=
InvalidLocationConstraint
```

Why: `aws configure get region` returned empty even though AWS_REGION was set.
The package used that empty value to construct LocationConstraint.
Its retry logger also printed:

```text
Cannot bind argument to parameter 'Message' because it is null.
```

We saved `us-east-1` on the dedicated CLI profile, then answered its bucket
retry. The next creation succeeded. **No upstream provisioning code was
patched to hide or bypass either error.** Step 4 includes the missing
persisted-region prerequisite so an admin does not repeat that failure.

The script printed its new role ARN, SQS URL, and `AWSCloudTrail`. Save the real
CSV log and outputs, but do not assume success from the process exit code.

The supervised run then waited at the final console-only `RawUI.ReadKey`.
Redirected stdin could not acknowledge that terminal pause. After all cloud
provisioning calls/final outputs and independent read-backs, the owned process
was stopped at that pause. **We do not claim a normal upstream process exit.**
An administrator running directly in a console can press a key normally.

## 9. Inspect exactly what the package created

In the AWS console:

1. **IAM -> role -> Trust relationships:** confirm the government provider,
   government audience, and the isolated workspace's session binding.
2. **S3 -> new bucket -> Permissions:** inspect the bucket policy granting
   this role object reads and CloudTrail delivery.
3. **S3 -> Properties -> Event notifications:** confirm the dedicated queue,
   account-specific `CloudTrail/` prefix, and upstream `.gz` suffix.
4. **SQS -> new queue -> Access policy:** confirm S3 notifications and the
   dedicated role's receive/delete/change-visibility/get-URL permissions.
5. **CloudTrail -> new trail:** confirm Logging, correct bucket and multi-region.
6. Wait for successful **Last log file delivered** and actual S3 objects.
7. Inspect queue counts only; do not receive/delete/purge the notifications.

Optional CLI read-back (set names from your real outputs):

```powershell
$roleName = Read-Host 'Package-created role name'
$bucketName = Read-Host 'Package-created bucket'
$trailName = Read-Host 'Package-created trail'
$sqsUrl = Read-Host 'Package-created SQS URL'
aws iam get-role --role-name $roleName --output json
if ($LASTEXITCODE -ne 0) { throw 'Role read-back failed.' }
aws s3api get-bucket-policy --bucket $bucketName --output json
if ($LASTEXITCODE -ne 0) { throw 'Bucket policy read-back failed.' }
aws s3api get-bucket-notification-configuration --bucket $bucketName --output json
if ($LASTEXITCODE -ne 0) { throw 'Notification read-back failed.' }
aws sqs get-queue-attributes --queue-url $sqsUrl --attribute-names All --output json
if ($LASTEXITCODE -ne 0) { throw 'Queue read-back failed.' }
aws cloudtrail get-trail --name $trailName --output json
if ($LASTEXITCODE -ne 0) { throw 'Trail read-back failed.' }
aws cloudtrail get-trail-status --name $trailName --output json
if ($LASTEXITCODE -ne 0) { throw 'Trail status failed.' }
```

Do not claim the package's policies/settings are byte-identical to the earlier
custom CloudFormation template. For example, the upstream notification suffix
is `.gz`, whereas the earlier template used `.json.gz`; upstream access grants
also use resource policies. These are Microsoft package behaviors retained in
the mirror, not arbitrary redesigns.

The package-created trail also showed **log file validation Disabled**, unlike
the earlier custom trail. Optional SSE-KMS was not enabled, management activity
was **All**, and data events were not configured. These observed defaults are
disclosed, not silently hardened or presented as identical to the earlier
template. Review production integrity/encryption requirements separately.

For comparison, this is the actual generated trust shape, with only customer
bindings replaced by placeholders:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<AWS-ACCOUNT-ID>:oidc-provider/sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/:aud": "api://d4230588-5f84-4281-a9c7-2c15194b28f7",
        "sts:RoleSessionName": "MicrosoftSentinel_<ISOLATED-WORKSPACE-CUSTOMER-ID>"
      }
    }
  }]
}
```

In plain language: the role trusts the Microsoft government service identity,
accepts the government Sentinel audience, and requires the destination
workspace's session name. Neither the AWS root browser nor the administrator's
temporary CLI credentials are used by Sentinel's ongoing collector.

## 10. Register those actual outputs in government Sentinel

Return to the repository directory, retaining the variables from Step 4.

```powershell
$connection = @{
    RoleArn = Read-Host 'Exact Role Arn printed by the upstream package'
    SqsUrl = Read-Host 'Exact Sqs Url printed by the upstream package'
    AwsProfile = $awsProfile
}
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect -WhatIf
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect
```

Connect checks AWS identity, role trust, government audience, workspace session,
provider audience and queue identity. It checks the government workspace and
native connector inventory before creating anything. An identical enabled
resource is a no-op; conflicting queue consumers are rejected.

It calls:

```text
PUT https://management.usgovcloudapi.net/subscriptions/<SUBSCRIPTION>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE>/providers/Microsoft.SecurityInsights/dataConnectors/<ID>?api-version=2025-10-01-preview
```

Request shape:

```json
{
  "kind": "AmazonWebServicesS3",
  "properties": {
    "roleArn": "<EXACT-PACKAGE-ROLE-ARN>",
    "sqsUrls": ["<EXACT-PACKAGE-SQS-URL>"],
    "destinationTable": "AWSCloudTrail",
    "dataTypes": { "logs": { "state": "Enabled" } }
  }
}
```

The role ARN and queue URL are actual outputs, not invented replacements.
The request contains no AWS access keys. GET read-back must match the request.

The live package run's first PUT returned GatewayTimeout. Exact-ID GET and
preview inventory showed no saved connector. Retrying the **same deterministic
ID** then succeeded. If your request times out, inspect first: do not generate
new IDs/queues or assume the request failed to save.

The stable API kind rejections and the required tested preview API are recorded
in the [earlier API investigation](PRODUCT-GROUP-WALKTHROUGH.md).
Preview functionality is not a Microsoft production support commitment.

## 11. Prove package-only ingestion, not just provisioning

```powershell
.\Invoke-AwsSentinelGcch.ps1 @target -Mode Verify `
  -AwsAccountId $awsTarget.AwsAccountId -LookbackHours 2
```

Verify calls the government Logs API:

```text
POST https://api.loganalytics.us/v1/workspaces/<ISOLATED-WORKSPACE-CUSTOMER-ID>/query
Token audience: https://api.loganalytics.us
```

The POST executes a query; it does not upload events or change cloud resources.
Empty results fail explicitly. Successful results are saved in
`gcch-ingestion-evidence.json`, including workspace ID, query and UTC timestamp.

For the portal, open <https://security.microsoft.us/>, select the isolated
workspace in Advanced hunting, set a UI time range covering the test, and run:

```kusto
AWSCloudTrail
| where ingestion_time() > ago(2h)
| where UserIdentityAccountId == "<AWS-ACCOUNT-ID>"
    or RecipientAccountId == "<AWS-ACCOUNT-ID>"
| summarize Events=count(), LastEvent=max(TimeGenerated),
    LastIngested=max(ingestion_time()) by AWSRegion, EventSource
| order by LastIngested desc
```

The Defender workspace selector may list only workspaces connected to that
portal experience. In this lab it still listed only the original workspace,
not the newly created isolated workspace. Do not select the original and call
its results package proof. Use the isolated workspace's **Logs** in
<https://portal.azure.us/> with an authorized browser session, or use Verify
against its exact customer ID. The saved package proof here is the real
government Logs API response, not an asserted Defender screenshot.

One grouped result row is not one raw event. Sum `Events`.
Use UTC JSON timestamps when comparing with a portal showing local time.
Do not substitute results from the earlier workspace. Initial empty polls
are not success, and source delivery alone is not ingestion.

### Actual isolated-workspace result

The verification succeeded on poll 8 after seven initial empty results.
The trail began Logging at **18:37:54 UTC**, delivered source files by
**18:42:39 UTC**, and the successful query completed at **18:53:18 UTC** on
November 4, 2026. Its seven grouped rows contained **25 events**, not seven.
The timestamps below are exact UTC values from that saved query; customer
identifiers are intentionally omitted.

| AWS region | Event source | Events | Latest ingestion, UTC |
|---|---|---:|---|
| us-east-1 | iam.amazonaws.com | 8 | 18:52:34.362733 |
| us-east-1 | notifications.amazonaws.com | 2 | 18:52:34.362733 |
| us-east-1 | s3.amazonaws.com | 6 | 18:52:34.362733 |
| us-east-1 | cloudtrail.amazonaws.com | 3 | 18:52:34.362733 |
| eu-central-1 | sts.amazonaws.com | 1 | 18:50:15.8423109 |
| us-east-1 | sts.amazonaws.com | 4 | 18:50:15.8423109 |
| eu-central-1 | connect.amazonaws.com | 1 | 18:50:15.8423109 |

These are API activity records within **AWSCloudTrail**, not separate IAM,
S3, STS or Amazon Connect ingestion tables. The observed timings are one lab
run, not a promised service latency.

This short console excerpt is from the actual run; only resource identifiers
are replaced with placeholders:

```text
Checking existing OIDC provider
  OIDC provider already exists
  Approved client IDs: api://d4230588-5f84-4281-a9c7-2c15194b28f7
  Client ID api://d4230588-5f84-4281-a9c7-2c15194b28f7 is already approved
  <NEW-ROLE> role created successfully
  S3 Bucket <NEW-BUCKET> created successfully
Enabling S3 event notifications (for *.gz file)
```

The internal handover retains the original unredacted CSV/transcript,
request/read-back, isolated workspace ID, and full query result so the product
group can trace these public snippets back to actual evidence.

## 12. Evidence to send to the product group

Keep the original commercial archive/hash, complete file comparison, active
constants delta, upstream CSV/transcript, real AWS resource read-backs, native
request/response, and actual isolated-workspace ingestion results.

Unredacted account/tenant/workspace values and screenshots belong only in the
intended internal handover. Public examples should redact customer bindings.
Do not distribute credential caches, authorization codes, or tokens.

The offline regression suite now checks the actual commercial ZIP variants,
the active government bindings, and hashes of **every non-constants file**,
as well as the existing connector safety/query checks. Fourteen tests passed.
Offline tests do not establish live ingestion for other package log types.

## 13. Cleanup and scope limits

The package creates standalone resources, not a CloudFormation stack.
Do not tell an admin to delete a nonexistent stack as cleanup.
After approved test retention:

1. Remove only the test native connector.
2. Stop only the package-test trail.
3. Retain/delete its S3 objects according to policy, then retire only the
   dedicated trail, notification, queue and role after dependency review.
4. Do not delete the shared government OIDC provider or original connections.
5. Retire the isolated workspace when evidence retention permits.
6. Log out of the temporary AWS CLI profile when execution/evidence work ends:
   `aws logout --profile <TEST-PROFILE>`.

No claim is made for all AWS tables, AWS GovCloud source live execution,
exactly-once ingestion, production-scale behavior, or preview production support.

## Official sources

- [Microsoft commercial package source folder](https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/AWS-S3)
- [Microsoft AWS setup and government OIDC settings](https://learn.microsoft.com/en-us/azure/sentinel/connect-aws-configure-environment)
- [AWS temporary CLI console login](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [Sentinel onboarding API](https://learn.microsoft.com/en-us/rest/api/securityinsights/sentinel-onboarding-states/create?view=rest-securityinsights-2024-03-01)
