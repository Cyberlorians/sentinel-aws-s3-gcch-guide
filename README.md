# AWS CloudTrail S3 ingestion into Microsoft Sentinel GCC High

Deploy the native AWS S3 backend connector when the general AWS Content hub
solution/connector tile is missing or deprecated in Azure Government.

**Verified November 4, 2026:** a live AWS-commercial-to-Azure-Government test
ingested 74 CloudTrail events into `AWSCloudTrail`. Both the government Logs
API and government Defender Advanced hunting returned the same 15 grouped
rows. Fourteen local regression tests passed. Customer identifiers, raw lab
evidence, and screenshots are intentionally excluded from this public repository.

This is a tested implementation guide, not a Microsoft support commitment.
Preview API functionality does not restore support for deprecated solutions.
Confirm production support and compliance authorization with Microsoft and your
organization before deployment.

## Is it identical to commercial?

| Surface | Commercial | This government deployment |
|---|---|---|
| Collection pipeline | CloudTrail -> S3 -> SQS -> Sentinel | Same architecture |
| Destination table | `AWSCloudTrail` | Same table and account-filtered KQL |
| Setup interface tested | General AWS S3 connector UI | Native backend ARM request; missing tile not required |
| ARM host | `management.azure.com` | `management.usgovcloudapi.net` |
| Logs API host | `api.loganalytics.io` | `api.loganalytics.us` |
| AWS trust | Commercial Sentinel service issuer/audience | Government Sentinel service issuer/audience |
| Connector API used here | Commercial portal-managed operation | `2025-10-01-preview` |
| Content hub rules/workbooks | Depends on installed solution | Not installed by this workflow |

It is **functionally equivalent for the tested CloudTrail management-event
ingestion**, not identical in provisioning, portal experience, support status,
or a certification of every AWS log type or production-scale behavior.
No commercial resource configuration was changed for the government test.

GCC High is the destination. It does not imply that the AWS source account is
AWS GovCloud. Choose the actual source partition explicitly.

## Files and prerequisites

- [Invoke-AwsSentinelGcch.ps1](Invoke-AwsSentinelGcch.ps1): `Inspect`,
  `PrepareAws`, `Connect`, and `Verify`.
- [Regression tests](Tests/Test-AwsSentinelGcch.ps1): mocked CLI tests, no
  cloud writes. Download the pinned official ZIP before running them.
- PowerShell 7+, Azure CLI authenticated in AzureUSGovernment, and an existing
  Sentinel-enabled Log Analytics workspace.
- AWS CLI v2 with approved SSO/temporary credentials for provisioning and
  connection preflight. Browser authentication is not AWS CLI authentication.
- Azure permissions to read workspace/provider metadata, manage Sentinel
  connectors, and query logs. AWS provisioning permissions for the dedicated
  CloudTrail/S3/SQS/IAM resources; preflight uses STS GetCallerIdentity, IAM
  GetRole/GetOpenIDConnectProvider, and SQS GetQueueAttributes.

Do not use AWS root, embed credentials, or change machine-wide execution policy
to Unrestricted. Follow organization signing, data export, and access policies.
Do not publish generated request/response evidence without reviewing identifiers.

## 1. Authenticate and inspect

Clone/download this repository, then run in its directory:

```powershell
az cloud set --name AzureUSGovernment
$tenant = Read-Host 'Government organization tenant ID'
az login --tenant $tenant
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed.' }

$target = @{
    TenantId       = $tenant
    SubscriptionId = Read-Host 'Government subscription ID'
    ResourceGroup  = Read-Host 'Sentinel workspace resource group'
    WorkspaceName  = Read-Host 'Sentinel workspace name'
}
.\Invoke-AwsSentinelGcch.ps1 @target -Mode Inspect | ConvertTo-Json -Depth 20
```

Confirm cloud, tenant, workspace, and workspace customer ID. The script never
switches cloud/account for you and passes the subscription explicitly.

## 2. Download and prepare Microsoft's AWS scripts

```powershell
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/DataConnectors/AWS-S3/ConfigAwsS3DataConnectorScriptsGov.zip' `
  -OutFile .\ConfigAwsS3DataConnectorScriptsGov.zip
Get-FileHash .\ConfigAwsS3DataConnectorScriptsGov.zip -Algorithm SHA256

$awsTarget = @{
    AwsPartition = Read-Host 'Actual source partition: aws or aws-us-gov'
    AwsAccountId = Read-Host 'Source AWS account ID (12 digits)'
    AwsRegion    = Read-Host 'Source AWS region'
}
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget -Mode PrepareAws -WhatIf
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget -Mode PrepareAws
```

Reviewed ZIP SHA-256:
`5522D4324F8A36EE0315E372AF9594280B120D3170258A88DD26196BF7CEF56A`.
The upstream `master` URL is mutable: a different checksum fails deliberately.
Review changed contents before updating the pin; do not bypass verification.
The Microsoft ZIP is downloaded from its source, not redistributed here.

**Packaging finding:** both reviewed nested Gov packages had commercial
ComToProd constants active. `PrepareAws` extracts the selected variant into a
new folder and changes only `Enviornment\EnviornmentConstants.ps1`. The original
ZIP is unchanged. Existing prepared folders are not overwritten.

| Government setting | Value |
|---|---|
| Sentinel service issuer | `sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/` |
| Sentinel service audience | `api://d4230588-5f84-4281-a9c7-2c15194b28f7` |
| Required role session | `MicrosoftSentinel_<workspace-customer-ID>` |
| AWS commercial source | `CloudEnv=Com`, `AwsCloudResource=arn:aws` |
| AWS GovCloud source | `CloudEnv=Gov`, `AwsCloudResource=arn:aws-us-gov` |

These are Microsoft service identifiers, not your organization tenant ID.

## 3. Provision dedicated AWS resources

Review the prepared scripts before running them: upstream code is interactive
and can modify policies, notifications, or existing logging.

```powershell
$awsProfile = Read-Host 'Approved AWS CLI profile'
aws sts get-caller-identity --profile $awsProfile `
  --region $awsTarget.AwsRegion --no-cli-pager
if ($LASTEXITCODE -ne 0) { throw 'AWS identity check failed.' }

$env:AWS_PROFILE = $awsProfile
$env:AWS_REGION = $awsTarget.AwsRegion
$prepared = Join-Path $PWD "prepared-$($awsTarget.AwsPartition)-to-gcch"
Push-Location $prepared
try {
    .\ConfigAwsConnector.ps1 -AwsLogType CloudTrail
}
finally {
    Pop-Location
}
```

Before provisioning, verify that STS returns the intended account/partition.
At the prompts:

1. Use the government **workspace customer ID**, not a tenant/subscription ID.
2. Use a dedicated `OIDC_` role, standard SQS queue, bucket and trail. Do not
   modify the working commercial connection.
3. Configure the correct government OIDC audience and workspace-bound role
   session. Preserve existing audiences if reusing a provider.
4. Choose CloudTrail management events for this tested scope. Data events,
   organization trails, GuardDuty, VPC, and WAF are outside this validation.
5. If using KMS, review both role permissions and the KMS key policy.
6. Record the role ARN and SQS URL. Verify CloudTrail Logging and successful
   S3 delivery, object notifications, and queue permissions.

**Never share a queue between commercial and government consumers.** They
compete for messages. The script detects duplicates within the selected
workspace, not across every tenant/workspace.

The original live validation provisioned isolated AWS resources through
CloudFormation in the authenticated AWS console, then used Azure CLI for the
backend PUT/GET. The prepared upstream-script path above was regression-tested,
not executed as that live provisioning run. Its successful preparation alone
is not proof of deployment or ingestion.

## 4. Create the connector without the portal tile

```powershell
$connection = @{
    RoleArn    = Read-Host 'Government-bound OIDC_ role ARN'
    SqsUrl     = Read-Host 'Dedicated SQS URL'
    AwsProfile = $awsProfile
}
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect -WhatIf
.\Invoke-AwsSentinelGcch.ps1 @target @awsTarget @connection -Mode Connect
```

The workflow checks explicit AWS identity/partition/region, government role
trust, OIDC provider audience, workspace-bound session, and queue identity.
It refuses conflicting consumers/overwrites, uses a deterministic connector ID,
and reads back the exact properties. An identical enabled resource is a no-op.
WhatIf performs read-only preflight, without PUT or persistent output writes.
Temporary CLI diagnostic files are cleaned up.

The request uses native `kind: AmazonWebServicesS3` with `roleArn`, one
`sqsUrls` entry, `destinationTable: AWSCloudTrail`, and
`dataTypes.logs.state: Enabled`. It installs no Content hub content.

### Critical API-version finding

| Requested government API | Observed live result |
|---|---|
| `2024-03-01` | Kind rejected; error named `2020-01-01` |
| `2025-09-01` | Kind rejected; error named `2024-09-01` |
| `2025-10-01-preview` | PUT and GET succeeded; subsequent ingestion verified |
| `2022-11-01` | Kind rejected; error named `2020-01-01` |

These are observations, not an explanation of Microsoft's internal routing.
Do not silently substitute a stable version. An older API's empty inventory
did not establish that no preview connector existed. The workflow checks
provider advertisement, but that alone does not establish runtime support.

## 5. Verify real government ingestion

```powershell
.\Invoke-AwsSentinelGcch.ps1 @target -Mode Verify `
  -AwsAccountId $awsTarget.AwsAccountId -LookbackHours 2
```

Verify uses `https://api.loganalytics.us`, the actual workspace customer ID,
and recent ingestion time. Empty results fail explicitly; successful results
are saved as `gcch-ingestion-evidence.json`. The account-filtered KQL is:

```kusto
AWSCloudTrail
| where ingestion_time() > ago(2h)
| where UserIdentityAccountId == "<AWS-ACCOUNT-ID>"
    or RecipientAccountId == "<AWS-ACCOUNT-ID>"
| summarize Events=count(), LastEvent=max(TimeGenerated),
    LastIngested=max(ingestion_time()) by AWSRegion, EventSource
| order by LastIngested desc
```

Use the government workspace in `security.microsoft.us`. Grouped rows are not
raw event counts: sum `Events`. In the live test, 15 grouped rows represented
74 events, last ingested **2026-11-04 17:22:00 UTC**. Initial empty polls were
not treated as success. Allow time for source delivery and collection; do not
recreate the connector just because the first query is empty.

If results stay empty, check source delivery, S3 notification filters, queue
backlog, role assumption, IAM/KMS permissions, and Sentinel health information.
Do not purge/consume the queue as a troubleshooting shortcut. Preserve exact
errors for Microsoft support. One successful batch is point-in-time proof,
not an availability or latency SLA.

## Validation

After downloading the pinned official ZIP:

```powershell
.\Tests\Test-AwsSentinelGcch.ps1
```

Fourteen tests cover context guards, CLI/API errors, WhatIf, government trust,
AWS account/partition mismatches, duplicate queues, exact payload/read-back,
idempotency, empty/successful query results, and both upstream package variants.
Mocks do not substitute for real AWS deployment and government ingestion.

## Cost and rollback

Additional management-event trails can incur duplicate trail charges. S3,
SQS, Sentinel ingestion, and KMS where applicable may also incur charges.
Do not enable additional event types without deliberate approval.

For rollback, identify and remove only the dedicated government connector,
then stop the dedicated CloudTrail trail. Review dependencies before deleting
AWS resources or a potentially shared OIDC provider. Preserve source evidence
according to retention policy. Never delete the commercial connector/queue.

## Official references

- [AWS S3 setup and government OIDC settings](https://learn.microsoft.com/en-us/azure/sentinel/connect-aws-configure-environment)
- [Sentinel cloud feature availability](https://learn.microsoft.com/en-us/azure/sentinel/feature-availability)
- [Solution deprecation](https://learn.microsoft.com/en-us/azure/sentinel/sentinel-solution-deprecation)
- [Native data connector resource](https://learn.microsoft.com/en-us/azure/templates/microsoft.securityinsights/dataconnectors)
- [Microsoft's AWS-S3 source directory](https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/AWS-S3)
