#requires -Version 7.0
<#
.SYNOPSIS
Prepares Microsoft's AWS setup scripts and manages a CloudTrail S3 connector in Azure Government.
.DESCRIPTION
Inspect is read-only. PrepareAws creates a corrected local copy of the pinned upstream
commercial package; it does not run that package. Connect requires AWS CLI preflight,
creates only a new backend connector, and refuses conflicting queue consumers.
Verify requires actual recent ingested events. No Content hub solution is installed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect', 'PrepareAws', 'Connect', 'Verify')][string]$Mode,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkspaceName,
    [ValidateSet('aws', 'aws-us-gov')][string]$AwsPartition,
    [ValidatePattern('^\d{12}$')][string]$AwsAccountId,
    [string]$AwsRegion,
    [string]$AwsProfile,
    [string]$RoleArn,
    [string]$SqsUrl,
    [string]$OutputDirectory = $PSScriptRoot,
    [ValidateRange(1, 24)][int]$LookbackHours = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$apiVersion = '2025-10-01-preview'
$arm = 'https://management.usgovcloudapi.net'
$issuer = 'sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/'
$audience = 'api://d4230588-5f84-4281-a9c7-2c15194b28f7'
$archiveHash = '0586346CA75A79F04E59AFAD778499F50F1C1383A4672A3405CB3E132DC2377F'

function Invoke-JsonCli {
    param([string]$Command, [string[]]$Arguments)
    # Read-only WhatIf preflight still needs temporary stderr capture and cleanup.
    $WhatIfPreference = $false
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required CLI '$Command' is missing. Install it and authenticate explicitly; browser sign-in is not CLI sign-in."
    }
    $stderrFile = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).stderr"
    $previousEncoding = $env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        $global:LASTEXITCODE = 0
        $text = (& $Command @Arguments 2> $stderrFile | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrFile) { [IO.File]::ReadAllText($stderrFile).Trim() } else { '' }
    }
    finally {
        $env:PYTHONIOENCODING = $previousEncoding
        if (Test-Path -LiteralPath $stderrFile) { Remove-Item -LiteralPath $stderrFile }
    }
    if ($exitCode -ne 0) { throw "$Command failed (exit $exitCode): $stderr $text" }
    if ($stderr) { Write-Warning "$Command stderr: $stderr" }
    if (-not $text) { throw "$Command returned no JSON response." }
    try { return ConvertFrom-Json -InputObject $text -AsHashtable }
    catch { throw "$Command returned invalid JSON ($($text.Length) characters): $($_.Exception.Message)" }
}

function Invoke-ArmGet {
    param([string]$Path, [string]$Query)
    $arguments = @('rest', '--subscription', "$SubscriptionId", '--method', 'get', '--url', "$arm$Path", '--output', 'json')
    if ($Query) { $arguments += @('--query', $Query) }
    Invoke-JsonCli az $arguments
}

function Invoke-AwsGet {
    param([string[]]$Arguments)
    $cliArguments = @($Arguments) + @('--region', $AwsRegion, '--output', 'json', '--no-cli-pager')
    if ($AwsProfile) { $cliArguments += @('--profile', $AwsProfile) }
    Invoke-JsonCli aws $cliArguments
}

function Assert-AwsSelection {
    if (-not $AwsPartition -or -not $AwsAccountId -or -not $AwsRegion) {
        throw 'Supply AwsPartition, AwsAccountId, and AwsRegion explicitly.'
    }
    if (($AwsPartition -eq 'aws' -and $AwsRegion -notmatch '^(us|eu|ap|sa|ca|me|af|il|mx)-[a-z]+-\d+$') -or
        ($AwsPartition -eq 'aws-us-gov' -and $AwsRegion -notmatch '^us-gov-(east|west)-1$')) {
        throw "Region '$AwsRegion' does not match partition '$AwsPartition'."
    }
}

$cloud = Invoke-JsonCli az @('cloud', 'show', '--output', 'json')
if ($cloud.name -ne 'AzureUSGovernment' -or
    $cloud.endpoints.resourceManager.TrimEnd('/') -ne $arm) {
    throw 'Azure CLI must explicitly use AzureUSGovernment. This script never switches cloud or account for you.'
}
$account = Invoke-JsonCli az @('account', 'show', '--subscription', "$SubscriptionId", '--output', 'json')
if ($account.tenantId -ne "$TenantId" -or $account.id -ne "$SubscriptionId" -or
    $account.environmentName -ne 'AzureUSGovernment') {
    throw 'Authenticated subscription/tenant/environment does not match the requested government target.'
}
$base = "/subscriptions/$SubscriptionId/resourceGroups/$([uri]::EscapeDataString($ResourceGroup))"
$workspacePath = "$base/providers/Microsoft.OperationalInsights/workspaces/$([uri]::EscapeDataString($WorkspaceName))"
$workspace = Invoke-ArmGet "$workspacePath`?api-version=2022-10-01"
$workspaceId = [guid]$workspace.properties.customerId
$sentinelPath = "$workspacePath/providers/Microsoft.SecurityInsights"
$null = Invoke-ArmGet "$sentinelPath/onboardingStates/default?api-version=2024-03-01"
$provider = Invoke-ArmGet "/subscriptions/$SubscriptionId/providers/Microsoft.SecurityInsights?api-version=2021-04-01"
$connectorType = @($provider.resourceTypes | Where-Object resourceType -EQ 'dataConnectors')
if ($connectorType.Count -ne 1 -or $apiVersion -notin $connectorType[0].apiVersions) {
    throw "Government provider does not advertise connector API $apiVersion. Stop rather than guessing another version."
}
$inventory = Invoke-ArmGet "$sentinelPath/dataConnectors?api-version=$apiVersion" `
    '{value:value[].{name:name,kind:kind,properties:{roleArn:properties.roleArn,sqsUrls:properties.sqsUrls,destinationTable:properties.destinationTable,dataTypes:properties.dataTypes}}}'
if (-not $inventory.ContainsKey('value')) { throw 'Connector inventory response has no value array.' }

if ($Mode -eq 'Inspect') {
    [pscustomobject]@{
        Cloud = $cloud.name; TenantId = "$TenantId"; SubscriptionId = "$SubscriptionId"
        Workspace = $workspace.name; WorkspaceId = "$workspaceId"; Location = $workspace.location
        ApiVersion = $apiVersion
        Connectors = @($inventory.value | ForEach-Object { @{ Name = $_.name; Kind = $_.kind; Properties = $_.properties } })
        Warning = 'API version availability does not prove that the AWS S3 backend accepts new connectors or that ingestion works.'
    }
    return
}

if ($Mode -eq 'PrepareAws') {
    Assert-AwsSelection
    $archive = Join-Path $PSScriptRoot 'ConfigAwsS3DataConnectorScripts.zip'
    if (-not (Test-Path -LiteralPath $archive)) { throw "Missing pinned official package: $archive. See the guide." }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) {
        throw 'Official package checksum differs from the reviewed snapshot. Review the new package before changing the pinned hash.'
    }
    $destination = Join-Path $OutputDirectory "prepared-$AwsPartition-to-gcch"
    if (Test-Path -LiteralPath $destination) { throw "Refusing to overwrite existing prepared scripts: $destination" }
    if ($PSCmdlet.ShouldProcess($destination, 'Extract official scripts and replace only environment constants for Azure Government')) {
        $staging = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        try {
            $null = New-Item -ItemType Directory -Path $staging
            Expand-Archive -LiteralPath $archive -DestinationPath $staging
            $nestedName = if ($AwsPartition -eq 'aws') { 'ConfigAwsComToAzureCom.zip' } else { 'ConfigAwsGovToAzureCom.zip' }
            Expand-Archive -LiteralPath (Join-Path $staging $nestedName) -DestinationPath $destination
            $cloudEnv = if ($AwsPartition -eq 'aws') { 'Com' } else { 'Gov' }
            $constantsPath = Join-Path $destination 'Enviornment\EnviornmentConstants.ps1'
            $constants = Get-Content -LiteralPath $constantsPath -Raw
            $settings = @{
                SentinelClientId = $audience
                SentinelTenantId = 'cab8a31a-1906-4287-a0d8-4eef66b95f6e'
                CloudEnv = $cloudEnv
                AwsCloudResource = "arn:$AwsPartition"
            }
            foreach ($setting in $settings.GetEnumerator()) {
                $pattern = '(?m)^([ \t]*\$script:{0}[ \t]*=[ \t]*)''[^'']*''' -f $setting.Key
                if ([regex]::Matches($constants, $pattern).Count -ne 1) {
                    throw "Expected one active assignment for $($setting.Key) in the pinned commercial package."
                }
                $constants = [regex]::Replace($constants, $pattern, {
                    param($match)
                    $match.Groups[1].Value + "'$($setting.Value)'"
                })
            }
            Set-Content -LiteralPath $constantsPath -Value $constants -Encoding utf8 -NoNewline
        }
        finally {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        }
        Write-Output "Prepared: $destination"
        Write-Output "Workspace ID for the upstream prompt: $workspaceId"
        Write-Warning 'The upstream scripts are interactive and can alter AWS policies/logging. Review them and run separately, with dedicated resources. Preparation is not deployment.'
    }
    return
}

if (-not $AwsAccountId) { throw 'Supply AwsAccountId for account-filtered verification or connection.' }
$query = @"
AWSCloudTrail
| where ingestion_time() > ago(${LookbackHours}h)
| where UserIdentityAccountId == "$AwsAccountId" or RecipientAccountId == "$AwsAccountId"
| summarize Events=count(), LastEvent=max(TimeGenerated), LastIngested=max(ingestion_time()) by AWSRegion, EventSource
| order by LastIngested desc
"@

if ($Mode -eq 'Verify') {
    if ($WhatIfPreference) { Write-Output $query; return }
    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).json"
    try {
        @{ query = $query; timespan = "PT${LookbackHours}H" } | ConvertTo-Json |
            Set-Content -LiteralPath $bodyFile -Encoding utf8
        $result = Invoke-JsonCli az @(
            'rest', '--subscription', "$SubscriptionId", '--method', 'post', '--url', "https://api.loganalytics.us/v1/workspaces/$workspaceId/query"
            '--resource', 'https://api.loganalytics.us', '--body', "@$bodyFile", '--output', 'json'
        )
    }
    finally { if (Test-Path -LiteralPath $bodyFile) { Remove-Item -LiteralPath $bodyFile } }
    if ($result.ContainsKey('error')) { throw "Log query returned an error: $($result.error | ConvertTo-Json -Depth 20 -Compress)" }
    $tables = @($result.tables | Where-Object name -EQ 'PrimaryResult')
    if ($tables.Count -ne 1 -or @($tables[0].rows).Count -eq 0) {
        throw "No recent ingested CloudTrail events for $AwsAccountId. Ingestion is NOT verified."
    }
    if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Save successful account-filtered ingestion evidence')) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
        @{ VerifiedAtUtc = [datetime]::UtcNow.ToString('o'); WorkspaceId = "$workspaceId"; Query = $query; Result = $result } |
            ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'gcch-ingestion-evidence.json') -Encoding utf8
    }
    $result
    return
}

Assert-AwsSelection
if ($RoleArn -notmatch "^arn:$([regex]::Escape($AwsPartition)):iam::$AwsAccountId`:role/OIDC_[A-Za-z0-9_+=,.@-]+$") {
    throw 'RoleArn must be an explicit OIDC_ role in the selected AWS account and partition (no role path).'
}
$queueUri = $null
if (-not [uri]::TryCreate($SqsUrl, [UriKind]::Absolute, [ref]$queueUri) -or
    $queueUri.Scheme -ne 'https' -or $queueUri.Host -cne "sqs.$AwsRegion.amazonaws.com" -or
    $queueUri.AbsolutePath -notmatch "^/$AwsAccountId/[A-Za-z0-9_-]+$" -or
    $queueUri.Query -or $queueUri.Fragment -or $queueUri.UserInfo -or -not $queueUri.IsDefaultPort) {
    throw 'Supply a standard (not FIFO) SQS HTTPS URL in the selected account and region.'
}
$identity = Invoke-AwsGet @('sts', 'get-caller-identity')
if ($identity.Account -ne $AwsAccountId -or $identity.Arn -notlike "arn:$AwsPartition`:*") {
    throw 'AWS CLI identity does not match the explicitly selected account and partition.'
}
$roleName = ($RoleArn -split '/')[-1]
$role = Invoke-AwsGet @('iam', 'get-role', '--role-name', $roleName)
if ($role.Role.Arn -ne $RoleArn) { throw 'AWS returned a different role ARN.' }
$providerArn = "arn:$AwsPartition`:iam::$AwsAccountId`:oidc-provider/$issuer"
$trustMatches = @($role.Role.AssumeRolePolicyDocument.Statement | Where-Object {
    $_.Effect -eq 'Allow' -and @($_.Action) -contains 'sts:AssumeRoleWithWebIdentity' -and
    $_.Principal.Federated -eq $providerArn -and
    $_.Condition.StringEquals["${issuer}:aud"] -eq $audience -and
    $_.Condition.StringEquals['sts:RoleSessionName'] -eq "MicrosoftSentinel_$workspaceId"
})
if ($trustMatches.Count -eq 0) { throw 'Role trust does not bind the government Sentinel audience and this workspace session name.' }
$oidc = Invoke-AwsGet @('iam', 'get-open-id-connect-provider', '--open-id-connect-provider-arn', $providerArn)
if ($audience -notin $oidc.ClientIDList) { throw 'Government Sentinel audience is absent from the AWS OIDC provider.' }
$queue = Invoke-AwsGet @('sqs', 'get-queue-attributes', '--queue-url', $SqsUrl, '--attribute-names', 'QueueArn')
if ($queue.Attributes.QueueArn -ne "arn:$AwsPartition`:sqs:$AwsRegion`:$AwsAccountId`:$($queueUri.Segments[-1])") {
    throw 'SQS returned an unexpected queue ARN.'
}
$hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$workspaceId|$RoleArn|$SqsUrl|AWSCloudTrail"))
$connectorId = [guid]::new([byte[]]$hash[0..15]).ToString()
$connectorPath = "$sentinelPath/dataConnectors/$connectorId`?api-version=$apiVersion"
$sameQueue = @($inventory.value | Where-Object { $_.properties.ContainsKey('sqsUrls') -and $SqsUrl -in $_.properties.sqsUrls })
if ($sameQueue.Count -gt 0) {
    if ($sameQueue.Count -eq 1 -and $sameQueue[0].name -eq $connectorId -and
        $sameQueue[0].kind -eq 'AmazonWebServicesS3' -and
        $sameQueue[0].properties.roleArn -eq $RoleArn -and
        $sameQueue[0].properties.destinationTable -eq 'AWSCloudTrail' -and
        $sameQueue[0].properties.dataTypes.logs.state -eq 'Enabled' -and
        @($sameQueue[0].properties.sqsUrls).Count -eq 1) {
        Write-Output 'Matching enabled backend connector already exists. Run Verify to establish ingestion.'
        return
    }
    throw 'This workspace already has a connector consuming this queue. Refusing to duplicate or overwrite it.'
}
if (@($inventory.value | Where-Object name -EQ $connectorId).Count -gt 0) {
    throw 'Connector ID is already occupied. Refusing to overwrite it.'
}
$payload = @{
    kind = 'AmazonWebServicesS3'
    properties = @{
        roleArn = $RoleArn; sqsUrls = @($SqsUrl); destinationTable = 'AWSCloudTrail'
        dataTypes = @{ logs = @{ state = 'Enabled' } }
    }
}
if ($PSCmdlet.ShouldProcess("$arm$connectorPath", 'Create government AWS S3 backend connector (no Content hub package)')) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $payloadFile = Join-Path $OutputDirectory "gcch-connector-$connectorId.request.json"
    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $payloadFile -Encoding utf8
    $null = Invoke-JsonCli az @('rest', '--subscription', "$SubscriptionId", '--method', 'put', '--url', "$arm$connectorPath", '--body', "@$payloadFile", '--output', 'json')
    $created = Invoke-ArmGet $connectorPath
    if ($created.kind -ne 'AmazonWebServicesS3' -or $created.properties.roleArn -ne $RoleArn -or
        $created.properties.destinationTable -ne 'AWSCloudTrail' -or
        $created.properties.dataTypes.logs.state -ne 'Enabled' -or
        @($created.properties.sqsUrls).Count -ne 1 -or $created.properties.sqsUrls[0] -ne $SqsUrl) {
        throw 'Backend read-back did not match the requested connector. Inspect the resource before retrying.'
    }
    $created | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory "gcch-connector-$connectorId.response.json") -Encoding utf8
    Write-Output "Backend connector saved: $connectorId. Ingestion is NOT yet verified; run -Mode Verify."
}
