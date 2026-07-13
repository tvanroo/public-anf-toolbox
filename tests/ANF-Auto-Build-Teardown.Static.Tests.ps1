#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Automated Build and Teardown/ANF-Auto-Build-Teardown.ps1'
$readmePath = Join-Path $repoRoot 'Automated Build and Teardown/README.md'
$behaviorImagePath = Join-Path $repoRoot 'Automated Build and Teardown/media/auto-build-teardown.png'

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
    throw "PowerShell parser found errors in ANF-Auto-Build-Teardown.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '$requiredModules = @(''Az.Accounts'')' -Message 'Expected Az.Accounts to be the only required module.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected shared setting helper.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected environment variable support.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_Operation"' -Message 'Expected explicit create/delete operation setting.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_TestMode"' -Message 'Expected test mode setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_DeleteConfirmation' -Message 'Expected delete confirmation gate.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected ARM REST helper.'
Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF REST API version.'
Assert-Contains -Haystack $scriptText -Needle 'function Test-AnfFlexibleServiceLevel' -Message 'Expected Flexible Service Level detection.'
Assert-Contains -Haystack $scriptText -Needle 'Standard, Premium, Ultra, or Flexible' -Message 'Expected all service levels to be accepted.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_FslPoolThroughputMibps' -Message 'Expected configurable FSL pool throughput.'
Assert-Contains -Haystack $scriptText -Needle 'customThroughputMibps' -Message 'Expected FSL pool throughput create field.'
Assert-Contains -Haystack $scriptText -Needle 'throughputMibps' -Message 'Expected manual QoS volume throughput support.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_QosType' -Message 'Expected configurable QoS type.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_IsLargeVolume' -Message 'Expected large-volume creation option.'
Assert-Contains -Haystack $scriptText -Needle 'isLargeVolume' -Message 'Expected REST large-volume field.'
Assert-Contains -Haystack $scriptText -Needle 'Wait-AnfProvisioningState' -Message 'Expected long-running create/delete polling helper.'
Assert-Contains -Haystack $scriptText -Needle 'function Wait-AnfChildResourceCollectionEmpty' -Message 'Expected parent collection empty wait helper for ordered deletes.'
Assert-Contains -Haystack $scriptText -Needle 'function Wait-AnfNamedChildAbsent' -Message 'Expected parent collection child-absence wait helper for ordered deletes.'
Assert-Contains -Haystack $scriptText -Needle 'Wait-AnfChildResourceCollectionEmpty -CollectionResourceId $poolVolumesResourceId' -Message 'Expected delete path to wait for the pool volume collection to be empty before deleting the pool.'
Assert-Contains -Haystack $scriptText -Needle 'Wait-AnfNamedChildAbsent -CollectionResourceId $accountPoolsResourceId' -Message 'Expected delete path to wait for the account pool collection before deleting the account.'
Assert-Contains -Haystack $scriptText -Needle 'still contains capacity pool(s)' -Message 'Expected account delete guard when capacity pools remain.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.NetAppFiles' -Message 'Expected script not to require Az.NetAppFiles.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'New-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Remove-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Read-Host' -Message 'Expected non-interactive operation and delete confirmation settings.'
Assert-NotContains -Haystack $scriptText -Needle '-ServiceLevel "Standard"' -Message 'Expected service level not to be hard-coded during pool creation.'

Assert-Contains -Haystack $readmeText -Needle 'media/auto-build-teardown.png' -Message 'Expected README to include the behavior graphic.'
Assert-Contains -Haystack $readmeText -Needle 'Standard, Premium, Ultra, and Flexible Service Level' -Message 'Expected README to document all service levels.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_Operation` |' -Message 'Expected README settings table to document operation selection.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_TestMode` | `Yes` |' -Message 'Expected README settings table to document safe default.'
Assert-Contains -Haystack $readmeText -Needle '`ANF_DeleteConfirmation`' -Message 'Expected README to document delete confirmation.'
Assert-Contains -Haystack $readmeText -Needle '`ANF_FslPoolThroughputMibps`' -Message 'Expected README to document FSL pool throughput.'
Assert-Contains -Haystack $readmeText -Needle '`ANF_IsLargeVolume`' -Message 'Expected README to document large-volume option.'
Assert-Contains -Haystack $readmeText -Needle 'waits for Azure to confirm each layer is gone' -Message 'Expected README to document ordered delete waits.'
Assert-Contains -Haystack $readmeText -Needle 'Invoke-WebRequest -Uri $scriptUri -OutFile $scriptPath' -Message 'Expected README examples to download the script from GitHub for fresh Cloud Shell runs.'
Assert-Contains -Haystack $readmeText -Needle 'raw.githubusercontent.com/tvanroo/public-anf-toolbox/codex/auto-build-teardown-modernization/Automated%20Build%20and%20Teardown/ANF-Auto-Build-Teardown.ps1' -Message 'Expected README examples to pull the WIP script from GitHub.'
Assert-Contains -Haystack $readmeText -Needle 'pwsh -NoProfile -File $scriptPath' -Message 'Expected README examples to run the downloaded script path.'
Assert-NotContains -Haystack $readmeText -Needle 'Az.NetAppFiles' -Message 'Expected README not to list stale module requirement.'

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected Auto Build/Teardown behavior graphic to exist.'
}

Write-Output 'ANF-Auto-Build-Teardown static checks passed.'
