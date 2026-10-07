#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ANF Throughput Metrics Collector/ANF-throughput-metrics-collector.ps1'
$scriptText = Get-Content $scriptPath -Raw
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
# Load only pure helpers for focused selection tests; no Azure modules or credentials needed.
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
$runningInAutomation = $false
$subs = @([pscustomobject]@{Id='s1';Name='First'}, [pscustomobject]@{Id='s2';Name='Second'})
Assert (@(Select-AnfDiscoverySubscriptions $subs @('s1','Second','s1')).Count -eq 2) 'Multiple selections must deduplicate by ID.'
Assert (@(Select-AnfDiscoverySubscriptions $subs @('All')).Count -eq 2) 'All should select all subscriptions.'
$threw = $false
try { Select-AnfDiscoverySubscriptions $subs @('s1','missing') } catch { $threw = $true }
Assert $threw 'A partly invalid selection must fail, not silently omit a subscription.'
$threw = $false
try { Select-AnfDiscoverySubscriptions @($subs[0], [pscustomobject]@{Id='s3';Name='First'}) @('First') } catch { $threw = $true }
Assert $threw 'Ambiguous subscription names must fail.'
function Read-Host { '1,2,1' }
Assert (@(Select-AnfDiscoverySubscriptions $subs).Count -eq 2) 'Interactive selection should support multiple numbers.'
$tenantId = 'tenant-test'
function Get-AzSubscription { param($TenantId) Assert ($TenantId -eq 'tenant-test') 'Enumeration must specify the tenant.'; $subs }
Assert (@(Get-AnfDiscoverySubscriptions @('All')).Count -eq 2) 'Tenant-scoped discovery should return both subscriptions.'
function Get-AzSubscription { throw 'Enumeration unavailable' }
$threw = $false
try { Get-AnfDiscoverySubscriptions @('All') } catch { $threw = $true }
Assert $threw 'Failed enumeration must not silently fall back to a different scope.'

# Execute the real collection/export flow with module loading and Azure transport replaced.
$testText = $scriptText
$moduleStart = $testText.IndexOf('Write-Output "Loading required Azure PowerShell modules..."')
$moduleEnd = $testText.IndexOf('function Get-AnfSetting')
$testText = $testText.Remove($moduleStart, $moduleEnd - $moduleStart)
$armFunction = $functions | Where-Object Name -eq 'Invoke-AnfArmJson'
$mockTransport = @'
function Invoke-AnfArmJson {
    param($Method, $ResourceId, $ApiVersion, $QueryString)
    Assert ($Method -eq 'GET') 'Collector must only read Azure resources.'
    if ($ResourceId -like '*/providers/microsoft.insights/metrics') {
        Assert ($QueryString -match 'interval=PT1H&aggregation=Average') 'Default collection must request hourly average buckets.'
        Assert ($QueryString -match 'VolumeAllocatedSize' -and $QueryString -match 'VolumeLogicalSize') 'Capacity metrics must be requested.'
        if ($ResourceId -like '*/empty/*' -or $script:scenario -eq 'NoData') { return [pscustomobject]@{value=@()} }
        if ($script:scenario -eq 'Failure' -and $ResourceId -like '*/zero/*') { throw 'Synthetic metric failure' }
        $values = @(
            [pscustomobject]@{name=@{value='ReadThroughput'};unit='BytesPerSecond';timeseries=@(@{data=@(@{timeStamp='2026-10-07T01:00:00Z';average=1MB})})},
            [pscustomobject]@{name=@{value='VolumeAllocatedSize'};unit='Bytes';timeseries=@(@{data=@(@{timeStamp='2026-10-07T01:00:00Z';average=2GB})})},
            [pscustomobject]@{name=@{value='VolumeLogicalSize'};unit='Bytes';timeseries=@(@{data=@(
                @{timeStamp='2026-10-07T01:05:00Z';average=0},
                @{timeStamp='2026-10-07T01:00:00Z';average=1GB},
                @{timeStamp='2026-10-07T01:10:00Z';average=$null}
            )})}
        )
        if ($script:scenario -eq 'PartialFailure') {
            $values += [pscustomobject]@{name=@{value='OtherThroughput'};errorCode='BadRequest';errorMessage='Synthetic metric error'}
        }
        return [pscustomobject]@{value=$values}
    }
    if ($script:scenario -eq 'PoolFailure' -and $ResourceId -like '/subscriptions/s1/*') { throw 'Synthetic pool failure' }
    if ($ResourceId -like '*/volumes') {
        return [pscustomobject]@{value=@('zero','empty' | ForEach-Object {
            [pscustomobject]@{id="$ResourceId/$_";name=$_;properties=@{usageThreshold=4GB}}
        })}
    }
    return [pscustomobject]@{properties=@{serviceLevel='Flexible';qosType='Manual'}}
}
'@
$testText = $testText.Replace($armFunction.Extent.Text, $mockTransport)
function Get-AzContext { [pscustomobject]@{Account=@{Id='test'};Tenant=@{Id='tenant-test'};Subscription=@{Id='s1';Name='First'}} }
function Disable-AzContextAutosave {}
$script:contexts = @()
function Set-AzContext {
    param($SubscriptionId, $TenantId)
    Assert ($TenantId -eq 'tenant-test') 'Pool context must stay within the tenant.'
    $script:contexts += $SubscriptionId
}
function Connect-AzAccount { throw 'Tests must never authenticate to Azure.' }
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$null = New-Item -ItemType Directory $tempRoot
$environmentNames = @('AUTOMATION_ASSET_ACCOUNTID') + @([regex]::Matches($scriptText, 'ANF_[A-Za-z]+') | ForEach-Object Value | Sort-Object -Unique)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $null)
}
try {
    $env:ANF_CapacityPoolResourceId = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.NetApp/netAppAccounts/account/capacityPools/pool;/subscriptions/s2/resourceGroups/rg/providers/Microsoft.NetApp/netAppAccounts/account/capacityPools/pool'
    foreach ($scenario in @('Success','NoData','Failure','PartialFailure','PoolFailure')) {
        $script:scenario = $scenario
        $env:ANF_OutputPath = Join-Path $tempRoot "$scenario.csv"
        $threw = $false
        try { & ([scriptblock]::Create($testText)) | Out-Null } catch { $threw = $true; if ($scenario -in @('Success','NoData')) { throw } }
        Assert ($threw -eq ($scenario -in @('Failure','PartialFailure','PoolFailure'))) 'Failures must be reported after exporting available results.'
        $summaryPath = [IO.Path]::ChangeExtension($env:ANF_OutputPath, 'volumes.csv')
        $summary = @(Import-Csv $summaryPath)
        $expectedVolumes = if ($scenario -eq 'PoolFailure') { 2 } else { 4 }
        $expectedSubscriptions = if ($scenario -eq 'PoolFailure') { 1 } else { 2 }
        Assert ($summary.Count -eq $expectedVolumes) 'Every volume in both subscriptions must be included, even without metrics.'
        Assert (($summary.SubscriptionId | Sort-Object -Unique).Count -eq $expectedSubscriptions) 'Same-named volumes from different subscriptions must remain distinct.'
        Assert ($summary[0].AllocatedGiB -eq '4') 'Current allocation must come from volume quota.'
        if ($scenario -eq 'Success') {
            $used = @($summary | Where-Object VolumeName -eq 'zero')
            Assert ($used[0].UsedBytes -eq '0') 'Measured zero usage must not become blank.'
            Assert ($used[0].UsedMetricTimestamp -eq '2026-10-07T01:05:00Z') 'Latest non-null usage must win, regardless of sample order.'
            Assert (($summary | Where-Object VolumeName -eq 'empty')[0].UsedBytes -eq '') 'Missing usage must remain blank.'
            $rows = @(Import-Csv $env:ANF_OutputPath)
            $consumed = @($rows | Where-Object MetricName -eq 'VolumeConsumedSize')
            Assert ($consumed.Count -eq 4 -and $consumed[0].ApiMetricName -eq 'VolumeLogicalSize') 'Consumed capacity must use the requested CSV label and retain the Azure API name.'
            $capacity = @($rows | Where-Object MetricName -eq 'VolumeAllocatedSize')
            Assert ($capacity[0].AverageGiB -eq '2' -and $capacity[0].AverageMiBps -eq '') 'Capacity history must not be converted to throughput.'
            $throughput = @($rows | Where-Object MetricName -eq 'ReadThroughput')
            Assert ($throughput[0].VolumeAllocatedSize -eq '2147483648' -and $throughput[0].VolumeConsumedSize -eq '1073741824') 'Throughput rows must include capacity values joined by timestamp.'
            $zeroRows = @($rows | Where-Object { $_.MetricName -eq 'VolumeConsumedSize' -and $_.AverageBytes -eq '0' })
            Assert ($zeroRows[0].VolumeConsumedSize -eq '0' -and $zeroRows[0].VolumeAllocatedSize -eq '') 'Missing matching allocation must stay blank while measured zero consumption is preserved.'
            Assert ($throughput[0].AverageMiBps -eq '1' -and $throughput[0].AverageGiB -eq '') 'Throughput conversion must remain intact.'
        }
        if ($scenario -eq 'NoData') { Assert (-not (Test-Path $env:ANF_OutputPath)) 'No-data runs should only write the summary.' }
    }
    Assert ($script:contexts -contains 's1' -and $script:contexts -contains 's2') 'Both explicit subscription contexts must be processed.'
    $env:ANF_OutputPath = Join-Path $tempRoot 'NoData.csv'
    $threw = $false
    try { & ([scriptblock]::Create($testText)) | Out-Null } catch { $threw = $_.Exception.Message -like '*Output file already exists*' }
    Assert $threw 'Existing companion summary must be protected even if the metrics CSV does not exist.'
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Item $tempRoot -Recurse -Force
}
Write-Output 'ANF-Throughput-Metrics-Collector behavior checks passed.'
