#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Throughput Metrics Collector/ANF-throughput-metrics-collector.ps1'
$rootDuplicatePath = Join-Path $repoRoot 'ANF-throughput-metrics-collector.ps1'
$readmePath = Join-Path $repoRoot 'ANF Throughput Metrics Collector/README.md'
$behaviorImagePath = Join-Path $repoRoot 'ANF Throughput Metrics Collector/media/throughput-metrics-collector.png'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw

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
    throw "PowerShell parser found errors in ANF-throughput-metrics-collector.ps1: $($parseErrors.Message -join '; ')"
}

if (Test-Path -LiteralPath $rootDuplicatePath) {
    throw 'Expected empty root-level throughput metrics collector duplicate to be removed.'
}

Assert-Contains -Haystack $scriptText -Needle '$requiredModules = @(''Az.Accounts'')' -Message 'Expected Az.Accounts to be the only required module.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected setting helper for environment-variable driven runs.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected local/Cloud Shell environment variable support.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_CapacityPoolResourceId"' -Message 'Expected capacity pool Resource ID targeting.'
Assert-Contains -Haystack $scriptText -Needle 'function Resolve-AnfCapacityPoolResourceIds' -Message 'Expected multiple capacity pool Resource ID support.'
Assert-Contains -Haystack $scriptText -Needle '-split ''[\r\n;,]+''' -Message 'Expected multiple pool and volume values to split on new lines, semicolons, or commas.'
Assert-Contains -Haystack $scriptText -Needle 'foreach ($anfTarget in $anfTargets)' -Message 'Expected per-pool independent processing.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected ARM REST helper.'
Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF REST API version.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfMetricSeries' -Message 'Expected metrics to be collected through ARM REST.'
Assert-Contains -Haystack $scriptText -Needle 'ReadThroughput,WriteThroughput,TotalThroughput,OtherThroughput' -Message 'Expected throughput metrics list.'
Assert-Contains -Haystack $scriptText -Needle 'Export-Csv' -Message 'Expected CSV export.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_OutputPath' -Message 'Expected configurable output path.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_OverwriteOutput' -Message 'Expected overwrite guard.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_VolumeName' -Message 'Expected optional volume name filtering.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.NetAppFiles' -Message 'Expected script not to require or call Az.NetAppFiles.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.Monitor' -Message 'Expected script not to require Az.Monitor.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzMetric' -Message 'Expected script not to call Az.Monitor cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'example-rg' -Message 'Expected stale hard-coded targeting examples to be removed from script defaults.'

Assert-Contains -Haystack $readmeText -Needle 'media/throughput-metrics-collector.png' -Message 'Expected README to include the collector behavior graphic.'
Assert-Contains -Haystack $readmeText -Needle 'read-only' -Message 'Expected README to emphasize read-only behavior.'
Assert-Contains -Haystack $readmeText -Needle 'Standard, Premium, Ultra, and Flexible Service Level' -Message 'Expected README to clarify service-level coverage.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityPoolResourceId` | required |' -Message 'Expected README settings table to document Resource ID targeting.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_OutputPath` |' -Message 'Expected README settings table to document output path.'
Assert-Contains -Haystack $readmeText -Needle 'Each capacity pool is queried independently' -Message 'Expected README to document no cross-pool assumptions.'
Assert-NotContains -Haystack $readmeText -Needle 'Az.NetAppFiles' -Message 'Expected README not to list stale module requirement.'
Assert-NotContains -Haystack $readmeText -Needle 'Az.Monitor' -Message 'Expected README not to list stale module requirement.'

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected Throughput Metrics Collector behavior graphic to exist.'
}

Write-Output 'ANF-Throughput-Metrics-Collector static checks passed.'
