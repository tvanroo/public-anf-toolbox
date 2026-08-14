#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$boosterDirectory = Join-Path $repoRoot 'Robocopy Booster'
$scriptPath = Join-Path $boosterDirectory 'robocopy-booster.ps1'
$deprecatedScriptPath = Join-Path $boosterDirectory 'robocopy-booster-v2.ps1'
$readmePath = Join-Path $boosterDirectory 'README.md'
$rootReadmePath = Join-Path $repoRoot 'README.md'
$behaviorImagePath = Join-Path $boosterDirectory 'media/robocopy-booster.png'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Haystack,

        [Parameter(Mandatory = $true)]
        [string]$Needle,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Haystack.Contains($Needle)) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Haystack,

        [Parameter(Mandatory = $true)]
        [string]$Needle,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Haystack.Contains($Needle)) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        & $Action
    }
    catch {
        return
    }

    throw $Message
}

$boosterScripts = @(Get-ChildItem -LiteralPath $boosterDirectory -File -Filter 'robocopy-booster*.ps1')
Assert-True -Condition ($boosterScripts.Count -eq 1) -Message 'Expected exactly one Robocopy Booster script.'
Assert-True -Condition ($boosterScripts[0].FullName -eq $scriptPath) -Message 'Expected the canonical script to use the stable robocopy-booster.ps1 filename.'
Assert-True -Condition (-not (Test-Path -LiteralPath $deprecatedScriptPath)) -Message 'Expected the V2 script to be removed.'

$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw ('PowerShell parser found errors in {0}: {1}' -f $scriptPath, ($parseErrors.Message -join '; '))
}

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
$rootReadmeText = Get-Content -LiteralPath $rootReadmePath -Raw

foreach ($parameterName in @('SourcePath', 'DestinationPath')) {
    $parameterAst = $scriptAst.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -eq $parameterName } |
        Select-Object -First 1

    Assert-True -Condition ($null -ne $parameterAst) -Message "Expected $parameterName parameter."

    $parameterAttribute = $parameterAst.Attributes |
        Where-Object { $_.TypeName.FullName -eq 'Parameter' } |
        Select-Object -First 1
    $mandatoryArgument = $parameterAttribute.NamedArguments |
        Where-Object { $_.ArgumentName -eq 'Mandatory' } |
        Select-Object -First 1

    Assert-True -Condition (
        $null -ne $mandatoryArgument -and
        [bool]$mandatoryArgument.Argument.SafeGetValue()
    ) -Message "Expected $parameterName to be mandatory."
}

$maxJobsParameter = $scriptAst.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'MaxJobs' } |
    Select-Object -First 1
$threadsParameter = $scriptAst.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'ThreadsPerJob' } |
    Select-Object -First 1

Assert-True -Condition ($maxJobsParameter.DefaultValue.SafeGetValue() -eq 4) -Message 'Expected MaxJobs to default to 4.'
Assert-True -Condition ($threadsParameter.DefaultValue.SafeGetValue() -eq 8) -Message 'Expected ThreadsPerJob to default to 8.'

foreach ($requiredText in @(
    '[switch]$DryRun',
    '[string]$LogDirectory',
    'Assert-NoReparsePointInPath',
    'Assert-PathsDoNotOverlap',
    'SourcePath must not be inside DestinationPath',
    "'/XJ'",
    "'/COPY:DAT'",
    "'/DCOPY:DAT'",
    '"/UNILOG:$rootLogPath"',
    'Start-Job',
    'NoResult',
    'finally',
    'Highest Robocopy Exit Code'
)) {
    Assert-Contains -Haystack $scriptText -Needle $requiredText -Message "Expected canonical safety or execution behavior: $requiredText"
}

$stringConstants = @(
    $scriptAst.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        },
        $true
    ) | ForEach-Object { $_.Value }
)

foreach ($dangerousSwitch in @('/MIR', '/PURGE', '/MOV', '/MOVE')) {
    Assert-True -Condition ($dangerousSwitch -notin $stringConstants) -Message "Expected script not to add dangerous Robocopy switch $dangerousSwitch as an option."
}

Assert-NotContains -Haystack $scriptText -Needle '/LOG:NUL' -Message 'Expected output not to be discarded through /LOG:NUL.'
Assert-NotContains -Haystack $scriptText -Needle '[switch]$EnableLogging' -Message 'Expected the misleading V2 logging switch to be removed.'
Assert-NotContains -Haystack $scriptText -Needle 'Bytes/sec' -Message 'Expected locale-dependent speed parsing to be removed.'

foreach ($functionName in @(
    'ConvertTo-ComparablePath',
    'Test-IsChildPath',
    'Assert-PathsDoNotOverlap',
    'Assert-NoReparsePointInPath'
)) {
    $functionAst = $scriptAst.Find(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        },
        $true
    )

    Assert-True -Condition ($null -ne $functionAst) -Message "Expected function $functionName."
    $functionScript = [scriptblock]::Create($functionAst.Extent.Text)
    . $functionScript
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "robocopy-booster-guard-$([guid]::NewGuid().ToString('N'))"
$sourceRoot = Join-Path $testRoot 'source'
$destinationRoot = Join-Path $testRoot 'destination'
$sourceChild = Join-Path $sourceRoot 'child'

try {
    New-Item -ItemType Directory -Path $sourceChild -Force | Out-Null
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

    Assert-PathsDoNotOverlap -ResolvedSource $sourceRoot -ResolvedDestination $destinationRoot
    Assert-Throws -Action {
        Assert-PathsDoNotOverlap -ResolvedSource $sourceRoot -ResolvedDestination $sourceChild
    } -Message 'Expected destination-inside-source to be rejected.'
    Assert-Throws -Action {
        Assert-PathsDoNotOverlap -ResolvedSource $sourceChild -ResolvedDestination $sourceRoot
    } -Message 'Expected source-inside-destination to be rejected.'

    $linkPath = Join-Path $testRoot 'source-link'
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        New-Item -ItemType Junction -Path $linkPath -Target $sourceRoot | Out-Null
    }
    else {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $sourceRoot | Out-Null
    }

    $uncreatedChildThroughLink = Join-Path $linkPath 'new-child'
    Assert-Throws -Action {
        Assert-NoReparsePointInPath -Path $uncreatedChildThroughLink -Role 'TestPath'
    } -Message 'Expected a reparse-point ancestor to be rejected even when the destination leaf does not exist.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

function Invoke-BoosterSubprocess {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $processOutput = @(
        & $script:PowerShellExecutable -NoLogo -NoProfile -NonInteractive -File $scriptPath @Arguments 2>&1
    )
    $processExitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $processExitCode
        Output   = $processOutput
        Text     = $processOutput -join [System.Environment]::NewLine
    }
}

function Reset-CaptureFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$behaviorTempParent = if (
    [System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT -and
    (Test-Path -LiteralPath '/private/tmp' -PathType Container)
) {
    '/private/tmp'
}
else {
    [System.IO.Path]::GetTempPath()
}
$behaviorRoot = Join-Path $behaviorTempParent "robocopy booster behavior $([guid]::NewGuid().ToString('N'))"
$fakeBinDirectory = Join-Path $behaviorRoot 'fake bin'
$behaviorSource = Join-Path $behaviorRoot 'source data'
$capturePath = Join-Path $behaviorRoot 'captured arguments.txt'
$logDirectory = Join-Path $behaviorRoot 'logs with spaces'
$originalPath = $env:PATH
$originalCapture = $env:ROBOCOPY_BOOSTER_TEST_CAPTURE
$originalExitCode = $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE
$script:PowerShellExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

try {
    New-Item -ItemType Directory -Path $fakeBinDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $behaviorSource 'alpha one') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $behaviorSource 'beta') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $behaviorSource 'root.txt') -Value 'root'
    Set-Content -LiteralPath (Join-Path $behaviorSource 'alpha one/alpha.txt') -Value 'alpha'
    Set-Content -LiteralPath (Join-Path $behaviorSource 'beta/beta.txt') -Value 'beta'

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $fakeRobocopyPath = Join-Path $fakeBinDirectory 'robocopy.cmd'
        @(
            '@echo off',
            'setlocal DisableDelayedExpansion',
            ':capture_next',
            'if "%~1"=="" goto capture_done',
            '<nul set /p "=[%~1]" >>"%ROBOCOPY_BOOSTER_TEST_CAPTURE%"',
            'shift',
            'goto capture_next',
            ':capture_done',
            'echo.>>"%ROBOCOPY_BOOSTER_TEST_CAPTURE%"',
            'exit /b %ROBOCOPY_BOOSTER_TEST_EXIT_CODE%'
        ) | Set-Content -LiteralPath $fakeRobocopyPath -Encoding Ascii
    }
    else {
        $fakeRobocopyPath = Join-Path $fakeBinDirectory 'robocopy'
        @(
            '#!/bin/sh',
            'for robocopy_argument in "$@"; do',
            '    printf ''[%s]'' "$robocopy_argument" >> "$ROBOCOPY_BOOSTER_TEST_CAPTURE"',
            'done',
            'printf ''\n'' >> "$ROBOCOPY_BOOSTER_TEST_CAPTURE"',
            'exit "$ROBOCOPY_BOOSTER_TEST_EXIT_CODE"'
        ) | Set-Content -LiteralPath $fakeRobocopyPath -Encoding Ascii
        & chmod '+x' $fakeRobocopyPath
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to make the fake Robocopy executable.'
        }
    }

    $env:PATH = "$fakeBinDirectory$([System.IO.Path]::PathSeparator)$originalPath"
    $env:ROBOCOPY_BOOSTER_TEST_CAPTURE = $capturePath

    $sourceHashesBefore = @(
        Get-ChildItem -LiteralPath $behaviorSource -File -Recurse |
            Sort-Object FullName |
            ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    )

    $dryRunDestination = Join-Path $behaviorRoot 'dry run destination'
    $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE = '0'
    Reset-CaptureFile -Path $capturePath
    $dryRunResult = Invoke-BoosterSubprocess -Arguments @(
        '-SourcePath', $behaviorSource,
        '-DestinationPath', $dryRunDestination,
        '-MaxJobs', '1',
        '-DryRun'
    )

    Assert-True -Condition ($dryRunResult.ExitCode -eq 0) -Message "Expected dry run to succeed. Output: $($dryRunResult.Text)"
    Assert-True -Condition (-not (Test-Path -LiteralPath $dryRunDestination)) -Message 'Expected dry run not to create the destination.'
    $dryRunArguments = @(Get-Content -LiteralPath $capturePath)
    Assert-True -Condition ($dryRunArguments.Count -eq 3) -Message 'Expected one root-file job and two directory jobs in the dry run.'
    foreach ($argumentLine in $dryRunArguments) {
        Assert-Contains -Haystack $argumentLine -Needle '/L' -Message 'Expected every dry-run job to include /L.'
        Assert-NotContains -Haystack $argumentLine -Needle '/NFL' -Message 'Expected a no-log dry run to retain the file plan.'
        Assert-NotContains -Haystack $argumentLine -Needle '/NDL' -Message 'Expected a no-log dry run to retain the directory plan.'
    }
    $recursiveJobCount = @($dryRunArguments | Where-Object { $_ -match '\[/E\]' }).Count
    Assert-True -Condition ($recursiveJobCount -eq 2) -Message 'Expected only the two top-level directory jobs to use /E.'

    $warningDestination = Join-Path $behaviorRoot 'warning destination'
    $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE = '7'
    Reset-CaptureFile -Path $capturePath
    $warningResult = Invoke-BoosterSubprocess -Arguments @(
        '-SourcePath', $behaviorSource,
        '-DestinationPath', $warningDestination,
        '-MaxJobs', '1'
    )

    Assert-True -Condition ($warningResult.ExitCode -eq 0) -Message "Expected Robocopy exit 7 to produce script exit 0. Output: $($warningResult.Text)"
    Assert-True -Condition (Test-Path -LiteralPath $warningDestination -PathType Container) -Message 'Expected a live pass to create the destination.'
    $liveArguments = @(Get-Content -LiteralPath $capturePath)
    foreach ($argumentLine in $liveArguments) {
        Assert-Contains -Haystack $argumentLine -Needle '/NFL' -Message 'Expected a no-log live pass to suppress file listings.'
        Assert-Contains -Haystack $argumentLine -Needle '/NDL' -Message 'Expected a no-log live pass to suppress directory listings.'
        Assert-NotContains -Haystack $argumentLine -Needle '/L' -Message 'Expected a live pass not to include /L.'
    }

    $failureDestination = Join-Path $behaviorRoot 'failure destination'
    $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE = '8'
    Reset-CaptureFile -Path $capturePath
    $failureResult = Invoke-BoosterSubprocess -Arguments @(
        '-SourcePath', $behaviorSource,
        '-DestinationPath', $failureDestination,
        '-MaxJobs', '1',
        '-DryRun'
    )

    Assert-True -Condition ($failureResult.ExitCode -eq 1) -Message "Expected Robocopy exit 8 to produce script exit 1. Output: $($failureResult.Text)"
    Assert-Contains -Haystack $failureResult.Text -Needle 'Highest Robocopy Exit Code: 8' -Message 'Expected the failure summary to preserve the Robocopy exit code.'
    Assert-Contains -Haystack $failureResult.Text -Needle 'Failed job details:' -Message 'Expected failed jobs to include diagnostic details.'

    $loggedDestination = Join-Path $behaviorRoot 'logged dry run destination'
    $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE = '0'
    Reset-CaptureFile -Path $capturePath
    $loggedResult = Invoke-BoosterSubprocess -Arguments @(
        '-SourcePath', $behaviorSource,
        '-DestinationPath', $loggedDestination,
        '-MaxJobs', '1',
        '-LogDirectory', $logDirectory,
        '-DryRun'
    )

    Assert-True -Condition ($loggedResult.ExitCode -eq 0) -Message "Expected logged dry run to succeed. Output: $($loggedResult.Text)"
    Assert-True -Condition (Test-Path -LiteralPath $logDirectory -PathType Container) -Message 'Expected the requested log directory to be created.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $loggedDestination)) -Message 'Expected a logged dry run not to create the destination.'
    $loggedArguments = @(Get-Content -LiteralPath $capturePath)
    $logTargets = @()
    foreach ($argumentLine in $loggedArguments) {
        Assert-Contains -Haystack $argumentLine -Needle '/L' -Message 'Expected every logged dry-run job to include /L.'
        Assert-Contains -Haystack $argumentLine -Needle '/UNILOG:' -Message 'Expected every logged job to receive a Unicode log path.'
        Assert-Contains -Haystack $argumentLine -Needle 'logs with spaces' -Message 'Expected log paths containing spaces to remain one native argument.'

        if ($argumentLine -match '\[/UNILOG:([^\[\]]+?\.log)\]') {
            $logTargets += $Matches[1]
        }
    }

    Assert-True -Condition ($logTargets.Count -eq 3) -Message 'Expected to capture one log target per job.'
    Assert-True -Condition (@($logTargets | Select-Object -Unique).Count -eq 3) -Message 'Expected every job log filename to be unique.'

    $sourceHashesAfter = @(
        Get-ChildItem -LiteralPath $behaviorSource -File -Recurse |
            Sort-Object FullName |
            ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    )
    Assert-True -Condition (
        ($sourceHashesBefore -join ',') -eq ($sourceHashesAfter -join ',')
    ) -Message 'Expected all smoke runs to leave source file contents unchanged.'
}
finally {
    $env:PATH = $originalPath
    $env:ROBOCOPY_BOOSTER_TEST_CAPTURE = $originalCapture
    $env:ROBOCOPY_BOOSTER_TEST_EXIT_CODE = $originalExitCode

    if (Test-Path -LiteralPath $behaviorRoot) {
        Remove-Item -LiteralPath $behaviorRoot -Recurse -Force
    }
}

Assert-Contains -Haystack $readmeText -Needle 'media/robocopy-booster.png' -Message 'Expected README to include the behavior graphic.'
Assert-Contains -Haystack $readmeText -Needle 'single canonical script' -Message 'Expected README to document one canonical script.'
Assert-Contains -Haystack $readmeText -Needle 'one-way source-to-destination copy/update tool' -Message 'Expected README to document the one-way sync contract.'
Assert-Contains -Haystack $readmeText -Needle '/COPY:DAT and /DCOPY:DAT' -Message 'Expected README to document copied metadata.'
Assert-Contains -Haystack $readmeText -Needle 'does not copy ACLs, owners, or auditing information' -Message 'Expected README to document omitted security metadata.'
Assert-NotContains -Haystack $readmeText -Needle '.\robocopy-booster-v2.ps1' -Message 'Expected README examples not to invoke the removed V2 script.'
Assert-NotContains -Haystack $rootReadmeText -Needle 'V2 logging/no-logging' -Message 'Expected root README not to advertise the removed V2 experiment.'

if (-not (Test-Path -LiteralPath $behaviorImagePath)) {
    throw 'Expected Robocopy Booster behavior graphic to exist.'
}

Write-Output 'Robocopy-Booster static, guard, and behavior checks passed.'
