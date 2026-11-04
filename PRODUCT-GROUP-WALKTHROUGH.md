# AWS CloudTrail into Sentinel GCC High: exactly how the working test was built

**This is the earlier CloudFormation experiment.** The separate
[commercial-package walkthrough](PRODUCT-GROUP-PACKAGE-WALKTHROUGH.md)
documents the actual Microsoft-package mirror and execution. Do not mix the
two sets of evidence or treat the original CloudFormation results as package proof.

## Read this first

This is the **CloudFormation + Azure CLI/REST path actually used** on November 4,
2026. It is not the alternative Microsoft PowerShell provisioning path.
An administrator builds AWS resources in the AWS console, then registers the
native connector directly in Azure Government. The missing Content hub tile
is not involved.

**Already running? Do not repeat deployment. Start at Step 9 to inspect it.**
The actions marked **WRITE** create chargeable resources or change configuration.
Read through the entire guide before performing them on a new target.

There are two separate things to prove:

1. A connector resource exists. A successful PUT/GET proves only that.
2. Real AWS events reached the government workspace. Only a successful query
   of `AWSCloudTrail` proves ingestion.

Both were verified. Initial proof: **74 events / 15 grouped rows**, ingested at
**2026-11-04 17:22:00 UTC**. A later read-only check at **18:09:26 UTC** returned
**183 events / 19 grouped rows**, latest ingestion **18:09:15 UTC**.
Executing this walkthrough's own read-only query snippet at **18:15:32 UTC**
returned **210 events / 19 groups**, latest ingestion **18:14:24 UTC**.
These are account-filtered results over a rolling two-hour ingestion window,
not an event-loss calculation, performance benchmark, or availability SLA.

## 1. What we did, and what we did not do

| Action | Actually performed in the live test? |
|---|---|
| Inspect government Defender Content hub | Yes; general AWS/Amazon solution was not found in the selected workspace |
| Create separate AWS CloudFormation stack in the browser | Yes |
| Create a government OIDC provider, role, bucket, queue, and trail | Yes; seven CloudFormation resources including policies |
| Register native `AmazonWebServicesS3` through Azure CLI REST | Yes |
| Query the government Logs API and government Defender | Yes; real records |
| Run Microsoft's downloaded interactive AWS PowerShell setup | **No**; files were inspected/prepared, not used to provision the live stack |
| Run our wrapper's AWS-CLI `Connect` mode for the live deployment | **No**; AWS CLI was not installed; Azure CLI PUT/GET was used directly |
| Install/revive the deprecated Content hub solution | No |
| Create a Lambda, agent, local relay, custom DCR, or custom table | No |
| Leave a script running on the administrator's PC | No |

Commercial used CloudFormation plus its connector UI. Government used a separate
CloudFormation stack plus ARM REST because the UI entry was missing.
The data path and destination table are equivalent for this tested log type;
provisioning, cloud endpoints, authentication bindings, and support status differ.

## 2. Understand the pieces before clicking anything

Think of S3 as a filing cabinet and SQS as a list of newly added files:

```text
AWS activity
   |
   v
CloudTrail writes compressed JSON files
   |
   v
S3 bucket -------------------------+
   |                               |
   | sends "a file was added"       | Sentinel downloads the actual file
   v                               |
SQS notification queue             |
   |                               |
   +---- Sentinel collector -------+
               |
               v
       AWSCloudTrail table
       in Azure Government
```

The queue contains **notifications pointing to files**, not all CloudTrail
events. One file can contain many events. Queue message count, file count,
grouped query rows, and raw event count are not interchangeable.

| Component | Plain-English job | Who calls what |
|---|---|---|
| CloudFormation | Builds the AWS resources from YAML | Admin uploads template; AWS provisions services |
| CloudTrail trail | Records management activity | CloudTrail writes objects to S3 using the bucket policy |
| S3 bucket | Stores compressed CloudTrail files | S3 sends object-created notifications to SQS |
| SQS queue | Holds pointers until collection | Sentinel uses the role's SQS receive/delete/visibility permissions |
| IAM OIDC provider | Identifies the trusted Microsoft token issuer | AWS STS validates a web-identity request against the configured provider |
| IAM role trust | Limits who can obtain temporary AWS role credentials | Trust requires government audience and workspace-bound session name |
| IAM role permissions | Limits what those temporary credentials can read | Allows only dedicated log-object reads and dedicated queue consumption |
| Native Sentinel connector | Configures Microsoft's collector | ARM stores role ARN, SQS URL, destination table, and enabled state |
| Logs API / Advanced hunting | Lets the admin inspect ingested data | Reads the government workspace; does not forward AWS data |

Microsoft's collector authenticates to AWS using
`AssumeRoleWithWebIdentity`. No long-lived AWS access key was put in the
connector. In the actual backend GET, `awsAccessKey`, `awsSecretKey`, and
`dcrConfig` were all null.

The exact internal service scheduling, token caching, parsing, and
acknowledgment implementation was not traced. This guide describes the
configured contract and observed results, not a reconstruction of private
Microsoft service internals.

## 3. Gather the correct IDs and approvals

Use an authorized administrator account, not AWS root. Confirm export/compliance
approval; successful authentication does not authorize exporting regulated data.
PowerShell 7 and Azure CLI are required for the commands below. AWS CLI is
**not** required for this console-based path.

Open these separately:

- AWS console: <https://console.aws.amazon.com/>
- Government Azure portal: <https://portal.azure.us/>
- Government Defender: <https://security.microsoft.us/>

Do not substitute `portal.azure.com` or `security.microsoft.com` for the
government destination.

Record:

| Value | Where the admin finds it | Why it matters |
|---|---|---|
| Government organization tenant ID | Azure Government Microsoft Entra ID -> Overview | Chooses the customer directory for Azure CLI sign-in |
| Government subscription ID | Workspace Overview / subscription | Identifies the Azure resource scope |
| Workspace resource group and name | Azure Government -> Log Analytics workspaces -> target workspace -> Overview | Builds the ARM resource path |
| Workspace ID / customer ID | Same workspace Overview | Binds the AWS role session and selects the Logs API workspace |
| AWS account ID | AWS console account menu | Identifies the AWS source account |
| AWS region | AWS console region selector | The live test used AWS commercial `us-east-1` |

**Tenant ID, subscription ID, and workspace customer ID are different IDs.**
The government Microsoft service tenant below is a fourth, different identity:

```text
Issuer:
  https://sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/
Audience:
  api://d4230588-5f84-4281-a9c7-2c15194b28f7
Role session:
  MicrosoftSentinel_<YOUR-WORKSPACE-CUSTOMER-ID>
```

Those service values are not customer tenant defaults.
The tested source was **AWS commercial**, not AWS GovCloud. The reproduction
template uses `arn:aws`; do not use it unchanged for `arn:aws-us-gov`.

**Permissions:** the AWS operator needs CloudFormation and the IAM/S3/SQS/
CloudTrail permissions needed to create this stack. The Azure operator needs
workspace/provider read access, Sentinel connector write access, and workspace
log-query access. Use organization-approved least-privilege roles; possession
of one permission does not imply the others.

## 4. Sign in to Azure Government and confirm the workspace [READ]

Open PowerShell 7. Go to the folder containing this guide/template.
Commands in this guide are run in the **same PowerShell session** so variables
remain available. If you close it, repeat the variable/sign-in steps.

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
az cloud set --name AzureUSGovernment
if ($LASTEXITCODE -ne 0) { throw 'Cannot select Azure Government.' }
$tenantId = Read-Host 'Government ORGANIZATION tenant ID'
$subscriptionId = Read-Host 'Government subscription ID'
$resourceGroup = Read-Host 'Workspace resource group'
$workspaceName = Read-Host 'Workspace resource name'
$awsAccountId = Read-Host 'Source AWS account ID (12 digits)'
if ($awsAccountId -notmatch '^\d{12}$') { throw 'Invalid AWS account ID.' }

az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
az account show --subscription $subscriptionId `
  --query '{Cloud:environmentName,Tenant:tenantId,Subscription:id}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Subscription lookup failed.' }
```

Stop if the printed cloud is not `AzureUSGovernment` or the IDs are not yours.
Do not copy the lab's organization IDs into a different customer's deployment.

Create a small helper so a CLI error cannot silently become an empty object:

```powershell
function Invoke-AzJson {
    param([string[]]$Arguments)
    $text = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI failed; review the error above.' }
    if (-not $text) { throw 'Azure CLI returned an empty response.' }
    $text -join "`n" | ConvertFrom-Json
}
$arm = 'https://management.usgovcloudapi.net'
$workspacePath = "/subscriptions/$subscriptionId/resourceGroups/$([uri]::EscapeDataString($resourceGroup))/providers/Microsoft.OperationalInsights/workspaces/$([uri]::EscapeDataString($workspaceName))"
$workspace = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'get',
    '--url', "$arm$workspacePath`?api-version=2022-10-01", '-o', 'json'
)
$workspaceId = [guid]$workspace.properties.customerId
$workspace | Select-Object name, location
"Workspace customer ID: $workspaceId"
$sentinelPath = "$workspacePath/providers/Microsoft.SecurityInsights"
$null = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'get',
    '--url', "$arm$sentinelPath/onboardingStates/default?api-version=2024-03-01",
    '-o', 'json'
)
```

**What happened:** your Azure CLI called Azure Government ARM to read the
workspace and Sentinel onboarding. Nothing was created. Copy `$workspaceId`
for CloudFormation. The live workspace location was `usgovvirginia`.
An absent onboarding state is a stop condition: enable Sentinel through your
approved process before continuing.

## 5. Check AWS for collisions before creating anything [READ]

1. Sign in to the correct AWS account. Verify its 12-digit account ID.
2. Choose **US East (N. Virginia), us-east-1**, matching this tested source region.
3. Use the AWS search bar to open **IAM**.
4. In IAM, open **Identity providers**.
5. Look for `sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/`.
   - If absent, the new stack can create it.
   - If present, open it. Confirm the provider URL and government audience above.
     Copy its provider ARN. Do not delete it or replace its audience list.
     An existing provider can belong to another stack/workload.
6. Open **CloudTrail -> Trails**. Look for `sentinel-gcch-management-events`.
7. Open **S3 -> Buckets**. Look for
   `sentinel-gcch-cloudtrail-<AWS-ACCOUNT-ID>-us-east-1`.
8. Open **IAM -> Roles**. Choose a new dedicated role name beginning `OIDC_`.
   Do not reuse the commercial role.

If that trail, bucket, role, or an earlier government stack already exists,
**stop deployment** and identify its owner. The fixed bucket/trail names make
this a single isolated deployment per account/region, not an unlimited
multi-workspace template. Do not rename resources piecemeal: the policies refer
to the matching trail and bucket names.

The live original stack created a new government provider. The optional
existing-provider branch in the reproduction template is an adaptation for
accounts that already have that provider; it was not the live provisioned branch.

## 6. Upload the CloudFormation template in AWS [WRITE]

Use [cloudtrail-gcch-reproduction.yaml](cloudtrail-gcch-reproduction.yaml).
This is a public, parameterized derivative of the deployed lab template:
workspace ID and role name are inputs instead of embedded customer values,
and an optional existing-provider ARN avoids duplicate-provider creation.
It is **not the untouched file deployed in the lab**. The private evidence
appendix identifies that exact original file and its SHA-256.

1. In AWS search, type **CloudFormation**, then open the service.
2. Confirm region **us-east-1** again.
3. Select **Create stack -> With new resources (standard)**.
4. Choose **Choose an existing template** if that option is shown.
5. Choose **Upload a template file**.
6. Choose the reproduction YAML from your PC, then select **Next**.
7. Enter a new stack name, for example `sentinel-gcch-workspace-cloudtrail`.
8. Enter parameters:
   - **WorkspaceCustomerId:** the GUID printed by Step 4.
   - **SentinelRoleName:** your new `OIDC_` role name.
   - **ExistingGovernmentOidcProviderArn:** blank if no such provider exists;
     otherwise its exact reviewed ARN from Step 5, in this same AWS account.
9. Select **Next** through stack options. Do not add a service role or other
   settings unless your organization's CloudFormation process requires them.
10. Review the template, parameters, capabilities and expected resources.
11. Acknowledge creation of **IAM resources with custom names**.
12. Select **Submit/Create stack**. This is the action that creates resources.
13. Watch **Events**. Wait for **CREATE_COMPLETE**. Do not continue through a
    failed or rolled-back stack.
14. Open **Resources**. Expect seven resources for a new provider, or six
    managed resources when explicitly reusing an existing provider.
15. Open **Outputs**. Copy **RoleArn**, **SqsUrl**, **BucketName**, and
    **DestinationTable**. DestinationTable must be `AWSCloudTrail`.

Console labels can change. If a capability or resource differs from the
reviewed template, stop and investigate rather than blindly clicking through.

**What CloudFormation created and why:**

| Logical resource | Purpose / safety boundary |
|---|---|
| GovernmentOidcProvider | Government issuer and audience; original live stack created this |
| Queue | Standard SQS, SSE-SQS, 14-day retention, 300-second visibility timeout |
| QueuePolicy | Allows only the source bucket/account to send S3 notifications |
| Bucket | Private, block-public-access, enforced ownership, SSE-S3 encryption |
| BucketPolicy | Denies non-TLS access; permits only the named CloudTrail trail to deliver logs |
| Trail | Multi-region, global service events, all read/write management events, log validation |
| SentinelRole | Workspace-bound trust plus scoped bucket reads and queue consumption |

The bucket is retained on stack deletion. CloudTrail validation digest files
are not the selected ingestion input: notifications match the `CloudTrail/`
prefix and `.json.gz` suffix, not `CloudTrail-Digest/`.

## 7. Inspect delivery, notifications, and role trust in AWS [READ]

### A. Did CloudTrail write a real file?

1. Open **CloudTrail -> Trails -> sentinel-gcch-management-events**.
2. Confirm **Logging**.
3. Find **Last log file delivered** and any delivery errors.
4. Open the bucket link, or go to **S3 -> copied BucketName -> Objects**.
5. Browse `AWSLogs/<AWS-ACCOUNT-ID>/CloudTrail/<REGION>/<YEAR>/<MONTH>/<DAY>/`.
6. Look for actual `.json.gz` objects. Console layout/date depth may vary.
   Do not make the bucket public or download customer logs for a public guide.

The live test showed successful source delivery at **12:13:39 UTC-05:00**.
That proved CloudTrail -> S3, not Sentinel ingestion.

### B. Is S3 notifying the right queue?

1. In the bucket, select **Properties -> Event notifications**.
2. Confirm object-created events to the dedicated SQS queue.
3. Confirm prefix `AWSLogs/<AWS-ACCOUNT-ID>/CloudTrail/`.
4. Confirm suffix `.json.gz`.
5. Open **SQS -> your dedicated queue** and inspect its configuration/counts.
   Do **not** click polling/receive, delete, or purge messages.

Zero messages can mean no new files or successful consumption. Nonzero messages
can mean normal backlog or a collection problem. Neither alone proves success.

### C. Can only the intended government workspace assume the role?

1. Open **IAM -> Roles -> copied role name -> Trust relationships**.
2. Compare the trust to this actual configuration shape:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<AWS-ACCOUNT-ID>:oidc-provider/sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/:aud": "api://d4230588-5f84-4281-a9c7-2c15194b28f7",
      "sts:RoleSessionName": "MicrosoftSentinel_<WORKSPACE-CUSTOMER-ID>"
    }
  }
}
```

3. Under **Permissions**, inspect the inline policy:
   - `s3:GetObject`: only this bucket's account-specific `CloudTrail/*` objects.
   - `s3:ListBucket`, `s3:GetBucketLocation`: only this bucket.
   - `sqs:ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`,
     `GetQueueUrl`, `GetQueueAttributes`: only this queue.

Trust answers **who can assume the role**. Permissions answer **what the role
can do after assumption**. One does not replace the other.
This template uses SSE-S3, not a customer KMS key. Switching to KMS requires
separate decryption/key-policy review and was not tested here.

## 8. Register the government native connector [WRITE]

Return to the same PowerShell session used in Step 4.
You are not running Microsoft's downloaded PowerShell setup.
You are telling the existing Sentinel service which role and queue to use.

### A. Inspect the provider and existing connectors first [READ]

```powershell
$apiVersion = '2025-10-01-preview'
$provider = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'get',
    '--url', "$arm/subscriptions/$subscriptionId/providers/Microsoft.SecurityInsights?api-version=2021-04-01",
    '-o', 'json'
)
$connectorTypes = @($provider.resourceTypes | Where-Object resourceType -EQ 'dataConnectors')
if ($connectorTypes.Count -ne 1 -or $apiVersion -notin $connectorTypes[0].apiVersions) {
    throw 'The target provider does not advertise the tested connector API.'
}
$inventory = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'get',
    '--url', "$arm$sentinelPath/dataConnectors?api-version=$apiVersion",
    '--query', '{value:value[].{name:name,kind:kind,properties:{roleArn:properties.roleArn,sqsUrls:properties.sqsUrls}}}',
    '-o', 'json'
)
$inventory.value | ConvertTo-Json -Depth 10
```

Review that inventory. A queue must not be shared with another Sentinel
connector, including connectors in other workspaces or tenants. This workspace
inventory cannot detect every external consumer.

### B. Enter the two actual CloudFormation outputs

```powershell
$roleArn = Read-Host 'Paste RoleArn from CloudFormation Outputs'
$sqsUrl = Read-Host 'Paste SqsUrl from CloudFormation Outputs'
if ($roleArn -notmatch "^arn:aws:iam::${awsAccountId}:role/OIDC_") {
    throw 'Role ARN must be your dedicated OIDC_ role in the selected AWS account.'
}
if ($sqsUrl -notmatch "^https://sqs\.us-east-1\.amazonaws\.com/${awsAccountId}/[^/]+$" -or $sqsUrl.EndsWith('.fifo')) {
    throw 'Expected a standard dedicated SQS URL in the tested region/account.'
}
if (@($inventory.value | Where-Object { $sqsUrl -in @($_.properties.sqsUrls) }).Count -gt 0) {
    throw 'This workspace already has a consumer for that queue. Inspect it; do not create another.'
}
```

Check against the AWS console, not only the string checks. These abbreviated
REST snippets do not independently inspect AWS trust/policies; Step 7 does.
The optional wrapper's AWS CLI preflight is not required by this exact path.

### C. Build the actual native request

```powershell
$connectorId = [guid]::NewGuid().ToString()
$connectorUrl = "$arm$sentinelPath/dataConnectors/$connectorId`?api-version=$apiVersion"
$requestPath = Join-Path $PWD 'gcch-native-request.json'
$bindingPath = Join-Path $PWD 'gcch-native-binding.json'
if ((Test-Path -LiteralPath $requestPath) -or (Test-Path -LiteralPath $bindingPath)) {
    throw 'Request/binding files already exist. Inspect the prior deployment before continuing.'
}
$request = @{
    kind = 'AmazonWebServicesS3'
    properties = @{
        roleArn = $roleArn
        sqsUrls = @($sqsUrl)
        destinationTable = 'AWSCloudTrail'
        dataTypes = @{ logs = @{ state = 'Enabled' } }
    }
}
$request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $requestPath -Encoding utf8
@{ ConnectorId=$connectorId; ConnectorUrl=$connectorUrl; WorkspaceId="$workspaceId" } |
    ConvertTo-Json | Set-Content -LiteralPath $bindingPath -Encoding utf8
Get-Content -LiteralPath $requestPath
```

The JSON contains identifiers, not credentials. The connector ID is just a
resource name. The live test used a deterministic GUID; this walkthrough uses
a new GUID after duplicate checks for clarity. This changes the naming
convenience, not the native request properties.

### D. Review, then submit once

```powershell
if ((Read-Host 'Reviewed AWS trust, outputs, costs, and no competing consumer? Type CREATE') -cne 'CREATE') {
    throw 'Creation not confirmed.'
}
$put = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'put',
    '--url', $connectorUrl, '--body', "@$requestPath", '-o', 'json'
)
$saved = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'get',
    '--url', $connectorUrl, '-o', 'json'
)
if ($saved.kind -ne 'AmazonWebServicesS3' -or
    $saved.properties.roleArn -ne $roleArn -or
    @($saved.properties.sqsUrls).Count -ne 1 -or
    $saved.properties.sqsUrls[0] -ne $sqsUrl -or
    $saved.properties.destinationTable -ne 'AWSCloudTrail' -or
    $saved.properties.dataTypes.logs.state -ne 'Enabled') {
    throw 'Backend read-back did not match the reviewed request.'
}
$saved | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath (Join-Path $PWD 'gcch-native-response.json') -Encoding utf8
```

**What is calling what?** `az rest` obtains Azure authentication for the ARM
request and sends an HTTPS PUT to `management.usgovcloudapi.net`. ARM routes
the request to `Microsoft.SecurityInsights` at the selected workspace.
The request configures collection; it does not upload CloudTrail files.
The GET independently reads the saved configuration. PowerShell's `-ne` above
is case-insensitive, so the actual returned lowercase `enabled` is accepted.

Do not rerun creation with a new GUID after a timeout. Read the recorded
`gcch-native-binding.json` URL and inventory first: the request may have
succeeded despite the client timing out.

### E. Actual API finding, not a hypothetical example

| Requested version | Observed result |
|---|---|
| `2024-03-01` | BadRequest; error named `2020-01-01` |
| `2025-09-01` | BadRequest; error named `2024-09-01` |
| `2022-11-01` | BadRequest; error named `2020-01-01` |
| **`2025-10-01-preview`** | **Native PUT/GET accepted; real ingestion followed** |

Actual stable-version error text:

```text
Connector kind 'AmazonWebServicesS3' is not supported in api-version: '2020-01-01'
```

Sanitized excerpt of the actual successful GET:

```json
{
  "kind": "AmazonWebServicesS3",
  "properties": {
    "awsAccessKey": null,
    "awsSecretKey": null,
    "connectorDefinitionName": null,
    "dataTypes": { "logs": { "state": "enabled" } },
    "dcrConfig": null,
    "destinationTable": "AWSCloudTrail",
    "roleArn": "arn:aws:iam::<REDACTED>:role/<DEDICATED-GOVERNMENT-ROLE>",
    "sqsUrls": ["https://sqs.us-east-1.amazonaws.com/<REDACTED>/<DEDICATED-QUEUE>"]
  }
}
```

The differing API names inside errors are observed messages, not proof of
Microsoft's internal routing. Older stable inventory was incomplete compared
with preview inventory. Successful preview registration is not a support promise.

## 9. Verify AWS authentication after registration [READ]

1. Open **AWS CloudTrail -> Event history** in **us-east-1**.
2. Clear the default **Read-only = false** filter if shown.
3. Set **Lookup attributes -> Event name**.
4. Enter **AssumeRoleWithWebIdentity** and choose the deployment time window.
5. Open an event for your dedicated government role, not an unrelated Defender
   for Cloud or commercial role.
6. Inspect its request/response and error fields. Confirm role ARN and session
   `MicrosoftSentinel_<WORKSPACE-CUSTOMER-ID>`.
7. Record successful assumption time and any error. Do not publish temporary
   credentials/tokens or unredacted event details.

The live audit history showed successful government-workspace role sessions at
**12:09:34** and **12:11:08 UTC-05:00**. That is evidence of AWS authentication.
It is still not evidence that records reached Log Analytics.
Event history may lag and region/global STS behavior affects visibility;
absence from one console view alone is not proof no request occurred.

## 10. Ask the government Logs API for actual records [READ]

Use the same PowerShell session, with `$workspaceId` from Step 4.
Replace no endpoints with commercial ones.

```powershell
$query = @"
AWSCloudTrail
| where ingestion_time() > ago(2h)
| where UserIdentityAccountId == "$awsAccountId" or RecipientAccountId == "$awsAccountId"
| summarize Events=count(), LastEvent=max(TimeGenerated), LastIngested=max(ingestion_time()) by AWSRegion, EventSource
| order by LastIngested desc
"@
$queryPath = Join-Path $PWD 'gcch-query.json'
@{query=$query;timespan='PT2H'} | ConvertTo-Json |
    Set-Content -LiteralPath $queryPath -Encoding utf8
$result = Invoke-AzJson -Arguments @(
    'rest', '--subscription', $subscriptionId, '--method', 'post',
    '--url', "https://api.loganalytics.us/v1/workspaces/$workspaceId/query",
    '--resource', 'https://api.loganalytics.us',
    '--body', "@$queryPath", '-o', 'json'
)
if ($result.PSObject.Properties.Name -contains 'error') {
    throw "Query failed: $($result.error | ConvertTo-Json -Depth 10)"
}
$tables = @($result.tables | Where-Object name -EQ 'PrimaryResult')
if ($tables.Count -ne 1 -or @($tables[0].rows).Count -eq 0) {
    throw 'No matching real records yet. Ingestion is NOT verified.'
}
$table = $tables[0]
$eventColumn = [array]::IndexOf(@($table.columns.name), 'Events')
if ($eventColumn -lt 0) { throw 'Unexpected result shape: Events column missing.' }
$total = ($table.rows | ForEach-Object { $_[$eventColumn] } | Measure-Object -Sum).Sum
"Verified events: $total; grouped rows: $($table.rows.Count)"
@{
    VerifiedAtUtc=[datetime]::UtcNow.ToString('o')
    WorkspaceId="$workspaceId"
    Query=$query
    Result=$result
} | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath (Join-Path $PWD 'gcch-query-evidence.json') -Encoding utf8
```

**Why POST is still read-only:** this endpoint runs a query supplied in the
request body. It does not create a connector or ingest AWS events.
`--resource https://api.loganalytics.us` requests the appropriate government
Logs API authentication audience rather than using an ARM audience.

First live proof, copied from the saved result (all times UTC):

| AWSRegion | EventSource | Events | LastEvent | LastIngested |
|---|---|---:|---|---|
| us-west-2 | s3.amazonaws.com | 4 | 17:09:35 | 17:22:00 |
| us-east-1 | cloudtrail.amazonaws.com | 12 | 17:14:08 | 17:22:00 |
| us-east-1 | s3.amazonaws.com | 17 | 17:14:32 | 17:22:00 |
| us-east-1 | sts.amazonaws.com | 6 | 17:12:47 | 17:22:00 |
| us-east-1 | iam.amazonaws.com | 8 | 17:17:19 | 17:22:00 |

These are **five excerpt rows**, not the complete 74-event result.
Management API calls to GuardDuty/EKS/etc. can appear in CloudTrail; that does
not mean their separate data connectors or finding ingestion were enabled.

In the original bounded check, queries at 17:18:14 and 17:20:00 returned empty.
The attempt starting 17:21:50 succeeded after ingestion at 17:22:00.
We did not relabel an empty result as success or redeploy between these polls.

## 11. Show the same proof in government Defender [READ]

1. Open <https://security.microsoft.us/>.
2. Sign in to the government organization.
3. Open **Investigation & response -> Hunting -> Advanced hunting**.
4. Check **Selected workspace** at the top. Select the government workspace,
   not the working commercial workspace.
5. Select **New query**.
6. Paste the following, replacing the account placeholder:

```kusto
AWSCloudTrail
| where ingestion_time() > ago(2h)
| where UserIdentityAccountId == "<AWS-ACCOUNT-ID>"
    or RecipientAccountId == "<AWS-ACCOUNT-ID>"
| summarize Events=count(), LastEvent=max(TimeGenerated),
    LastIngested=max(ingestion_time()) by AWSRegion, EventSource
| order by LastIngested desc
```

7. Set the UI time selector to cover your test events (for example **Last 24
   hours**); the explicit KQL still restricts recent ingestion to two hours.
   A UI time restriction can additionally exclude older `TimeGenerated` values.
8. Select **Run query**.
9. Confirm nonempty rows, `Events`, `LastEvent`, and `LastIngested`.
10. Capture the selected workspace, query, result count and timestamps together.
    Record portal timezone. The original portal screenshot used UTC-05:00;
    the JSON evidence uses UTC.
11. Keep unredacted screenshots in the intended internal audience only.

The first portal verification returned the same **15 grouped rows / 74 events**
as the government Logs API. This independently demonstrated the result in
the customer-facing government portal, not only in a saved backend resource.

## 12. What keeps running after the administrator leaves?

The administrator can close PowerShell and the browser. The deployed resources
remain. CloudTrail continues delivering files, S3 continues notifying SQS,
and Microsoft's configured Sentinel collector continues using the trusted role.
No scheduled PowerShell task or local forwarding service was installed.

The later read-only query returned 183 events with a newer ingestion timestamp.
That supports continued collection after initial setup, not merely a single
manually uploaded batch. It does not establish a production SLA.

Do not infer exactly-once delivery from this test. S3/SQS notifications can be
duplicated; end-to-end deduplication/loss behavior and high-volume recovery were
not measured. Queue retention is finite; investigate prolonged backlogs promptly.

## 13. Troubleshooting: stop at the first unproven link

| Symptom | Check next | Do not do |
|---|---|---|
| Missing Content hub tile | This native backend path and provider API availability | Reinstall/uninstall unrelated content |
| Kind unsupported on stable API | Compare exact requested API/error with the observed matrix | Invent a support claim or silently switch versions |
| CloudFormation rollback | Stack Events, name collisions, IAM capability, bucket/queue policies | Continue to connector creation |
| Provider already exists | Reviewed existing-provider ARN/audience | Delete a shared provider or overwrite all audiences |
| No S3 files | Trail Logging, delivery errors, bucket policy, elapsed delivery time | Blame Sentinel first |
| Files exist; no notifications | Bucket notification prefix/suffix, queue destination/policy | Poll/purge the production queue as a shortcut |
| Failed role assumption | Correct government issuer/audience and workspace session | Broaden trust to everybody |
| Role assumed; no records yet | Backlog, role permissions, source format, collector health, elapsed time | Treat PUT or role assumption as ingestion success |
| Logs API forbidden | Government Logs audience and query permissions | Fall back to commercial workspace results |
| Portal empty; API has rows | Correct workspace, UI time range, query, timezone | Deploy a second consumer |
| Continued failure | Preserve errors/time window; engage Microsoft with evidence | Hide failures behind default success output |

Sentinel health monitoring can help where enabled/available. Enabling or
configuring health diagnostics is separate from this deployment; it was not
silently added as part of the working CloudTrail setup.

## 14. Costs, cleanup, and support boundaries

- The isolated stack adds another multi-region management-event trail.
  Additional management-event copies can incur charges.
- S3, SQS, Sentinel ingestion, and KMS if introduced have their own costs.
- No extra CloudTrail data events, organization trail, VPC/WAF/GuardDuty log
  setup was enabled by this template.
- For rollback, first identify the exact government connector and remove it
  only after approval. Stop the dedicated trail to stop new delivery.
- Inspect dependencies before deleting the stack. The bucket is intentionally
  retained; a reused OIDC provider is not owned by this stack.
- Do not delete shared or commercial resources. Follow evidence retention policy.

**Supported versus observed:** this proves a native preview-API configuration
worked in one Azure Government workspace. It does not override deprecated
solution support, establish feature parity for every AWS source, or prove this
API is available in every government region/tenant.

### Questions for the product group

1. What is the supported AWS S3 onboarding path for GCC High without the tile?
2. Is the observed `2025-10-01-preview` connector path supported for production?
3. Why do the tested stable requests reject the kind while preview accepts it?
4. What replaces the deprecated solution, including analytics/workbooks?
5. Should the official Gov ZIP's active environment constants be corrected?
6. What runtime health/support guidance applies to direct native onboarding?

## 15. What files does an admin actually need?

For **this exact console + REST method**:

1. This walkthrough.
2. The reviewed CloudFormation YAML.
3. PowerShell 7 + Azure CLI; the commands are printed above.

Microsoft's setup ZIP, the corrected upstream folder, and the optional wrapper
are **not runtime requirements for this route**. They belong to the alternative
script-based route. Tests, screenshots, API failures, and JSON results are
handover/validation evidence, not services running the connector.

The local internal appendix is `PRODUCT-GROUP-LAB-EVIDENCE.md`. It contains exact
lab bindings and links to original screenshots, untouched deployed YAML,
request/response JSON, API test matrix, and both verification snapshots.
It is deliberately not included in the public GitHub repository.

### Validation of this handover

The PowerShell snippets were parsed, the YAML was parsed, and the reproduction
template was compared structurally with the deployed original. Apart from the
documented target parameters, description, and optional existing-provider wiring,
the resource definitions match. The template's new/reused-provider wiring and
parameter patterns were checked locally. Neither branch of the new parameterized
template was newly deployed while writing this guide. That distinction matters:
local checks are not a second CloudFormation deployment or product certification.
The exact printed workspace/onboarding, provider/inventory, and Logs API query
snippets were also executed against the existing government deployment. They
completed successfully, and the query returned 210 real events. The creation
snippets were parsed but not rerun against the working environment.

## Sources

- [Microsoft AWS setup / government trust](https://learn.microsoft.com/en-us/azure/sentinel/connect-aws-configure-environment)
- [Native connector resource](https://learn.microsoft.com/en-us/azure/templates/microsoft.securityinsights/dataconnectors)
- [Solution deprecation](https://learn.microsoft.com/en-us/azure/sentinel/sentinel-solution-deprecation)
- [Microsoft's AWS-S3 source](https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/AWS-S3)
- [Repository and alternative script route](https://github.com/Cyberlorians/sentinel-aws-s3-gcch-guide)
