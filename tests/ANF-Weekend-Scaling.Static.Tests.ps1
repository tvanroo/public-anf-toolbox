#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/anf-weekend-scaling-plan.ps1'
$readmePath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/README.md'
$behaviorImagePath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/media/weekend-scaling-plan.png'
$deployPath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/deploy/azuredeploy.json'
$deployGovPath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/deploy/azuredeploy-gov.json'
$deployGovBadgePath = Join-Path $repoRoot 'ANF Weekend Scaling Plan/deploy/deploytoazuregov.svg'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$deployText = if (Test-Path -LiteralPath $deployPath) { Get-Content -LiteralPath $deployPath -Raw } else { "" }
$deployGovText = if (Test-Path -LiteralPath $deployGovPath) { Get-Content -LiteralPath $deployGovPath -Raw } else { "" }
$deployGovBadgeText = if (Test-Path -LiteralPath $deployGovBadgePath) { Get-Content -LiteralPath $deployGovBadgePath -Raw } else { "" }
$wipBranchPath = 'codex/weekend-scaling-modernization'
$wipBranchPathForDeployUri = 'codex%2Fweekend-scaling-modernization'

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

function Assert-StrictJson {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Path
    )

    try {
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($Text)
        $jsonDocument.Dispose()
    }
    catch {
        throw "Strict JSON parsing failed for ${Path}: $($_.Exception.Message)"
    }
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "PowerShell parser found errors in anf-weekend-scaling-plan.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '$requiredModules = @(''Az.Accounts'')' -Message 'Expected Az.Accounts to be the only required module for the PowerShell 7.2 Automation runtime.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-AnfSetting' -Message 'Expected shared setting helper for Automation Variable and environment variable support.'
Assert-Contains -Haystack $scriptText -Needle '[Environment]::GetEnvironmentVariable($Name)' -Message 'Expected local/Cloud Shell environment variable lookup in setting helper.'
Assert-Contains -Haystack $scriptText -Needle 'Get-AnfSetting -Name "ANF_CapacityPoolResourceId"' -Message 'Expected initial target capacity pool to be configured by Resource ID.'
Assert-Contains -Haystack $scriptText -Needle 'function Resolve-AnfCapacityPoolResourceIds' -Message 'Expected support for multiple capacity pool Resource IDs in the same Automation variable.'
Assert-Contains -Haystack $scriptText -Needle '-split ''[\r\n;,]+''' -Message 'Expected multiple capacity pool IDs to split on new lines, semicolons, or commas.'
Assert-Contains -Haystack $scriptText -Needle 'foreach ($anfTarget in $anfTargets)' -Message 'Expected per-pool independent processing.'
Assert-Contains -Haystack $scriptText -Needle 'function Invoke-AnfArmJson' -Message 'Expected ARM REST helper instead of Az.NetAppFiles cmdlets.'
Assert-Contains -Haystack $scriptText -Needle 'function Wait-AnfArmOperation' -Message 'Expected long-running REST operation polling for create/move/delete actions.'
Assert-Contains -Haystack $scriptText -Needle '$anfApiVersion = "2026-04-01"' -Message 'Expected modern ANF REST API version.'
Assert-Contains -Haystack $scriptText -Needle 'function New-AnfPool' -Message 'Expected REST capacity pool create helper.'
Assert-Contains -Haystack $scriptText -Needle 'function Move-AnfVolumeToPool' -Message 'Expected REST volume pool-change helper.'
Assert-Contains -Haystack $scriptText -Needle '/poolChange' -Message 'Expected ANF volume poolChange REST endpoint.'
Assert-Contains -Haystack $scriptText -Needle 'newPoolResourceId' -Message 'Expected poolChange request body to use newPoolResourceId.'
Assert-Contains -Haystack $scriptText -Needle 'function Remove-AnfPool' -Message 'Expected REST capacity pool delete helper.'
Assert-Contains -Haystack $scriptText -Needle 'function Test-AnfFlexibleServiceLevel' -Message 'Expected explicit FSL detection.'
Assert-Contains -Haystack $scriptText -Needle 'Flexible Service Level is not supported by this script' -Message 'Expected FSL pools to be rejected with a clear warning/error.'
Assert-Contains -Haystack $scriptText -Needle '24-hour cooldown' -Message 'Expected FSL cooldown rationale to be documented in script comments or output.'
Assert-Contains -Haystack $scriptText -Needle 'Auto QoS only' -Message 'Expected script to document that the pool-move model is Auto QoS only.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendPoolName' -Message 'Expected advanced optional weekend pool name override.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekdayPoolName' -Message 'Expected advanced optional weekday pool name override.'
Assert-Contains -Haystack $scriptText -Needle '$initialPoolName-weekday' -Message 'Expected weekday pool name to default from the initial pool name.'
Assert-Contains -Haystack $scriptText -Needle '$initialPoolName-weekend' -Message 'Expected weekend pool name to default from the initial pool name.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendServiceLevel' -Message 'Expected editable weekend service level setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekdayServiceLevel' -Message 'Expected editable weekday service level setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendStartDay' -Message 'Expected editable weekend start day setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendStartTime' -Message 'Expected editable weekend start time setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendEndDay' -Message 'Expected editable weekend end day setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_WeekendEndTime' -Message 'Expected editable weekend end time setting.'
Assert-Contains -Haystack $scriptText -Needle 'ANF_TimeZone' -Message 'Expected timezone setting for schedule decisions.'
Assert-Contains -Haystack $scriptText -Needle 'More than one managed pool currently contains volumes' -Message 'Expected guard against ambiguous active pool state.'
Assert-Contains -Haystack $scriptText -Needle 'No volumes found in the initial, weekday, or weekend pools' -Message 'Expected explicit no-volume exit pattern.'
Assert-NotContains -Haystack $scriptText -Needle 'Az.NetAppFiles' -Message 'Expected script not to require the Az.NetAppFiles module in PowerShell 7.x Automation.'
Assert-NotContains -Haystack $scriptText -Needle 'Get-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'New-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Set-AzNetAppFilesVolumePool' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle 'Remove-AzNetAppFiles' -Message 'Expected script not to call Az.NetAppFiles cmdlets.'
Assert-NotContains -Haystack $scriptText -Needle '$resourceGroupName =        "example-rg"' -Message 'Expected old separate resource group variable to be removed.'
Assert-NotContains -Haystack $scriptText -Needle '$anfAccountName =           "example-anf-acct"' -Message 'Expected old separate account variable to be removed.'

Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure' -Message 'Expected README to expose Deploy to Azure button.'
Assert-Contains -Haystack $readmeText -Needle 'Deploy to Azure Gov' -Message 'Expected README to expose Deploy to Azure Gov button.'
Assert-Contains -Haystack $readmeText -Needle 'media/weekend-scaling-plan.png' -Message 'Expected README to include the weekend scaling illustration.'
Assert-Contains -Haystack $readmeText -Needle 'Standard, Premium, and Ultra' -Message 'Expected README to document classic-only support.'
Assert-Contains -Haystack $readmeText -Needle 'Flexible Service Level' -Message 'Expected README to document FSL exclusion.'
Assert-Contains -Haystack $readmeText -Needle '24-hour cooldown' -Message 'Expected README to explain why FSL is excluded.'
Assert-Contains -Haystack $readmeText -Needle 'Auto QoS only' -Message 'Expected README to document Auto QoS-only behavior.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_CapacityPoolResourceId` | required |' -Message 'Expected README settings table to document target Resource ID.'
Assert-Contains -Haystack $readmeText -Needle '| `ANF_TestMode` | `Yes` |' -Message 'Expected README settings table to document test mode default.'
Assert-Contains -Haystack $readmeText -Needle 'Weekday and weekend pool names are derived automatically' -Message 'Expected README to document automatic target pool naming.'
Assert-NotContains -Haystack $readmeText -Needle '| `ANF_WeekdayPoolName` |' -Message 'Expected README not to list weekday pool name as a deployment-facing setting.'
Assert-NotContains -Haystack $readmeText -Needle '| `ANF_WeekendPoolName` |' -Message 'Expected README not to list weekend pool name as a deployment-facing setting.'
Assert-Contains -Haystack $readmeText -Needle 'Each configured pool set is processed independently' -Message 'Expected README to document no cross-pool calculations.'

Assert-Contains -Haystack $deployText -Needle '"runbookType": "PowerShell72"' -Message 'Expected commercial deploy template to create the runbook on PowerShell 7.2.'
Assert-Contains -Haystack $deployText -Needle '"capacityPoolResourceId"' -Message 'Expected commercial deploy template to ask for initial capacity pool Resource ID.'
Assert-Contains -Haystack $deployText -Needle '"ANF_CapacityPoolResourceId"' -Message 'Expected commercial deploy template to create target Resource ID Automation variable.'
Assert-NotContains -Haystack $deployText -Needle '"ANF_WeekendPoolName"' -Message 'Expected commercial deploy template not to create weekend pool name Automation variable.'
Assert-NotContains -Haystack $deployText -Needle '"ANF_WeekdayPoolName"' -Message 'Expected commercial deploy template not to create weekday pool name Automation variable.'
Assert-NotContains -Haystack $deployText -Needle '"weekendPoolName"' -Message 'Expected commercial deploy template not to prompt for weekend pool name.'
Assert-NotContains -Haystack $deployText -Needle '"weekdayPoolName"' -Message 'Expected commercial deploy template not to prompt for weekday pool name.'
Assert-NotContains -Haystack $deployGovText -Needle '"weekendPoolName"' -Message 'Expected Azure Gov deploy wrapper not to prompt for weekend pool name.'
Assert-NotContains -Haystack $deployGovText -Needle '"weekdayPoolName"' -Message 'Expected Azure Gov deploy wrapper not to prompt for weekday pool name.'
Assert-Contains -Haystack $deployText -Needle '"ANF_WeekendServiceLevel"' -Message 'Expected commercial deploy template to create weekend service level Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_WeekdayServiceLevel"' -Message 'Expected commercial deploy template to create weekday service level Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"ANF_TestMode"' -Message 'Expected commercial deploy template to create test mode Automation variable.'
Assert-Contains -Haystack $deployText -Needle '"Pacific Standard Time"' -Message 'Expected commercial deploy template timezone dropdown to include US examples.'
Assert-Contains -Haystack $deployText -Needle '"Tokyo Standard Time"' -Message 'Expected commercial deploy template timezone dropdown to include global examples.'
Assert-Contains -Haystack $deployGovText -Needle '"Pacific Standard Time"' -Message 'Expected Azure Gov deploy wrapper timezone dropdown to include US examples.'
Assert-Contains -Haystack $deployGovText -Needle '"Tokyo Standard Time"' -Message 'Expected Azure Gov deploy wrapper timezone dropdown to include global examples.'
Assert-Contains -Haystack $readmeText -Needle "public-anf-toolbox%2F$wipBranchPathForDeployUri%2FANF%2520Weekend%2520Scaling%2520Plan%2Fdeploy%2Fazuredeploy.json" -Message 'Expected commercial deploy button to point at the WIP branch template.'
Assert-Contains -Haystack $deployText -Needle "raw.githubusercontent.com/tvanroo/public-anf-toolbox/$wipBranchPath/ANF%20Weekend%20Scaling%20Plan/anf-weekend-scaling-plan.ps1" -Message 'Expected deploy template to import the runbook from the WIP branch.'
Assert-Contains -Haystack $deployGovText -Needle "raw.githubusercontent.com/tvanroo/public-anf-toolbox/$wipBranchPath/ANF%20Weekend%20Scaling%20Plan/deploy/azuredeploy.json" -Message 'Expected Azure Gov wrapper to link the WIP branch shared template.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'Deploy to Azure Gov' -Message 'Expected local Azure Gov badge SVG.'
Assert-Contains -Haystack $deployGovBadgeText -Needle 'fill="#0078D4"' -Message 'Expected Azure Gov badge to use the standard Azure button color.'
Assert-NotContains -Haystack $deployText -Needle '"Az.NetAppFiles"' -Message 'Expected deploy template not to import Az.NetAppFiles.'

if ($deployText) {
    Assert-StrictJson -Text $deployText -Path $deployPath
    $null = $deployText | ConvertFrom-Json -ErrorAction Stop
}
if ($deployGovText) {
    Assert-StrictJson -Text $deployGovText -Path $deployGovPath
    $null = $deployGovText | ConvertFrom-Json -ErrorAction Stop
}

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected weekend scaling behavior graphic to exist.'
}

Write-Output 'ANF-Weekend-Scaling static checks passed.'
