#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/ANF-daily-pool-size-scaling-plan.ps1'
$readmePath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/README.md'
$weeklyScalingImagePath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/media/daily-pool-size-scaling-week.png'
$deployPath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/deploy/azuredeploy.json'
$deployGovPath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/deploy/azuredeploy-gov.json'
$deployGovBadgePath = Join-Path $repoRoot 'ANF Daily Pool Size Scaling Plan/deploy/deploytoazuregov.svg'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$deployText = if (Test-Path -LiteralPath $deployPath) { Get-Content -LiteralPath $deployPath -Raw } else { "" }
$deployGovText = if (Test-Path -LiteralPath $deployGovPath) { Get-Content -LiteralPath $deployGovPath -Raw } else { "" }
$deployGovBadgeText = if (Test-Path -LiteralPath $deployGovBadgePath) { Get-Content -LiteralPath $deployGovBadgePath -Raw } else { "" }
$wipBranchPath = 'codex/anf-daily-pool-modernization'
$wipBranchPathForDeployUri = 'codex%2Fanf-daily-pool-modernization'

if (-not (Test-Path -LiteralPath $weeklyScalingImagePath)) {
    throw 'Expected README weekly scaling illustration to exist at ANF Daily Pool Size Scaling Plan/media/daily-pool-size-scaling-week.png.'
}

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
    throw "PowerShell parser found errors in ANF-daily-pool-size-scaling-plan.ps1: $($parseErrors.Message -join '; ')"
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
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfClassicManualThroughputPerTiB' -Message 'Expected classic service-level throughput rate helper.'
Assert-Contains -Haystack $scriptText -Needle '"Standard" { return 16 }' -Message 'Expected Standard throughput rate to be hard-coded at 16 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Premium" { return 64 }' -Message 'Expected Premium throughput rate to be hard-coded at 64 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle '"Ultra" { return 128 }' -Message 'Expected Ultra throughput rate to be hard-coded at 128 MiB/s per TiB.'
Assert-Contains -Haystack $scriptText -Needle 'function Test-AnfFlexibleServiceLevel' -Message 'Expected explicit FSL detection.'
Assert-Contains -Haystack $scriptText -Needle 'Flexible Service Level is not supported by this script' -Message 'Expected FSL pools to be rejected with a clear warning/error.'
Assert-Contains -Haystack $scriptText -Needle '24-hour cooldown' -Message 'Expected FSL cooldown rationale to be documented in script output or comments.'
Assert-Contains -Haystack $scriptText -Needle 'Update-AnfPoolQosTypeManual' -Message 'Expected Auto QoS to Manual QoS conversion helper.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_TestMode' -Message 'Expected Automation-variable test mode setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_OnHoursTiBs' -Message 'Expected on-hours pool size setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_OffHoursTiBs' -Message 'Expected off-hours pool size setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_DayStartTime' -Message 'Expected day start setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_DayEndTime' -Message 'Expected day end setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_TimeZone' -Message 'Expected timezone setting for daily schedule decisions.'
Assert-Contains -Haystack $scriptText -Needle 'Target pool size is below provisioned volume capacity' -Message 'Expected guard against shrinking pool below provisioned volume capacity.'
Assert-Contains -Haystack $scriptText -Needle '$volumeRetrievalCompleted = $false' -Message 'Expected empty volume list retrieval to terminate instead of retrying forever.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.NetAppFiles' -Message 'Expected script not to require the Az.NetAppFiles module in PowerShell 7.x Automation.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Update-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_MiBsperTiB"' -Message 'Expected MiB/s per TiB not to be user-configurable.'
Assert-NotContains -Haystack $scriptText -Needle '$MiBsperTiB' -Message 'Expected legacy user-configured MiB/s per TiB variable to be removed.'
Assert-NotContains -Haystack $scriptText -Needle 'ANF_ResourceGroupName must be set' -Message 'Expected old separate target resource group validation to be removed.'

Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure' -Message 'Expected README to expose Deploy to Azure button.'
Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure Gov' -Message 'Expected README to expose Deploy to Azure Gov button.'
Assert-Contains -Haystack $readmeText -Needle 'Standard, Premium, and Ultra' -Message 'Expected README to document classic-only support.'
Assert-Contains -Haystack $readmeText -Needle 'Flexible Service Level' -Message 'Expected README to document FSL exclusion.'
Assert-Contains -Haystack $readmeText -Needle '24-hour cooldown' -Message 'Expected README to explain why FSL is excluded.'
Assert-Contains -Haystack $readmeText -Needle 'over-provisioned in capacity to reach a throughput requirement' -Message 'Expected README to document the intended classic-pool use case.'
Assert-Contains -Haystack $readmeText -Needle 'media/daily-pool-size-scaling-week.png' -Message 'Expected README to include the weekly daily-pool-scaling illustration.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityPoolResourceId` | required |' -Message 'Expected README settings table to document target Resource ID.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_TestMode` | `Yes` |' -Message 'Expected README settings table to document test mode default.'
Assert-NotContains -Haystack $readmeText -Needle 'ANF_MiBsperTiB' -Message 'Expected README not to expose MiB/s per TiB input.'

Assert-Contains -Haystack $deployText -Needle '"runbookType": "PowerShell72"' -Message 'Expected commercial deploy template to create the runbook on PowerShell 7.2.'
Assert-Contains -Haystack $deployText -Needle '"capacityPoolResourceId"' -Message 'Expected commercial deploy template to ask for capacity pool Resource ID.'
Assert-Contains -Haystack $deployText -Needle '"ANF_CapacityPoolResourceId"' -Message 'Expected commercial deploy template to create target Resource ID Automation variable.'
Assert-Contains -Haystack $deployText -Needle 'ANF_OnHoursTiBs' -Message 'Expected commercial deploy template to create on-hours size Automation variable.'
Assert-Contains -Haystack $deployText -Needle 'ANF_OffHoursTiBs' -Message 'Expected commercial deploy template to create off-hours size Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_TestMode"' -Message 'Expected commercial deploy template to create test mode Automation variable.'
Assert-Contains -Haystack $readmeText -Needle 'public-anf-toolbox%2Fmain%2FANF%2520Daily%2520Pool%2520Size%2520Scaling%2520Plan%2Fdeploy%2Fazuredeploy.json' -Message 'Expected commercial deploy button to point at the main branch template.'
Assert-Contains -Haystack $deployText -Needle 'raw.githubusercontent.com/tvanroo/public-anf-toolbox/main/ANF%20Daily%20Pool%20Size%20Scaling%20Plan/ANF-daily-pool-size-scaling-plan.ps1' -Message 'Expected deploy template to import the runbook from main after promotion.'
Assert-Contains -Haystack $deployGovText -Needle 'raw.githubusercontent.com/tvanroo/public-anf-toolbox/main/ANF%20Daily%20Pool%20Size%20Scaling%20Plan/deploy/azuredeploy.json' -Message 'Expected Azure Gov wrapper to link the main branch shared template after promotion.'
Assert-NotContains -Haystack $readmeText -Needle $wipBranchPathForDeployUri -Message 'Expected README deploy buttons not to point at the WIP branch after promotion.'
Assert-NotContains -Haystack $deployText -Needle $wipBranchPath -Message 'Expected commercial deploy template not to point at the WIP branch after promotion.'
Assert-NotContains -Haystack $deployGovText -Needle $wipBranchPath -Message 'Expected Azure Gov deploy template not to point at the WIP branch after promotion.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'Deploy to Azure Gov' -Message 'Expected local Azure Gov badge SVG.'
Assert-NotContains -Haystack $deployText -Needle '"Az.NetAppFiles"' -Message 'Expected deploy template not to import Az.NetAppFiles.'
Assert-NotContains -Haystack $deployText -Needle '"miBsperTiB"' -Message 'Expected deploy template not to ask for MiB/s per TiB.'

if ($deployText) {
    $null = $deployText | ConvertFrom-Json -ErrorAction Stop
}
if ($deployGovText) {
    $null = $deployGovText | ConvertFrom-Json -ErrorAction Stop
}

Write-Output 'ANF-Daily-Pool-Size-Scaling static checks passed.'
