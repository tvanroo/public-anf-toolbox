#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Robocopy Booster/robocopy-booster.ps1'
$scriptV2Path = Join-Path $repoRoot 'Robocopy Booster/robocopy-booster-v2.ps1'
$readmePath = Join-Path $repoRoot 'Robocopy Booster/README.md'
$behaviorImagePath = Join-Path $repoRoot 'Robocopy Booster/media/robocopy-booster.png'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$scriptV2Text = Get-Content -LiteralPath $scriptV2Path -Raw
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

foreach ($path in @($scriptPath, $scriptV2Path)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell parser found errors in $path`: $($parseErrors.Message -join '; ')"
    }
}

foreach ($text in @($scriptText, $scriptV2Text)) {
    Assert-Contains -Haystack $text -Needle '[switch]$DryRun' -Message 'Expected dry-run switch.'
    Assert-Contains -Haystack $text -Needle '/XJ' -Message 'Expected junction traversal protection.'
    Assert-Contains -Haystack $text -Needle 'Test-IsChildPath' -Message 'Expected destination-inside-source guard.'
    Assert-Contains -Haystack $text -Needle 'ReparsePoint' -Message 'Expected reparse point protection.'
    Assert-Contains -Haystack $text -Needle '/COPY:DAT' -Message 'Expected data/attributes/timestamps copy mode.'
    Assert-Contains -Haystack $text -Needle '/DCOPY:DAT' -Message 'Expected directory data/attributes/timestamps copy mode.'
    Assert-Contains -Haystack $text -Needle 'Start-Job' -Message 'Expected parallel Robocopy jobs.'
    Assert-Contains -Haystack $text -Needle 'Highest Robocopy Exit Code' -Message 'Expected exit-code summary.'
    foreach ($dangerousSwitch in @('/MIR', '/PURGE', '/MOV', '/MOVE')) {
        if ($text -match "(?m)^\s*['""]$([regex]::Escape($dangerousSwitch))['""]\s*,?") {
            throw "Expected script not to add dangerous Robocopy switch $dangerousSwitch as an option."
        }
    }
}

Assert-Contains -Haystack $scriptV2Text -Needle '[switch]$EnableLogging' -Message 'Expected V2 logging switch.'
Assert-Contains -Haystack $scriptV2Text -Needle '/LOG:NUL' -Message 'Expected V2 silent mode to suppress Robocopy logging.'
Assert-Contains -Haystack $scriptV2Text -Needle 'Speed' -Message 'Expected V2 speed reporting field.'

Assert-Contains -Haystack $readmeText -Needle 'media/robocopy-booster.png' -Message 'Expected README to include behavior graphic.'
Assert-Contains -Haystack $readmeText -Needle 'one-way source-to-destination copy/update' -Message 'Expected README to document the one-way sync contract.'
Assert-Contains -Haystack $readmeText -Needle 'These scripts are not mirror/purge tools' -Message 'Expected README to warn against mirror/purge semantics.'

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected Robocopy Booster behavior graphic to exist.'
}

Write-Output 'Robocopy-Booster static checks passed.'
