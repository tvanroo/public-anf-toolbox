#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Capacity Autoscale/ANF-Capacity-Autoscale.ps1'
$readmePath = Join-Path $repoRoot 'ANF Capacity Autoscale/README.md'
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

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "PowerShell parser found errors in ANF-Capacity-Autoscale.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF read API version to be declared.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected shared ARM REST helper for FSL-compatible API calls.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected shared setting helper for Automation Variable and Cloud Shell environment variable support.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected Cloud Shell environment variable lookup in setting helper.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_ResourceGroupName"' -Message 'Expected resource group setting to support ANF_ResourceGroupName environment variable.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_AccountName"' -Message 'Expected account setting to support ANF_AccountName environment variable.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_PoolName"' -Message 'Expected pool setting to support ANF_PoolName environment variable.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfPool' -Message 'Expected pool retrieval wrapper that can resolve service level and throughput from REST.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfVolumes' -Message 'Expected volume retrieval wrapper that can read FSL throughput fields.'
Assert-Contains -Haystack $scriptText -Needle 'function Update-AnfFslPoolThroughputMibps' -Message 'Expected FSL pool throughput update helper.'
Assert-Contains -Haystack $scriptText -Needle '$poolUpdateApiVersion = "2024-07-01-preview"' -Message 'Expected FSL pool throughput PATCH to use the preview update API from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle '$propertyCandidates = @("customThroughputMibps", "provisionedThroughputMibps", "totalThroughputMibps")' -Message 'Expected FSL pool throughput property fallback order from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle 'ServiceLevel = $resolvedServiceLevel' -Message 'Expected service level to be normalized onto the pool object.'
Assert-Contains -Haystack $scriptText -Needle '$isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel' -Message 'Expected explicit Flexible service level detection.'
Assert-Contains -Haystack $scriptText -Needle 'Flexible service level: capacity and throughput are managed independently' -Message 'Expected FSL branch to keep capacity and throughput planning separate.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_CapacityResizeThreshold: Resize threshold percent (int, default: 99)' -Message 'Expected script header to document actual capacity resize threshold default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MinimumVolumeGrowthPercent: Minimum growth percent (int, default: 0)' -Message 'Expected script header to document actual minimum volume growth default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MaximumVolumeGrowthPercent: Maximum growth percent (int, default: 10000000)' -Message 'Expected script header to document actual maximum volume growth default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MinimumFreeSpaceGiB: Minimum free space in GiB (int, default: 256)' -Message 'Expected script header to document actual minimum free space default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MaxThroughputPerTiB: Maximum throughput per TiB override (int, default: 68)' -Message 'Expected script header to document actual classic manual QoS throughput cap default.'
Assert-Contains -Haystack $scriptText -Needle 'Minimum volume size is hard-coded at 50 GiB; maximum volume size is hard-coded at 102400 GiB.' -Message 'Expected script header to document hard-coded volume size bounds.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityResizeThreshold` | `99` |' -Message 'Expected README settings table to document actual resize threshold default.'
Assert-Contains -Haystack $readmeText -Needle '| Minimum volume size | `50` GiB |' -Message 'Expected README hard-coded decision table to document minimum volume size.'
Assert-Contains -Haystack $readmeText -Needle '| Missing capacity metric data | `0` consumed |' -Message 'Expected README hard-coded decision table to document missing metric fallback.'

Write-Output 'ANF-Capacity-Autoscale static checks passed.'
