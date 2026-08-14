#requires -Version 5.1

<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************


Last Edit Date: 08/14/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script runs parallel Robocopy commands to accelerate many-small-file migrations.
It performs a one-way source-to-destination copy/update operation and does not use /MOV, /MOVE, /MIR, or /PURGE.
Source and destination trees must be separate, FileSystem-backed paths without reparse points in their path components.
Top-level source reparse directories are skipped, and Robocopy uses /XJ for junction points below each job root.

First run:
- Copies root files from the source to the destination.
- Copies each top-level source directory to the matching destination directory in parallel.

Reruns:
- Robocopy skips files that already match.
- New and changed source files are copied to the destination.
- Extra destination files are left in place.

Parameters:
-SourcePath: Required source directory path.
-DestinationPath: Required destination directory path.
-MaxJobs: Maximum number of parallel Robocopy jobs.
-ThreadsPerJob: Number of Robocopy /MT threads per job.
-RetryCount: Robocopy /R retry count.
-WaitSeconds: Robocopy /W wait time between retries.
-LogDirectory: Optional directory for one Unicode Robocopy log per job.
-DryRun: Adds Robocopy /L so actions are listed without writing to the destination.
#>

[CmdletBinding()]
param(
    [Alias('src')]
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Alias('dest')]
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [Alias('max_jobs')]
    [Parameter()]
    [ValidateRange(1, 256)]
    [int]$MaxJobs = 4,

    [Alias('mtreads', 'mtThreads', 'mthreads')]
    [Parameter()]
    [ValidateRange(1, 128)]
    [int]$ThreadsPerJob = 8,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$RetryCount = 1,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$WaitSeconds = 1,

    [Parameter()]
    [string]$LogDirectory,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-FileSystemDirectoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [switch]$MustExist,

        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Role cannot be empty."
    }

    $provider = $null
    $drive = $null

    try {
        $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path,
            [ref]$provider,
            [ref]$drive
        )
    }
    catch {
        throw "Unable to resolve $Role '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') {
        throw "$Role must use the FileSystem provider."
    }

    if (Test-Path -LiteralPath $providerPath) {
        if (-not (Test-Path -LiteralPath $providerPath -PathType Container)) {
            throw "$Role is not a directory: $providerPath"
        }
    }
    elseif ($MustExist) {
        throw "$Role does not exist: $providerPath"
    }

    return $providerPath
}

function Assert-NoReparsePointInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Unable to determine the root of $Role path: $Path"
    }

    $currentPath = $Path

    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        try {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            $item = $null
        }
        catch {
            throw "Unable to validate $Role path component '$currentPath': $($_.Exception.Message)"
        }

        if (
            $null -ne $item -and
            (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        ) {
            throw "$Role traverses a reparse point, junction, or symlink: $($item.FullName)"
        }

        $trimmedCurrent = $currentPath.TrimEnd([char[]]@('\', '/'))
        $trimmedRoot = $root.TrimEnd([char[]]@('\', '/'))
        if ($trimmedCurrent.Equals($trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent) {
            break
        }

        $currentPath = $parent.FullName
    }
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

function Assert-PathsDoNotOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSource,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedDestination
    )

    $sourceCompare = ConvertTo-ComparablePath -Path $ResolvedSource
    $destinationCompare = ConvertTo-ComparablePath -Path $ResolvedDestination

    if ($sourceCompare.Equals($destinationCompare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourcePath and DestinationPath resolve to the same directory. Choose separate directory trees.'
    }

    if (Test-IsChildPath -Path $ResolvedDestination -ParentPath $ResolvedSource) {
        throw 'DestinationPath must not be inside SourcePath because that would write under the source tree.'
    }

    if (Test-IsChildPath -Path $ResolvedSource -ParentPath $ResolvedDestination) {
        throw 'SourcePath must not be inside DestinationPath because overlapping trees can cause a job to write under the source tree.'
    }
}

function Receive-BoosterJobs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Jobs
    )

    $remainingJobs = @()

    foreach ($job in $Jobs) {
        $jobKey = $job.InstanceId.ToString()
        $jobIsTerminal = $job.State -in @('Completed', 'Failed', 'Stopped')
        $received = if ($jobIsTerminal) {
            @(Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue)
        }
        else {
            @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        foreach ($outputItem in $received) {
            if ($null -eq $outputItem) {
                continue
            }

            if ($outputItem.PSObject.Properties.Name -contains 'ExitCode') {
                if ($script:JobResultBuffers.ContainsKey($jobKey)) {
                    $script:JobResultBuffers[$jobKey] = @($script:JobResultBuffers[$jobKey]) + $outputItem
                }
                else {
                    $script:JobResultBuffers[$jobKey] = @($outputItem)
                }
            }
            else {
                Write-Host $outputItem
            }
        }

        if (-not $jobIsTerminal) {
            $remainingJobs += $job
            continue
        }

        $resultObjects = if ($script:JobResultBuffers.ContainsKey($jobKey)) {
            @($script:JobResultBuffers[$jobKey])
        }
        else {
            @()
        }
        $null = $script:JobResultBuffers.Remove($jobKey)

        if ($job.State -eq 'Completed' -and $resultObjects.Count -eq 1) {
            $jobResult = $resultObjects[0]
            $script:JobResults += $jobResult
            $color = if ($jobResult.ExitCode -ge 8) { 'Red' } elseif ($jobResult.ExitCode -ge 4) { 'Yellow' } else { 'Green' }
            Write-Host "Completed: $($jobResult.Name) (Robocopy exit code: $($jobResult.ExitCode))" -ForegroundColor $color
        }
        else {
            $status = if ($job.State -eq 'Completed') { 'NoResult' } else { $job.State }
            $jobReason = $job.JobStateInfo.Reason
            if ($null -eq $jobReason) {
                $jobReason = $job.ChildJobs |
                    ForEach-Object { $_.JobStateInfo.Reason } |
                    Where-Object { $null -ne $_ } |
                    Select-Object -First 1
            }

            $reason = if ($null -ne $jobReason) {
                $jobReason.Message
            }
            else {
                'The job did not return exactly one result object.'
            }

            $script:JobResults += [pscustomobject]@{
                Name        = $job.Name
                Source      = ''
                Destination = ''
                ExitCode    = 16
                CompletedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                LogPath     = ''
                Status      = $status
                Message     = $reason
            }
        }

        Remove-Job -Job $job -Force
    }

    return $remainingJobs
}

function ConvertTo-LogFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunIdentifier,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    $safeName = [regex]::Replace($Name, '[^\p{L}\p{Nd}._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'job'
    }

    if ($safeName.Length -gt 80) {
        $safeName = $safeName.Substring(0, 80)
    }

    return ('{0}-{1:D4}-{2}.log' -f $RunIdentifier, $Index, $safeName)
}

$robocopyCommand = Get-Command robocopy -CommandType Application -ErrorAction SilentlyContinue

if (-not $robocopyCommand) {
    Write-Error 'Robocopy was not found. Run this script on Windows with Robocopy available in PATH.'
    exit 1
}

$resolvedSource = Resolve-FileSystemDirectoryPath -Path $SourcePath -MustExist -Role 'SourcePath'
$resolvedDestination = Resolve-FileSystemDirectoryPath -Path $DestinationPath -Role 'DestinationPath'

Assert-NoReparsePointInPath -Path $resolvedSource -Role 'SourcePath'
Assert-NoReparsePointInPath -Path $resolvedDestination -Role 'DestinationPath'
Assert-PathsDoNotOverlap -ResolvedSource $resolvedSource -ResolvedDestination $resolvedDestination

$resolvedLogDirectory = $null
if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
    $resolvedLogDirectory = Resolve-FileSystemDirectoryPath -Path $LogDirectory -Role 'LogDirectory'
    Assert-NoReparsePointInPath -Path $resolvedLogDirectory -Role 'LogDirectory'

    if (
        (ConvertTo-ComparablePath -Path $resolvedLogDirectory).Equals(
            (ConvertTo-ComparablePath -Path $resolvedSource),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        (Test-IsChildPath -Path $resolvedLogDirectory -ParentPath $resolvedSource)
    ) {
        throw 'LogDirectory must not be SourcePath or a directory inside SourcePath.'
    }

    if (
        (ConvertTo-ComparablePath -Path $resolvedLogDirectory).Equals(
            (ConvertTo-ComparablePath -Path $resolvedDestination),
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        (Test-IsChildPath -Path $resolvedLogDirectory -ParentPath $resolvedDestination)
    ) {
        throw 'LogDirectory must not be DestinationPath or a directory inside DestinationPath.'
    }

}

if (-not $DryRun -and -not (Test-Path -LiteralPath $resolvedDestination)) {
    New-Item -ItemType Directory -Path $resolvedDestination -Force | Out-Null
    Assert-NoReparsePointInPath -Path $resolvedDestination -Role 'DestinationPath'
}

if ($null -ne $resolvedLogDirectory -and -not (Test-Path -LiteralPath $resolvedLogDirectory)) {
    New-Item -ItemType Directory -Path $resolvedLogDirectory -Force | Out-Null
    Assert-NoReparsePointInPath -Path $resolvedLogDirectory -Role 'LogDirectory'
}

$rootFiles = @(Get-ChildItem -LiteralPath $resolvedSource -File -Force)
$allDirectories = @(Get-ChildItem -LiteralPath $resolvedSource -Directory -Force)
$directories = @($allDirectories | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 })
$skippedReparseDirectories = @($allDirectories | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })

Write-Host '=== Robocopy Booster - Configuration ===' -ForegroundColor Cyan
Write-Host "Source Path: $resolvedSource" -ForegroundColor White
Write-Host "Destination Path: $resolvedDestination" -ForegroundColor White
Write-Host "Max Parallel Jobs: $MaxJobs" -ForegroundColor White
Write-Host "Threads per Job: $ThreadsPerJob" -ForegroundColor White
Write-Host "Retry/Wait: /R:$RetryCount /W:$WaitSeconds" -ForegroundColor White
Write-Host "Dry Run: $($DryRun.IsPresent)" -ForegroundColor White
Write-Host "Log Directory: $(if ($null -eq $resolvedLogDirectory) { 'Not enabled' } else { $resolvedLogDirectory })" -ForegroundColor White
Write-Host 'Sync Mode: source-to-destination copy/update only; no source deletes, moves, or renames.' -ForegroundColor Green
Write-Host 'Destination extras are left in place; this is not a mirror/purge operation.' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Cyan

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

$workItems = @()
$workItemIndex = 0
$runIdentifier = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))

if ($rootFiles.Count -gt 0) {
    $workItemIndex++
    $rootOptions = @($commonOptions)
    $rootLogPath = ''

    if ($null -eq $resolvedLogDirectory -and -not $DryRun) {
        $rootOptions += @('/NFL', '/NDL', '/NJH', '/NP')
    }
    elseif ($null -eq $resolvedLogDirectory) {
        $rootOptions += '/NP'
    }
    else {
        $rootLogPath = Join-Path -Path $resolvedLogDirectory -ChildPath (
            ConvertTo-LogFileName -RunIdentifier $runIdentifier -Name 'root-files' -Index $workItemIndex
        )
        $rootOptions += "/UNILOG:$rootLogPath"
    }

    $workItems += [pscustomobject]@{
        Name          = 'Root files'
        Source        = $resolvedSource
        Destination   = $resolvedDestination
        Options       = $rootOptions
        LogPath       = $rootLogPath
    }
}

foreach ($directory in $directories) {
    $workItemIndex++
    $directoryOptions = @('/E') + $commonOptions
    $directoryLogPath = ''

    if ($null -eq $resolvedLogDirectory -and -not $DryRun) {
        $directoryOptions += @('/NFL', '/NDL', '/NJH', '/NP')
    }
    elseif ($null -eq $resolvedLogDirectory) {
        $directoryOptions += '/NP'
    }
    else {
        $directoryLogPath = Join-Path -Path $resolvedLogDirectory -ChildPath (
            ConvertTo-LogFileName -RunIdentifier $runIdentifier -Name $directory.Name -Index $workItemIndex
        )
        $directoryOptions += "/UNILOG:$directoryLogPath"
    }

    $workItems += [pscustomobject]@{
        Name          = $directory.Name
        Source        = $directory.FullName
        Destination   = Join-Path -Path $resolvedDestination -ChildPath $directory.Name
        Options       = $directoryOptions
        LogPath       = $directoryLogPath
    }
}

foreach ($workItem in $workItems) {
    Assert-NoReparsePointInPath -Path $workItem.Source -Role "Source job root '$($workItem.Name)'"
    Assert-NoReparsePointInPath -Path $workItem.Destination -Role "Destination job root '$($workItem.Name)'"
    if (-not [string]::IsNullOrWhiteSpace($workItem.LogPath)) {
        Assert-NoReparsePointInPath -Path $workItem.LogPath -Role "Log file for '$($workItem.Name)'"
    }
}

$activeJobLimit = [math]::Min($MaxJobs, $workItems.Count)
$maximumActiveCopyThreads = $activeJobLimit * $ThreadsPerJob
$processorCount = [System.Environment]::ProcessorCount
$generalThreadGuidance = $processorCount * 2

Write-Host "Maximum simultaneous Robocopy threads: $maximumActiveCopyThreads" -ForegroundColor White
if ($maximumActiveCopyThreads -gt $generalThreadGuidance) {
    Write-Warning "The configured aggregate can exceed two copy threads per processor ($generalThreadGuidance on this host). Benchmark lower values if throughput or latency degrades."
}

$copyJobScript = {
    param(
        [string]$JobName,
        [string]$JobSource,
        [string]$JobDestination,
        [string[]]$RobocopyOptions,
        [string]$RobocopyPath,
        [string]$JobLogPath
    )

    $ErrorActionPreference = 'Stop'

    $robocopyArguments = @($JobSource, $JobDestination) + $RobocopyOptions

    & $RobocopyPath @robocopyArguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 16 } else { [int]$LASTEXITCODE }

    [pscustomobject]@{
        Name        = $JobName
        Source      = $JobSource
        Destination = $JobDestination
        ExitCode    = $exitCode
        CompletedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        LogPath     = $JobLogPath
        Status      = 'Completed'
        Message     = ''
    }
}

$startTime = Get-Date
$activeJobs = @()
$script:JobResults = @()
$script:JobResultBuffers = @{}
$totalJobs = $workItems.Count

try {
    foreach ($workItem in $workItems) {
        while ($activeJobs.Count -ge $MaxJobs) {
            Start-Sleep -Milliseconds 250
            $activeJobs = @(Receive-BoosterJobs -Jobs $activeJobs)

            $completedCount = $script:JobResults.Count
            $percentComplete = [math]::Min(100, [math]::Round(($completedCount / $totalJobs) * 100, 1))
            Write-Progress -Activity 'Processing Robocopy jobs' -Status "Completed $completedCount of $totalJobs" -PercentComplete $percentComplete
        }

        Assert-NoReparsePointInPath -Path $workItem.Source -Role "Source job root '$($workItem.Name)'"
        Assert-NoReparsePointInPath -Path $workItem.Destination -Role "Destination job root '$($workItem.Name)'"
        if (-not [string]::IsNullOrWhiteSpace($workItem.LogPath)) {
            Assert-NoReparsePointInPath -Path $workItem.LogPath -Role "Log file for '$($workItem.Name)'"
        }

        Write-Host "Starting: $($workItem.Name)" -ForegroundColor White
        $jobName = "RobocopyBooster-$($workItem.Name)-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $activeJobs += Start-Job -Name $jobName -ScriptBlock $copyJobScript -ArgumentList @(
            $workItem.Name,
            $workItem.Source,
            $workItem.Destination,
            $workItem.Options,
            $robocopyCommand.Source,
            $workItem.LogPath
        )
    }

    while ($activeJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 500
        $activeJobs = @(Receive-BoosterJobs -Jobs $activeJobs)

        $completedCount = $script:JobResults.Count
        $percentComplete = [math]::Min(100, [math]::Round(($completedCount / $totalJobs) * 100, 1))
        Write-Progress -Activity 'Processing Robocopy jobs' -Status "Completed $completedCount of $totalJobs" -PercentComplete $percentComplete
    }
}
finally {
    Write-Progress -Activity 'Processing Robocopy jobs' -Completed

    foreach ($job in $activeJobs) {
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }

        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

$duration = New-TimeSpan -Start $startTime -End (Get-Date)
$successfulJobs = @($script:JobResults | Where-Object { $_.ExitCode -lt 4 }).Count
$warningJobs = @($script:JobResults | Where-Object { $_.ExitCode -ge 4 -and $_.ExitCode -lt 8 }).Count
$errorJobs = @($script:JobResults | Where-Object { $_.ExitCode -ge 8 }).Count
$failedJobResults = @($script:JobResults | Where-Object { $_.ExitCode -ge 8 })
$maxExitCode = if ($script:JobResults.Count -gt 0) {
    ($script:JobResults | Measure-Object -Property ExitCode -Maximum).Maximum
}
else {
    16
}

Write-Host ''
Write-Host '=== Robocopy Booster - Results ===' -ForegroundColor Cyan
Write-Host "Total Execution Time: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor Green
Write-Host "Jobs Executed: $totalJobs" -ForegroundColor White
Write-Host "Root Files Job: $(if ($rootFiles.Count -gt 0) { "Yes ($($rootFiles.Count) file(s))" } else { 'No' })" -ForegroundColor White
Write-Host "Directories Processed: $($directories.Count)" -ForegroundColor White
Write-Host "Successful Jobs (0-3): $successfulJobs" -ForegroundColor Green
Write-Host "Warning Jobs (4-7): $warningJobs" -ForegroundColor Yellow
Write-Host "Error Jobs (8+): $errorJobs" -ForegroundColor Red
Write-Host "Highest Robocopy Exit Code: $maxExitCode" -ForegroundColor White
if ($null -ne $resolvedLogDirectory) {
    Write-Host "Per-job logs: $resolvedLogDirectory" -ForegroundColor White
}
if ($failedJobResults.Count -gt 0) {
    Write-Host 'Failed job details:' -ForegroundColor Red
    foreach ($failedJobResult in $failedJobResults) {
        $failureMessage = if ([string]::IsNullOrWhiteSpace($failedJobResult.Message)) {
            "Robocopy returned exit code $($failedJobResult.ExitCode)."
        }
        else {
            $failedJobResult.Message
        }
        $failureLog = if ([string]::IsNullOrWhiteSpace($failedJobResult.LogPath)) { 'not enabled' } else { $failedJobResult.LogPath }
        Write-Host "- $($failedJobResult.Name): exit $($failedJobResult.ExitCode), $($failedJobResult.Status); $failureMessage Log: $failureLog" -ForegroundColor Red
    }
}
Write-Host '==================================' -ForegroundColor Cyan

if ($maxExitCode -ge 8) {
    exit 1
}

exit 0
