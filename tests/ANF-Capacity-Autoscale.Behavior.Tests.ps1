#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ANF Capacity Autoscale/ANF-Capacity-Autoscale.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)

# Supply settings and ARM responses locally while running the real planning and write paths.
foreach ($name in 'Get-AnfSetting', 'Invoke-AnfArmJson') {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    $source = $source.Replace($definition.Extent.Text, '')
}
$runbook = [scriptblock]::Create($source)
$poolId = '/subscriptions/test/resourceGroups/test/providers/Microsoft.NetApp/netAppAccounts/test/capacityPools/test'
$settings = @{}
$usedBytes = 0
function Get-AnfSetting($Name, $Default) {
    if ($settings.ContainsKey($Name)) { return $settings[$Name] }
    switch ($Name) {
        'ANF_CapacityPoolResourceId' { return $poolId }
        'ANF_TestMode' { return 'No' }
        default { return $Default }
    }
}
function Import-Module {}
function Disable-AzContextAutosave {}
function Connect-AzAccount {}
function Set-AzContext {}
function Get-AzContext { return @{ Account = @{ Id = 'test' }; Subscription = @{ Id = 'test' } } }

function Invoke-AnfArmJson($Method, $ResourceId, $ApiVersion, $QueryString, $BodyJson) {
    if ($ResourceId -like '*/providers/microsoft.insights/metrics') {
        $metric = @{ timeseries = @(@{ data = @(@{ average = $usedBytes }) }) }
        if ($ResourceId -like '*/volumes/unmeasured/*') {
            switch ($scenario) {
                'Empty'       { return @{ value = @() } }
                'NullSamples' { $metric.timeseries[0].data = @(@{ average = $null }) }
                'QueryFailed' { throw 'Simulated Azure Monitor failure' }
                'MetricError' { $metric.errorCode = 'BadRequest' }
            }
        }
        return @{ value = @($metric) }
    }
    if ($Method -eq 'PATCH') {
        $writes.Add($ResourceId)
        $properties = ($BodyJson | ConvertFrom-Json -AsHashtable).properties
        foreach ($key in $properties.Keys) { $resources[$ResourceId].properties[$key] = $properties[$key] }
        return
    }
    if ($ResourceId -eq "$poolId/volumes") { return @{ value = $fixtureVolumes } }
    if ($resources.ContainsKey($ResourceId)) { return $resources[$ResourceId] }
    if ($ResourceId -eq ($poolId -replace '/capacityPools/test$')) { return @{ id = $ResourceId } }
    throw "Unexpected request: $Method $ResourceId"
}

foreach ($scenario in 'Empty', 'NullSamples', 'QueryFailed', 'MetricError') {
    $settings = @{ ANF_MinimumFreeSpacePercent = 15 }
    $pool = @{ id = $poolId; properties = @{ size = 4TB; serviceLevel = 'Standard'; qosType = 'Manual'; totalThroughputMibps = 64 } }
    $measured = @{ id = "$poolId/volumes/measured"; name = 'measured'; properties = @{ usageThreshold = 1TB; throughputMibps = 1 } }
    $unmeasured = @{ id = "$poolId/volumes/unmeasured"; name = 'unmeasured'; properties = @{ usageThreshold = 1792GB + 1MB; throughputMibps = 7 } }
    $resources = @{ $poolId = $pool; $measured.id = $measured; $unmeasured.id = $unmeasured }
    $fixtureVolumes = @($measured, $unmeasured)
    $writes = [System.Collections.Generic.List[string]]::new()
    $warnings = @(& $runbook 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

    if ($writes.Contains($unmeasured.id)) { throw "$scenario issued a write to the skipped volume" }
    if (-not ($warnings -match "Skipping volume 'unmeasured'.*VolumeLogicalSize")) { throw "$scenario omitted the skip warning" }
    if ($measured.properties.usageThreshold -ne 256GB) { throw "$scenario did not process the sibling with a measured zero" }
    # 1792 GiB + 1 MiB reserved, plus the sibling's 256 GiB target, is just over 2 TiB.
    if ($pool.properties.size -ne 3TB) { throw "$scenario did not preserve the full quota in the pool target" }
    if ($measured.properties.throughputMibps -ne 41) { throw "$scenario did not reserve the skipped volume's 7 MiB/s from the pool's 48 MiB/s" }
}

function Test-BufferTarget($Case, [long]$InitialQuota, [long]$UsedBytes, [long]$ExpectedQuota, [hashtable]$Settings) {
    $pool = @{ id = $poolId; properties = @{ size = [math]::Ceiling($InitialQuota / 1TB) * 1TB; serviceLevel = 'Standard'; qosType = 'Auto' } }
    $volume = @{ id = "$poolId/volumes/measured"; name = 'measured'; properties = @{ usageThreshold = $InitialQuota } }
    $resources = @{ $poolId = $pool; $volume.id = $volume }
    $fixtureVolumes = @($volume)
    $writes = [System.Collections.Generic.List[string]]::new()
    $warnings = @(& $runbook 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    if ($warnings.Count) { throw "$Case produced unexpected warnings: $warnings" }
    if ($volume.properties.usageThreshold -ne $ExpectedQuota) { throw "$Case expected $ExpectedQuota bytes, got $($volume.properties.usageThreshold)" }
    if ($pool.properties.size -ne [math]::Ceiling($ExpectedQuota / 1TB) * 1TB) { throw "$Case used the wrong pool target" }
    if ($InitialQuota -eq $ExpectedQuota -and $writes.Count -ne 0) { throw "$Case issued an unnecessary write" }
}

$percent = @{ ANF_MinimumFreeSpacePercent = '15' }
Test-BufferTarget 'Percentage drives growth' 4096GB 3800GB 4471GB $percent
Test-BufferTarget 'Percentage protects shrinkage' 5120GB 3800GB 4471GB $percent
Test-BufferTarget 'GiB drives growth' 1024GB 900GB 1156GB $percent
Test-BufferTarget 'GiB protects shrinkage' 1536GB 900GB 1156GB $percent
Test-BufferTarget 'Absent percentage' 4096GB 3800GB 4056GB @{}
Test-BufferTarget 'Disabled percentage preserves fractional GiB target' 4096GB 3800.5GB 4056.5GB @{ ANF_MinimumFreeSpacePercent = 0 }
Test-BufferTarget 'Percentage exactly satisfied' 4000GB 3400GB 4000GB @{ ANF_MinimumFreeSpacePercent = 15; ANF_MinimumVolumeGrowthPercent = 10 }
Test-BufferTarget 'Fractional use just over the boundary' 4000GB (3400GB + 1MB) 4001GB $percent
Test-BufferTarget 'Repeated run at rounded target' 4471GB 3800GB 4471GB $percent
Test-BufferTarget 'Per-run growth cap' 4000GB 3800GB 4200GB @{ ANF_MinimumFreeSpacePercent = 15; ANF_MaximumVolumeGrowthPercent = 5 }
Test-BufferTarget 'Maximum allowed percentage' 1024GB 100GB 10000GB @{ ANF_MinimumFreeSpacePercent = 99 }

foreach ($invalid in -1, 100, '15.5', 'invalid') {
    $settings = @{ ANF_MinimumFreeSpacePercent = $invalid }
    try {
        & $runbook | Out-Null
        throw "Accepted invalid percentage '$invalid'"
    } catch {
        if ($_.Exception.Message -notlike 'ANF_MinimumFreeSpacePercent must be*') { throw }
    }
}
Write-Output 'ANF-Capacity-Autoscale behavior checks passed.'
