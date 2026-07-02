#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF QoS Performance/ANF-QoS-Autoscale-PerformanceBased.ps1'
$readmePath = Join-Path $repoRoot 'ANF QoS Performance/README.md'
$deployPath = Join-Path $repoRoot 'ANF QoS Performance/deploy/azuredeploy.json'
$deployGovPath = Join-Path $repoRoot 'ANF QoS Performance/deploy/azuredeploy-gov.json'
$deployGovBadgePath = Join-Path $repoRoot 'ANF QoS Performance/deploy/deploytoazuregov.svg'
$behaviorImagePath = Join-Path $repoRoot 'ANF QoS Performance/media/qos-performance-behavior.png'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$deployText = if (Test-Path -LiteralPath $deployPath) { Get-Content -LiteralPath $deployPath -Raw } else { "" }
$deployGovText = if (Test-Path -LiteralPath $deployGovPath) { Get-Content -LiteralPath $deployGovPath -Raw } else { "" }
$deployGovBadgeText = if (Test-Path -LiteralPath $deployGovBadgePath) { Get-Content -LiteralPath $deployGovBadgePath -Raw } else { "" }
$publishedBranchPath = 'codex/qos-performance-modernization'

function Assert-Contains {
    param(
        [Parameter(Mandatory=$true)][string]$Haystack,
        [Parameter(Mandatory=$true)][string]$Needle,
        [Parameter(Mandatory=$true)][string]$Message
    )

    if (-not $Haystack.Contains($Needle)) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory=$true)][string]$Haystack,
        [Parameter(Mandatory=$true)][string]$Needle,
        [Parameter(Mandatory=$true)][string]$Message
    )

    if ($Haystack.Contains($Needle)) {
        throw $Message
    }
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "PowerShell parser found errors in ANF-QoS-Autoscale-PerformanceBased.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '$requiredModules = @(''Az.Accounts'')' -Message 'Expected Az.Accounts to be the only required module for the PowerShell 7.2 Automation runtime.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected shared setting helper for Automation Variable and environment variable support.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected local/Cloud Shell environment variable lookup in setting helper.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_CapacityPoolResourceId"' -Message 'Expected target capacity pool to be configured by Resource ID.'
Assert-Contains -Haystack $scriptText -Needle 'function Resolve-AnfCapacityPoolResourceIds' -Message 'Expected support for multiple capacity pool Resource IDs in the same Automation variable.'
Assert-Contains -Haystack $scriptText -Needle '-split ''[\r\n;,]+''' -Message 'Expected multiple capacity pool IDs to split on new lines, semicolons, or commas.'
Assert-Contains -Haystack $scriptText -Needle 'foreach ($anfTarget in $anfTargets)' -Message 'Expected per-pool independent processing.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected ARM REST helper instead of Az.NetAppFiles cmdlets.'
Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF REST API version.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfMetricAverageValues' -Message 'Expected throughput metrics to be read through ARM REST instead of Az.Monitor cmdlets.'
Assert-Contains -Haystack $scriptText -Needle 'providers/microsoft.insights/metrics' -Message 'Expected ARM metrics endpoint usage for volume throughput history.'
Assert-Contains -Haystack $scriptText -Needle "MetricName 'TotalThroughput'" -Message 'Expected TotalThroughput metric to drive performance allocation.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_ThroughputLookBackHours"' -Message 'Expected configurable throughput metric lookback window.'
Assert-Contains -Haystack $scriptText -Needle 'function Test-AnfFlexibleServiceLevel' -Message 'Expected explicit Flexible Service Level detection.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfClassicManualThroughputPerTiB' -Message 'Expected classic service-level throughput rate helper.'
Assert-Contains -Haystack $scriptText -Needle '"Standard" { return 16 }' -Message 'Expected Standard throughput rate to be hard-coded at 16 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Premium" { return 64 }' -Message 'Expected Premium throughput rate to be hard-coded at 64 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Ultra" { return 128 }' -Message 'Expected Ultra throughput rate to be hard-coded at 128 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle 'FSL uses the current manual pool throughput as the performance budget' -Message 'Expected FSL behavior to use current pool throughput, not capacity-derived throughput.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfPerformancePlan' -Message 'Expected explicit performance allocation helper.'
Assert-Contains -Haystack $scriptText -Needle 'ThroughputMetric' -Message 'Expected performance allocation to include historical throughput metric values.'
Assert-Contains -Haystack $scriptText -Needle 'MetricWeightPercentage' -Message 'Expected performance allocation to show metric-based weighting.'
Assert-Contains -Haystack $scriptText -Needle 'SizeFallbackUsed' -Message 'Expected performance allocation to explicitly report provisioned-size fallback use.'
Assert-Contains -Haystack $scriptText -Needle 'Update-AnfPoolQosTypeManual' -Message 'Expected Auto QoS to Manual QoS conversion helper.'
Assert-Contains -Haystack $scriptText -Needle 'Update-AnfVolumeThroughput' -Message 'Expected REST volume throughput update helper.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MinimumThroughputPerVolume' -Message 'Expected configurable per-volume throughput floor.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_ConvertToManualMode' -Message 'Expected configurable Auto QoS conversion setting.'
Assert-Contains -Haystack $scriptText -Needle 'Classic service level throughput per TiB is hard-coded' -Message 'Expected script header to document fixed classic service level throughput rates.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.NetAppFiles' -Message 'Expected script not to require or call Az.NetAppFiles in PowerShell 7.x Automation.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Update-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzMetric' -Message 'Expected script not to depend on Az.Monitor.'
Assert-NotContains -Haystack $scriptText -Needle '$resourceGroupName = "example-rg"' -Message 'Expected old separate resource group variable to be removed.'
Assert-NotContains -Haystack $scriptText -Needle '$anfAccountName = "example-anf-acct"' -Message 'Expected old separate account variable to be removed.'
Assert-NotContains -Haystack $scriptText -Needle '$anfPoolName = "example-anf-pool"' -Message 'Expected old separate pool variable to be removed.'

Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure' -Message 'Expected README to expose Deploy to Azure button.'
Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure Gov' -Message 'Expected README to expose Deploy to Azure Gov button.'
Assert-Contains -Haystack $readmeText -Needle 'media/qos-performance-behavior.png' -Message 'Expected README to include the QoS Performance behavior graphic.'
Assert-Contains -Haystack $readmeText -Needle 'Standard, Premium, Ultra, and Flexible Service Level' -Message 'Expected README to document all service-level support.'
Assert-Contains -Haystack $readmeText -Needle 'FSL uses the current manual pool throughput' -Message 'Expected README to document FSL throughput budget behavior.'
Assert-Contains -Haystack $readmeText -Needle 'historical average throughput' -Message 'Expected README to document metric-based allocation behavior.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityPoolResourceId` | required |' -Message 'Expected README settings table to document target Resource ID.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_TestMode` | `Yes` |' -Message 'Expected README settings table to document test mode default.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_MinimumThroughputPerVolume` | `1` |' -Message 'Expected README to document minimum throughput floor.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_ConvertToManualMode` | `Yes` |' -Message 'Expected README to document Auto QoS conversion setting.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_ThroughputLookBackHours` | `168` |' -Message 'Expected README to document throughput metric lookback setting.'
Assert-Contains -Haystack $readmeText -Needle 'separated by new lines, semicolons, or commas' -Message 'Expected README to document multi-pool variable syntax.'
Assert-Contains -Haystack $readmeText -Needle 'Each capacity pool is processed independently' -Message 'Expected README to document no cross-pool calculations.'

Assert-Contains -Haystack $deployText -Needle '"runbookType": "PowerShell72"' -Message 'Expected commercial deploy template to create the runbook on PowerShell 7.2.'
Assert-Contains -Haystack $deployText -Needle '"capacityPoolResourceId"' -Message 'Expected commercial deploy template to ask for capacity pool Resource ID.'
Assert-Contains -Haystack $deployText -Needle '"ANF_CapacityPoolResourceId"' -Message 'Expected commercial deploy template to create target Resource ID Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_MinimumThroughputPerVolume"' -Message 'Expected commercial deploy template to create minimum throughput Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_ConvertToManualMode"' -Message 'Expected commercial deploy template to create conversion Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_ThroughputLookBackHours"' -Message 'Expected commercial deploy template to create throughput lookback Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_TestMode"' -Message 'Expected commercial deploy template to create test mode Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"monitoringReaderRoleDefinitionId": "43d0d8ad-25c7-4714-9337-8ba259a9fe05"' -Message 'Expected Monitoring Reader role assignment for ARM metrics reads.'
Assert-Contains -Haystack $readmeText -Needle "public-anf-toolbox%2F$publishedBranchPath%2FANF%2520QoS%2520Performance%2Fdeploy%2Fazuredeploy.json" -Message 'Expected commercial deploy button to point at the WIP branch template.'
Assert-Contains -Haystack $deployText -Needle "raw.githubusercontent.com/tvanroo/public-anf-toolbox/$publishedBranchPath/ANF%20QoS%20Performance/ANF-QoS-Autoscale-PerformanceBased.ps1" -Message 'Expected deploy template to import the runbook from the WIP branch.'
Assert-Contains -Haystack $deployGovText -Needle "raw.githubusercontent.com/tvanroo/public-anf-toolbox/$publishedBranchPath/ANF%20QoS%20Performance/deploy/azuredeploy.json" -Message 'Expected Azure Gov wrapper to link the WIP branch shared template.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'Deploy to Azure Gov' -Message 'Expected local Azure Gov badge SVG.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'fill="#0078D4"' -Message 'Expected Azure Gov badge to use the standard Azure button color.'
Assert-NotContains -Haystack $deployText -Needle '"Az.NetAppFiles"' -Message 'Expected deploy template not to import Az.NetAppFiles.'
Assert-NotContains -Haystack $deployText -Needle '"Az.Monitor"' -Message 'Expected deploy template not to import Az.Monitor.'

if ($deployText) {
    $null = $deployText | ConvertFrom-Json -ErrorAction Stop
}
if ($deployGovText) {
    $null = $deployGovText | ConvertFrom-Json -ErrorAction Stop
}

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected QoS Performance behavior graphic to exist.'
}

Write-Output 'ANF-QoS-Performance static checks passed.'
