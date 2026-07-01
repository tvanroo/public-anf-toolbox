#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Capacity Autoscale/ANF-Capacity-Autoscale.ps1'
$readmePath = Join-Path $repoRoot 'ANF Capacity Autoscale/README.md'
$deployPath = Join-Path $repoRoot 'ANF Capacity Autoscale/deploy/azuredeploy.json'
$deployGovPath = Join-Path $repoRoot 'ANF Capacity Autoscale/deploy/azuredeploy-gov.json'
$deployGovBadgePath = Join-Path $repoRoot 'ANF Capacity Autoscale/deploy/deploytoazuregov.svg'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$deployText = if (Test-Path -LiteralPath $deployPath) { Get-Content -LiteralPath $deployPath -Raw } else { "" }
$deployGovText = if (Test-Path -LiteralPath $deployGovPath) { Get-Content -LiteralPath $deployGovPath -Raw } else { "" }
$deployGovBadgeText = if (Test-Path -LiteralPath $deployGovBadgePath) { Get-Content -LiteralPath $deployGovBadgePath -Raw } else { "" }

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
    throw "PowerShell parser found errors in ANF-Capacity-Autoscale.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF read API version to be declared.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected shared ARM REST helper for FSL-compatible API calls.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected shared setting helper for Automation Variable and Cloud Shell environment variable support.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected Cloud Shell environment variable lookup in setting helper.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_CapacityPoolResourceId"' -Message 'Expected target capacity pool to be configured by a single Resource ID setting.'
Assert-Contains -Haystack $scriptText -Needle 'function Resolve-AnfCapacityPoolResourceId' -Message 'Expected helper to parse capacity pool Resource ID into subscription, resource group, account, and pool names.'
Assert-Contains -Haystack $scriptText -Needle 'CapacityPoolResourceId = $normalizedResourceId' -Message 'Expected parsed capacity pool Resource ID to be retained in target metadata.'
Assert-Contains -Haystack $scriptText -Needle 'Missing required variable: ANF_CapacityPoolResourceId' -Message 'Expected missing target validation to name the single Resource ID setting.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_ResourceGroupName must be set before running this script' -Message 'Expected target validation not to fail on the old separate resource group setting.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_AccountName must be set before running this script' -Message 'Expected target validation not to fail on the old separate account setting.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_PoolName must be set before running this script' -Message 'Expected target validation not to fail on the old separate pool setting.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfPool' -Message 'Expected pool retrieval wrapper that can resolve service level and throughput from REST.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfVolumes' -Message 'Expected volume retrieval wrapper that can read FSL throughput fields.'
Assert-Contains -Haystack $scriptText -Needle 'function Update-AnfFslPoolThroughputMibps' -Message 'Expected FSL pool throughput update helper.'
Assert-Contains -Haystack $scriptText -Needle 'function Resolve-AnfVolumeSizeProfile' -Message 'Expected per-volume regular/large/breakthrough size profile resolver.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfClassicManualThroughputPerTiB' -Message 'Expected classic throughput per TiB to be derived from service level in code.'
Assert-Contains -Haystack $scriptText -Needle '"Standard" { return 16 }' -Message 'Expected Standard classic throughput rate to be hard-coded at 16 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Premium" { return 64 }' -Message 'Expected Premium classic throughput rate to be hard-coded at 64 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Ultra" { return 128 }' -Message 'Expected Ultra classic throughput rate to be hard-coded at 128 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '$minimumPoolThroughputMibps = 128' -Message 'Expected FSL minimum pool throughput to be fixed at 128 MiB/s in code.'
Assert-Contains -Haystack $scriptText -Needle 'ExcludedFromAutoscale' -Message 'Expected unsupported breakthrough volumes to be excluded from autoscale changes.'
Assert-Contains -Haystack $scriptText -Needle 'Breakthrough large volume' -Message 'Expected warning path for unsupported breakthrough large volumes.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_MaxThroughputPerTiB"' -Message 'Expected classic throughput cap not to be user-configurable.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_MinimumPoolThroughputMibps"' -Message 'Expected FSL minimum pool throughput not to be user-configurable.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_LargeVolumeLimitMode' -Message 'Expected large volume limit mode not to be externally configurable.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_BreakthroughLargeVolumeMaximumSizeGiB' -Message 'Expected breakthrough large volume sizing not to be supported in this script.'
Assert-NotContains -Haystack $scriptText -Needle 'ExtraLargeCoolAccess' -Message 'Expected extra-large cool-access sizing not to be supported in this script.'
Assert-Contains -Haystack $scriptText -Needle 'IsLargeVolume = $isLargeVolume' -Message 'Expected REST volume conversion to preserve isLargeVolume.'
Assert-Contains -Haystack $scriptText -Needle 'LargeVolumeType = $largeVolumeType' -Message 'Expected REST volume conversion to preserve largeVolumeType.'
Assert-Contains -Haystack $scriptText -Needle 'MaximumSizeGiB = $volumeSizeProfile.MaximumSizeGiB' -Message 'Expected volume data to use per-volume maximum size limits.'
Assert-Contains -Haystack $scriptText -Needle '$poolUpdateApiVersion = "2024-07-01-preview"' -Message 'Expected FSL pool throughput PATCH to use the preview update API from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle '$propertyCandidates = @("customThroughputMibps", "provisionedThroughputMibps", "totalThroughputMibps")' -Message 'Expected FSL pool throughput property fallback order from the FSL reference script.'
Assert-Contains -Haystack $scriptText -Needle 'ServiceLevel = $resolvedServiceLevel' -Message 'Expected service level to be normalized onto the pool object.'
Assert-Contains -Haystack $scriptText -Needle '$isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel' -Message 'Expected explicit Flexible service level detection.'
Assert-Contains -Haystack $scriptText -Needle 'Flexible service level: capacity and throughput are managed independently' -Message 'Expected FSL branch to keep capacity and throughput planning separate.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_CapacityResizeThreshold: Resize threshold percent (int, default: 99)' -Message 'Expected script header to document actual capacity resize threshold default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MinimumVolumeGrowthPercent: Minimum growth percent (int, default: 0)' -Message 'Expected script header to document actual minimum volume growth default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MaximumVolumeGrowthPercent: Maximum growth percent (int, default: 10000000)' -Message 'Expected script header to document actual maximum volume growth default.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_MinimumFreeSpaceGiB: Minimum free space in GiB (int, default: 256)' -Message 'Expected script header to document actual minimum free space default.'
Assert-Contains -Haystack $scriptText -Needle 'Classic service level throughput per TiB is hard-coded' -Message 'Expected script header to document fixed classic service level throughput rates.'
Assert-Contains -Haystack $scriptText -Needle 'Breakthrough large volumes are excluded from changes' -Message 'Expected script header to document breakthrough exclusion.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityResizeThreshold` | `99` |' -Message 'Expected README settings table to document actual resize threshold default.'
Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure' -Message 'Expected README to expose Deploy to Azure button.'
Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure Gov' -Message 'Expected README to expose Deploy to Azure Gov button.'
Assert-Contains -Haystack $readmeText -Needle 'deploy/deploytoazuregov.svg' -Message 'Expected Azure Gov deploy badge to use the local Azure-style Gov badge.'
Assert-NotContains -Haystack $readmeText -Needle 'img.shields.io/badge/Deploy%20to-Azure%20Gov' -Message 'Expected README not to use the generic shields.io Azure Gov badge.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'Deploy to Azure Gov' -Message 'Expected local Azure Gov badge SVG to label the button as Deploy to Azure Gov.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'fill="#0078D4"' -Message 'Expected local Azure Gov badge SVG to use the standard Azure button color.'
Assert-Contains -Haystack $readmeText -Needle 'Standard `16`, Premium `64`, and Ultra `128` MiB/s per TiB' -Message 'Expected README to document fixed classic service level throughput rates.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityPoolResourceId` | required |' -Message 'Expected README settings table to document single target capacity pool Resource ID.'
Assert-NotContains -Haystack $readmeText -Needle '| `ANF_ResourceGroupName` |' -Message 'Expected README not to ask for target resource group separately.'
Assert-NotContains -Haystack $readmeText -Needle '| `ANF_AccountName` |' -Message 'Expected README not to ask for target ANF account separately.'
Assert-NotContains -Haystack $readmeText -Needle '| `ANF_PoolName` |' -Message 'Expected README not to ask for target pool separately.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_LargeVolumeMaximumSizeGiB` | `1048576` |' -Message 'Expected README settings table to document editable large volume maximum.'
Assert-Contains -Haystack $readmeText -Needle 'Breakthrough large volumes are excluded' -Message 'Expected README to document breakthrough large volume exclusion.'
Assert-NotContains -Haystack $readmeText -Needle 'ANF_MaxThroughputPerTiB' -Message 'Expected README not to expose classic max throughput per TiB.'
Assert-NotContains -Haystack $readmeText -Needle 'ANF_MinimumPoolThroughputMibps' -Message 'Expected README not to expose FSL minimum pool throughput.'
Assert-NotContains -Haystack $readmeText -Needle 'ANF_LargeVolumeLimitMode' -Message 'Expected README not to expose large volume limit mode.'
Assert-NotContains -Haystack $readmeText -Needle 'Extra-large cool-access' -Message 'Expected README not to describe unsupported extra-large cool-access sizing.'
Assert-Contains -Haystack $readmeText -Needle '| Missing capacity metric data | `0` consumed |' -Message 'Expected README hard-coded decision table to document missing metric fallback.'
Assert-Contains -Haystack $deployText -Needle '"ANF_TestMode"' -Message 'Expected commercial deploy template to create editable ANF_TestMode Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"defaultValue": "ANF-Capacity-Autoscale"' -Message 'Expected commercial deploy template to provide a relevant default Automation Account name.'
Assert-Contains -Haystack $deployText -Needle '"capacityPoolResourceId"' -Message 'Expected commercial deploy template to ask for target capacity pool Resource ID.'
Assert-Contains -Haystack $deployText -Needle '"ANF_CapacityPoolResourceId"' -Message 'Expected commercial deploy template to create target capacity pool Resource ID Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_LargeVolumeMaximumSizeGiB"' -Message 'Expected commercial deploy template to create editable large volume max Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"scheduleStartDelayMinutes"' -Message 'Expected commercial deploy template to ask for start delay in minutes.'
Assert-Contains -Haystack $deployText -Needle '"scheduleBaseTimeUtc"' -Message 'Expected commercial deploy template to use a parameter default for utcNow-based schedule calculation.'
Assert-Contains -Haystack $deployText -Needle '"defaultValue": "[utcNow(' -Message 'Expected commercial deploy template to keep utcNow only in a parameter default value.'
Assert-NotContains -Haystack $deployText -Needle 'dateTimeAdd(utcNow' -Message 'Expected commercial deploy template not to use utcNow directly inside schedule resource properties.'
Assert-NotContains -Haystack $deployText -Needle '"anfAccountName"' -Message 'Expected commercial deploy template not to ask for ANF account separately.'
Assert-NotContains -Haystack $deployText -Needle '"anfPoolName"' -Message 'Expected commercial deploy template not to ask for capacity pool separately.'
Assert-NotContains -Haystack $deployText -Needle '"ANF_ResourceGroupName"' -Message 'Expected commercial deploy template not to create separate target resource group variable.'
Assert-NotContains -Haystack $deployText -Needle '"ANF_AccountName"' -Message 'Expected commercial deploy template not to create separate target account variable.'
Assert-NotContains -Haystack $deployText -Needle '"ANF_PoolName"' -Message 'Expected commercial deploy template not to create separate target pool variable.'
Assert-NotContains -Haystack $deployText -Needle '"maxThroughputPerTiB"' -Message 'Expected commercial deploy template not to ask for classic throughput rate.'
Assert-NotContains -Haystack $deployText -Needle '"minimumPoolThroughputMibps"' -Message 'Expected commercial deploy template not to ask for FSL minimum pool throughput.'
Assert-NotContains -Haystack $deployText -Needle '"largeVolumeLimitMode"' -Message 'Expected commercial deploy template not to ask for large volume limit mode.'
Assert-NotContains -Haystack $deployText -Needle '"scheduleTimeZone"' -Message 'Expected commercial deploy template not to ask for schedule timezone.'
Assert-NotContains -Haystack $deployText -Needle '"scheduleStartTimeUtc"' -Message 'Expected commercial deploy template not to ask for full schedule start timestamp.'
Assert-Contains -Haystack $deployText -Needle '"Azure NetApp Files Administrator"' -Message 'Expected commercial deploy template to document ANF administrator permission assignment.'
Assert-Contains -Haystack $deployGovText -Needle '"ANF_TestMode"' -Message 'Expected Azure Gov deploy template to create editable ANF_TestMode Automation variable.'
Assert-Contains -Haystack $deployGovText -Needle '"defaultValue": "ANF-Capacity-Autoscale"' -Message 'Expected Azure Gov deploy template to provide a relevant default Automation Account name.'
Assert-Contains -Haystack $deployGovText -Needle '"capacityPoolResourceId"' -Message 'Expected Azure Gov deploy template to ask for target capacity pool Resource ID.'
Assert-Contains -Haystack $deployGovText -Needle '"scheduleStartDelayMinutes"' -Message 'Expected Azure Gov deploy template to ask for start delay in minutes.'
Assert-NotContains -Haystack $deployGovText -Needle '"anfAccountName"' -Message 'Expected Azure Gov deploy template not to ask for ANF account separately.'
Assert-NotContains -Haystack $deployGovText -Needle '"anfPoolName"' -Message 'Expected Azure Gov deploy template not to ask for capacity pool separately.'
Assert-NotContains -Haystack $deployGovText -Needle '"largeVolumeLimitMode"' -Message 'Expected Azure Gov deploy template not to ask for large volume limit mode.'

if ($deployText) {
    $null = $deployText | ConvertFrom-Json -ErrorAction Stop
}
if ($deployGovText) {
    $null = $deployGovText | ConvertFrom-Json -ErrorAction Stop
}

Write-Output 'ANF-Capacity-Autoscale static checks passed.'
