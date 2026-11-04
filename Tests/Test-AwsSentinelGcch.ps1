#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-AwsSentinelGcch.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "aws-sentinel-tests-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $testRoot
$common = @{
    TenantId = '11111111-1111-1111-1111-111111111111'
    SubscriptionId = '22222222-2222-2222-2222-222222222222'
    ResourceGroup = 'test-rg'; WorkspaceName = 'test-workspace'; OutputDirectory = $testRoot
}
$awsParameters = @{
    AwsPartition = 'aws'; AwsAccountId = '123456789012'; AwsRegion = 'us-east-1'
    RoleArn = 'arn:aws:iam::123456789012:role/OIDC_GcchTest'
    SqsUrl = 'https://sqs.us-east-1.amazonaws.com/123456789012/gcch-dedicated'
}
$global:GcchTest = @{}
$passed = 0

function Reset-Fixture {
    $global:GcchTest.Clear()
    $global:GcchTest.Cloud = 'AzureUSGovernment'
    $global:GcchTest.Tenant = $common.TenantId
    $global:GcchTest.ApiVersion = '2025-10-01-preview'
    $global:GcchTest.WorkspaceId = '33333333-3333-3333-3333-333333333333'
    $global:GcchTest.Audience = 'api://d4230588-5f84-4281-a9c7-2c15194b28f7'
    $global:GcchTest.Connectors = @()
    $global:GcchTest.Puts = 0
    $global:GcchTest.Rows = ,@('us-east-1', 'cloudtrail.amazonaws.com', 2, '2026-11-04T16:00:00Z', '2026-11-04T16:01:00Z')
}

function global:az {
    $a = @($args)
    $global:LASTEXITCODE = 0
    if ($global:GcchTest.ContainsKey('CliFailure')) {
        $global:LASTEXITCODE = 1
        '{"error":{"code":"Forbidden","message":"fixture access denied"}}'
        return
    }
    if ($a[0] -eq 'cloud') {
        @{name=$global:GcchTest.Cloud; endpoints=@{resourceManager='https://management.usgovcloudapi.net/'}} | ConvertTo-Json -Depth 10
        return
    }
    if ($a[0] -eq 'account') {
        @{id='22222222-2222-2222-2222-222222222222';tenantId=$global:GcchTest.Tenant;environmentName='AzureUSGovernment'} | ConvertTo-Json
        return
    }
    $url = $a[[array]::IndexOf($a, '--url') + 1]
    $method = $a[[array]::IndexOf($a, '--method') + 1]
    if ($method -eq 'put') {
        $global:GcchTest.Puts++
        $body = $a[[array]::IndexOf($a, '--body') + 1].Substring(1)
        $created = Get-Content -Raw -LiteralPath $body | ConvertFrom-Json -AsHashtable
        $created.name = (($url -split '/dataConnectors/')[1] -split '\?')[0]
        $global:GcchTest.Created = $created
        $created | ConvertTo-Json -Depth 20
        return
    }
    if ($method -eq 'post' -and $url -like 'https://api.loganalytics.us/*') {
        @{tables=@(@{name='PrimaryResult';columns=@();rows=$global:GcchTest.Rows})} | ConvertTo-Json -Depth 20
        return
    }
    if ($url -match '/workspaces/[^/]+\?') {
        @{name='test-workspace';location='usgovvirginia';properties=@{customerId=$global:GcchTest.WorkspaceId}} | ConvertTo-Json -Depth 10
    }
    elseif ($url -like '*/onboardingStates/*') { '{"name":"default","properties":{}}' }
    elseif ($url -match '/providers/Microsoft.SecurityInsights\?') {
        @{resourceTypes=@(@{resourceType='dataConnectors';apiVersions=@($global:GcchTest.ApiVersion)})} | ConvertTo-Json -Depth 10
    }
    elseif ($url -match '/dataConnectors\?') {
        @{value=$global:GcchTest.Connectors} | ConvertTo-Json -Depth 20
    }
    elseif ($url -match '/dataConnectors/') {
        $global:GcchTest.Created | ConvertTo-Json -Depth 20
    }
    else { throw "Unexpected az fixture request: $($a -join ' ')" }
}

function global:aws {
    $a = @($args)
    $global:LASTEXITCODE = 0
    switch ("$($a[0]) $($a[1])") {
        'sts get-caller-identity' { '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}' }
        'iam get-role' {
            @{
                Role=@{
                    Arn='arn:aws:iam::123456789012:role/OIDC_GcchTest'
                    AssumeRolePolicyDocument=@{
                        Statement=@(@{
                            Effect='Allow';Action='sts:AssumeRoleWithWebIdentity'
                            Principal=@{Federated='arn:aws:iam::123456789012:oidc-provider/sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/'}
                            Condition=@{StringEquals=@{
                                'sts.windows.net/cab8a31a-1906-4287-a0d8-4eef66b95f6e/:aud'=$global:GcchTest.Audience
                                'sts:RoleSessionName'="MicrosoftSentinel_$($global:GcchTest.WorkspaceId)"
                            }}
                        })
                    }
                }
            } | ConvertTo-Json -Depth 20
        }
        'iam get-open-id-connect-provider' { @{ClientIDList=@($global:GcchTest.Audience)} | ConvertTo-Json }
        'sqs get-queue-attributes' { '{"Attributes":{"QueueArn":"arn:aws:sqs:us-east-1:123456789012:gcch-dedicated"}}' }
        default { throw "Unexpected aws fixture request: $($a -join ' ')" }
    }
}

function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Expect-Error([scriptblock]$Action, [string]$Pattern) {
    $message = $null
    try { & $Action | Out-Null }
    catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notlike $Pattern) {
        throw "Expected error '$Pattern'; received '$message'."
    }
}
function Run-Case([string]$Name, [scriptblock]$Action) {
    Reset-Fixture
    & $Action
    $script:passed++
    Write-Host "PASS $Name"
}

try {
    Run-Case 'Read-only Inspect with explicit government target' {
        $result = & $scriptPath @common -Mode Inspect
        Assert-Equal $result.WorkspaceId $global:GcchTest.WorkspaceId
        Assert-Equal $result.Connectors.Count 0
        Assert-Equal $global:GcchTest.Puts 0
    }
    Run-Case 'Reject commercial Azure context' {
        $global:GcchTest.Cloud = 'AzureCloud'
        Expect-Error { & $scriptPath @common -Mode Inspect } '*AzureUSGovernment*'
    }
    Run-Case 'Reject wrong tenant' {
        $global:GcchTest.Tenant = '44444444-4444-4444-4444-444444444444'
        Expect-Error { & $scriptPath @common -Mode Inspect } '*does not match*'
    }
    Run-Case 'Reject unsupported API version' {
        $global:GcchTest.ApiVersion = '1900-01-01'
        Expect-Error { & $scriptPath @common -Mode Inspect } '*does not advertise*'
    }
    Run-Case 'CLI errors must not become success' {
        $global:GcchTest.CliFailure = $true
        Expect-Error { & $scriptPath @common -Mode Inspect } '*Forbidden*'
    }
    Run-Case 'WhatIf preflights but never PUTs or writes request' {
        & $scriptPath @common @awsParameters -Mode Connect -WhatIf | Out-Null
        Assert-Equal $global:GcchTest.Puts 0
        Assert-Equal @(Get-ChildItem -LiteralPath $testRoot -Filter '*.request.json').Count 0
    }
    Run-Case 'Government role trust rejects commercial audience' {
        $global:GcchTest.Audience = 'api://1462b192-27f7-4cb9-8523-0f4ecb54b47e'
        Expect-Error { & $scriptPath @common @awsParameters -Mode Connect } '*Role trust*'
    }
    Run-Case 'Reject mismatched SQS account' {
        $wrong = $awsParameters.Clone()
        $wrong.SqsUrl = 'https://sqs.us-east-1.amazonaws.com/999999999999/queue'
        Expect-Error { & $scriptPath @common @wrong -Mode Connect } '*standard*'
    }
    Run-Case 'Reject mismatched AWS partition and region' {
        $wrong = $awsParameters.Clone()
        $wrong.AwsPartition = 'aws-us-gov'
        Expect-Error { & $scriptPath @common @wrong -Mode Connect } '*does not match partition*'
    }
    Run-Case 'Refuse duplicate queue consumer' {
        $global:GcchTest.Connectors = @(@{name='other';kind='AmazonWebServicesS3';properties=@{sqsUrls=@($awsParameters.SqsUrl)}})
        Expect-Error { & $scriptPath @common @awsParameters -Mode Connect } '*already has a connector*'
        Assert-Equal $global:GcchTest.Puts 0
    }
    Run-Case 'Create exact backend payload and read back; rerun is idempotent' {
        & $scriptPath @common @awsParameters -Mode Connect | Out-Null
        Assert-Equal $global:GcchTest.Puts 1
        Assert-Equal $global:GcchTest.Created.kind 'AmazonWebServicesS3'
        Assert-Equal $global:GcchTest.Created.properties.destinationTable 'AWSCloudTrail'
        Assert-Equal $global:GcchTest.Created.properties.sqsUrls.Count 1
        $global:GcchTest.Connectors = @($global:GcchTest.Created)
        & $scriptPath @common @awsParameters -Mode Connect | Out-Null
        Assert-Equal $global:GcchTest.Puts 1
    }
    Run-Case 'Verification refuses empty results' {
        $global:GcchTest.Rows = @()
        Expect-Error { & $scriptPath @common -Mode Verify -AwsAccountId '123456789012' } '*NOT verified*'
    }
    Run-Case 'Verification saves real result shape without credentials' {
        $null = & $scriptPath @common -Mode Verify -AwsAccountId '123456789012'
        $evidence = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'gcch-ingestion-evidence.json') | ConvertFrom-Json
        Assert-Equal $evidence.Result.tables[0].rows[0][2] 2
        if ($evidence.Query -notlike '*123456789012*') { throw 'Query must filter the selected account.' }
    }
    Run-Case 'Prepare both official package variants with correct government constants' {
        foreach ($partition in @('aws', 'aws-us-gov')) {
            & $scriptPath @common -Mode PrepareAws -AwsPartition $partition -AwsAccountId '123456789012' `
                -AwsRegion $(if ($partition -eq 'aws') { 'us-east-1' } else { 'us-gov-west-1' }) | Out-Null
            $constants = Get-Content -Raw -LiteralPath (Join-Path $testRoot "prepared-$partition-to-gcch\Enviornment\EnviornmentConstants.ps1")
            if ($constants -notlike '*d4230588-5f84-4281-a9c7-2c15194b28f7*' -or
                $constants -notlike "*'arn:$partition'*" -or $constants -like '*1462b192*') {
                throw 'Incorrect prepared environment constants.'
            }
        }
    }
    Write-Host "$passed tests passed."
}
finally {
    Remove-Item -LiteralPath 'Function:\az'
    Remove-Item -LiteralPath 'Function:\aws'
    Remove-Variable -Name GcchTest -Scope Global
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
