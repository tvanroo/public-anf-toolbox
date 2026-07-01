#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Capacity Autoscale/ANF-Capacity-Autoscale.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw

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
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfPool' -Message 'Expected pool retrieval wrapper that can resolve service level and throughput from REST.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfVolumes' -Message 'Expected volume retrieval wrapper that can read FSL throughput fields.'
Assert-Contains -Haystack $scriptText -Needle 'function Update-AnfFslPoolThroughputMibps' -Message 'Expected FSL pool throughput update helper.'
Assert-Contains -Haystack $scriptText -Needle '$poolUpdateApiVersion = "2024-07-01-preview"' -Message 'Expected FSL pool throughput PATCH to use the preview update API from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle '$propertyCandidates = @("customThroughputMibps", "provisionedThroughputMibps", "totalThroughputMibps")' -Message 'Expected FSL pool throughput property fallback order from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle 'ServiceLevel = $resolvedServiceLevel' -Message 'Expected service level to be normalized onto the pool object.'
Assert-Contains -Haystack $scriptText -Needle '$isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel' -Message 'Expected explicit Flexible service level detection.'
Assert-Contains -Haystack $scriptText -Needle 'Flexible service level: capacity and throughput are managed independently' -Message 'Expected FSL branch to keep capacity and throughput planning separate.'

Write-Output 'ANF-Capacity-Autoscale static checks passed.'
