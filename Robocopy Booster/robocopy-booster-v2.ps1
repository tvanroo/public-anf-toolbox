<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************


Last Edit Date: 06/03/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
Enhanced Robocopy Booster with logging/no-logging A/B testing, per-job speed reporting, and dry-run support.
It performs a one-way source-to-destination copy/update operation. It does not use /MOV, /MOVE, /MIR, or /PURGE.
It also avoids junction traversal with /XJ and skips top-level source reparse directories.

First run:
- Copies root files from the source to the destination.
- Copies each top-level source directory to the matching destination directory in parallel.

Reruns:
- Robocopy skips files that already match.
- New and changed source files are copied to the destination.
- Extra destination files are left in place.

Parameters:
-SourcePath: Source directory path.
-DestinationPath: Destination directory path.
-MaxJobs: Maximum number of parallel Robocopy jobs.
-ThreadsPerJob: Number of Robocopy /MT threads per job.
-EnableLogging: Shows normal Robocopy output. Omit it for silent/no-logging mode.
-RetryCount: Robocopy /R retry count.
-WaitSeconds: Robocopy /W wait time between retries.
-DryRun: Adds Robocopy /L so actions are listed without writing to the destination.
#>

[CmdletBinding()]
param(
    [Alias('src')]
    [Parameter()]
    [string]$SourcePath = 'Z:\',

    [Alias('dest')]
    [Parameter()]
    [string]$DestinationPath = 'C:\txtest',

    [Alias('max_jobs')]
    [Parameter()]
    [ValidateRange(1, 256)]
    [int]$MaxJobs = 12,

    [Alias('mtreads', 'mtThreads', 'mthreads')]
    [Parameter()]
    [ValidateRange(1, 128)]
    [int]$ThreadsPerJob = 128,

    [Parameter()]
    [switch]$EnableLogging,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$RetryCount = 1,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$WaitSeconds = 1,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-DirectoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Directory path cannot be empty.'
    }

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Path is not a directory: $Path"
        }

        return (Resolve-Path -LiteralPath $Path).Path
    }

    if ($MustExist) {
        throw "Directory does not exist: $Path"
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-ComparablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trimmed = $Path.TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $Path
    }

    return $trimmed
}

function Test-IsChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $child = ConvertTo-ComparablePath -Path $Path
    $parent = ConvertTo-ComparablePath -Path $ParentPath

    return (
        $child.StartsWith("$parent\", [System.StringComparison]::OrdinalIgnoreCase) -or
        $child.StartsWith("$parent/", [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Receive-BoosterJobs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Jobs
    )

    $remainingJobs = @()

    foreach ($job in $Jobs) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $received = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)

            foreach ($item in $received) {
                if ($null -ne $item -and $item.PSObject.Properties.Name -contains 'ExitCode') {
                    $script:JobResults += $item
                }
            }

            if ($job.State -ne 'Completed') {
                $script:JobResults += [pscustomobject]@{
                    Name        = $job.Name
                    Source      = ''
                    Destination = ''
                    ExitCode    = 16
                    CompletedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    Speed       = ''
                    Status      = $job.State
                }
            }

            Remove-Job -Job $job -Force
        }
        else {
            $remainingJobs += $job
        }
    }

    return $remainingJobs
}

$robocopyCommand = Get-Command robocopy.exe -ErrorAction SilentlyContinue
if (-not $robocopyCommand) {
    $robocopyCommand = Get-Command robocopy -ErrorAction SilentlyContinue
}

if (-not $robocopyCommand) {
    Write-Error 'Robocopy was not found. Run this script on Windows with Robocopy available in PATH.'
    exit 1
}

$resolvedSource = Resolve-DirectoryPath -Path $SourcePath -MustExist
$resolvedDestination = Resolve-DirectoryPath -Path $DestinationPath
$sourceCompare = ConvertTo-ComparablePath -Path $resolvedSource
$destinationCompare = ConvertTo-ComparablePath -Path $resolvedDestination

if ($sourceCompare.Equals($destinationCompare, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error 'SourcePath and DestinationPath resolve to the same directory. Choose a separate destination.'
    exit 1
}

if (Test-IsChildPath -Path $resolvedDestination -ParentPath $resolvedSource) {
    Write-Error 'DestinationPath must not be inside SourcePath because that would create or update files under the source tree.'
    exit 1
}

$destinationItem = Get-Item -LiteralPath $resolvedDestination -Force -ErrorAction SilentlyContinue
if ($null -ne $destinationItem -and (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    Write-Error 'DestinationPath must not be a reparse point, junction, or symlink. Use the real destination path to avoid writing through a link.'
    exit 1
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $resolvedDestination)) {
    New-Item -ItemType Directory -Path $resolvedDestination -Force | Out-Null
}

$rootFiles = @(Get-ChildItem -LiteralPath $resolvedSource -File -Force)
$allDirectories = @(Get-ChildItem -LiteralPath $resolvedSource -Directory -Force)
$directories = @($allDirectories | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 })
$skippedReparseDirectories = @($allDirectories | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })

Write-Host '=== Robocopy Booster V2 - Configuration ===' -ForegroundColor Cyan
Write-Host "Source Path: $resolvedSource" -ForegroundColor White
Write-Host "Destination Path: $resolvedDestination" -ForegroundColor White
Write-Host "Max Parallel Jobs: $MaxJobs" -ForegroundColor White
Write-Host "Threads per Job: $ThreadsPerJob" -ForegroundColor White
Write-Host "Retry/Wait: /R:$RetryCount /W:$WaitSeconds" -ForegroundColor White
Write-Host "Logging Mode: $(if ($EnableLogging) { 'Enabled' } else { 'Silent' })" -ForegroundColor $(if ($EnableLogging) { 'Green' } else { 'Yellow' })
Write-Host "Dry Run: $($DryRun.IsPresent)" -ForegroundColor White
Write-Host 'Sync Mode: source-to-destination copy/update only; no source deletes, moves, or renames.' -ForegroundColor Green
Write-Host 'Destination extras are left in place; this is not a mirror/purge operation.' -ForegroundColor Green
Write-Host '===========================================' -ForegroundColor Cyan

Write-Host "Found $($rootFiles.Count) root file(s)." -ForegroundColor Cyan
Write-Host "Found $($directories.Count) top-level director$(if ($directories.Count -eq 1) { 'y' } else { 'ies' }) to process." -ForegroundColor Cyan
if ($skippedReparseDirectories.Count -gt 0) {
    Write-Host "Skipped $($skippedReparseDirectories.Count) top-level reparse director$(if ($skippedReparseDirectories.Count -eq 1) { 'y' } else { 'ies' })." -ForegroundColor Yellow
}

if ($rootFiles.Count -eq 0 -and $directories.Count -eq 0) {
    Write-Host "No files or directories found in source path '$resolvedSource'. Nothing to copy." -ForegroundColor Yellow
    exit 0
}

$commonOptions = @(
    '/XJ',
    '/COPY:DAT',
    '/DCOPY:DAT',
    "/R:$RetryCount",
    "/W:$WaitSeconds",
    "/MT:$ThreadsPerJob"
)

if ($DryRun) {
    $commonOptions += '/L'
}

if (-not $EnableLogging) {
    $commonOptions += @('/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS', '/LOG:NUL')
}

$directoryOptions = @('/E') + $commonOptions
$rootFileOptions = $commonOptions

$workItems = @()
if ($rootFiles.Count -gt 0) {
    $workItems += [pscustomobject]@{
        Name          = 'Root files'
        Source        = $resolvedSource
        Destination   = $resolvedDestination
        RootFilesOnly = $true
        Options       = $rootFileOptions
    }
}

foreach ($directory in $directories) {
    $workItems += [pscustomobject]@{
        Name          = $directory.Name
        Source        = $directory.FullName
        Destination   = Join-Path -Path $resolvedDestination -ChildPath $directory.Name
        RootFilesOnly = $false
        Options       = $directoryOptions
    }
}

$copyJobScript = {
    param(
        [string]$JobName,
        [string]$JobSource,
        [string]$JobDestination,
        [bool]$RootFilesOnly,
        [string[]]$RobocopyOptions,
        [string]$RobocopyPath,
        [bool]$ShowRobocopyOutput
    )

    $robocopyArguments = if ($RootFilesOnly) {
        @($JobSource, $JobDestination, '*') + $RobocopyOptions
    }
    else {
        @($JobSource, $JobDestination) + $RobocopyOptions
    }

    Write-Host "Starting: $JobName" -ForegroundColor White
    $robocopyOutput = @()
    if ($ShowRobocopyOutput) {
        $robocopyOutput = @(& $RobocopyPath @robocopyArguments)
        $robocopyOutput | ForEach-Object { Write-Host $_ }
    }
    else {
        & $RobocopyPath @robocopyArguments | Out-Null
    }
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    $speed = ''
    if ($ShowRobocopyOutput -and $robocopyOutput.Count -gt 0) {
        $speedLine = $robocopyOutput | Where-Object { $_ -match 'Bytes/sec' } | Select-Object -First 1
        if ($speedLine -match '([\d,]+(?:\.\d+)?)\s+Bytes/sec') {
            $bytesPerSecond = ($Matches[1] -replace ',', '')
            $speed = "$([math]::Round(([double]$bytesPerSecond / 1MB), 2)) MB/s"
        }
    }

    $speedInfo = if ([string]::IsNullOrWhiteSpace($speed)) { '' } else { " - $speed" }
    $color = if ($exitCode -ge 8) { 'Red' } elseif ($exitCode -ge 4) { 'Yellow' } else { 'Green' }
    Write-Host "Completed: $JobName (Robocopy exit code: $exitCode)$speedInfo" -ForegroundColor $color

    [pscustomobject]@{
        Name        = $JobName
        Source      = $JobSource
        Destination = $JobDestination
        ExitCode    = $exitCode
        CompletedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Speed       = $speed
        Status      = 'Completed'
    }
}

$startTime = Get-Date
$activeJobs = @()
$script:JobResults = @()
$totalJobs = $workItems.Count

foreach ($workItem in $workItems) {
    while ($activeJobs.Count -ge $MaxJobs) {
        Start-Sleep -Milliseconds 250
        $activeJobs = @(Receive-BoosterJobs -Jobs $activeJobs)

        $completedCount = $script:JobResults.Count
        $percentComplete = [math]::Min(100, [math]::Round(($completedCount / $totalJobs) * 100, 1))
        Write-Progress -Activity 'Processing Robocopy jobs' -Status "Completed $completedCount of $totalJobs" -PercentComplete $percentComplete
    }

    $jobName = "RobocopyBoosterV2-$($workItem.Name)-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $activeJobs += Start-Job -Name $jobName -ScriptBlock $copyJobScript -ArgumentList @(
        $workItem.Name,
        $workItem.Source,
        $workItem.Destination,
        $workItem.RootFilesOnly,
        $workItem.Options,
        $robocopyCommand.Source,
        $EnableLogging.IsPresent
    )
}

while ($activeJobs.Count -gt 0) {
    Start-Sleep -Milliseconds 500
    $activeJobs = @(Receive-BoosterJobs -Jobs $activeJobs)

    $completedCount = $script:JobResults.Count
    $percentComplete = [math]::Min(100, [math]::Round(($completedCount / $totalJobs) * 100, 1))
    Write-Progress -Activity 'Processing Robocopy jobs' -Status "Completed $completedCount of $totalJobs" -PercentComplete $percentComplete
}

Write-Progress -Activity 'Processing Robocopy jobs' -Completed

$duration = New-TimeSpan -Start $startTime -End (Get-Date)
$successfulJobs = @($script:JobResults | Where-Object { $_.ExitCode -lt 4 }).Count
$warningJobs = @($script:JobResults | Where-Object { $_.ExitCode -ge 4 -and $_.ExitCode -lt 8 }).Count
$errorJobs = @($script:JobResults | Where-Object { $_.ExitCode -ge 8 }).Count
$maxExitCode = if ($script:JobResults.Count -gt 0) {
    ($script:JobResults | Measure-Object -Property ExitCode -Maximum).Maximum
}
else {
    0
}
$speedResults = @($script:JobResults | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Speed) })

Write-Host ''
Write-Host '=== Robocopy Booster V2 - Results ===' -ForegroundColor Cyan
Write-Host "Total Execution Time: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Green
Write-Host "Jobs Executed: $totalJobs" -ForegroundColor White
Write-Host "Root Files Job: $(if ($rootFiles.Count -gt 0) { "Yes ($($rootFiles.Count) file(s))" } else { 'No' })" -ForegroundColor White
Write-Host "Directories Processed: $($directories.Count)" -ForegroundColor White
Write-Host "Successful Jobs (0-3): $successfulJobs" -ForegroundColor Green
Write-Host "Warning Jobs (4-7): $warningJobs" -ForegroundColor Yellow
Write-Host "Error Jobs (8+): $errorJobs" -ForegroundColor Red
Write-Host "Highest Robocopy Exit Code: $maxExitCode" -ForegroundColor White
Write-Host "Logging Mode Used: $(if ($EnableLogging) { 'Enabled' } else { 'Silent' })" -ForegroundColor $(if ($EnableLogging) { 'Green' } else { 'Yellow' })
if ($speedResults.Count -gt 0) {
    Write-Host "Jobs with reported speed: $($speedResults.Count)" -ForegroundColor White
}
Write-Host '=====================================' -ForegroundColor Cyan

if ($maxExitCode -ge 8) {
    exit 1
}

exit 0
