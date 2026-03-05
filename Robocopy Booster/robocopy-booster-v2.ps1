<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************


Last Edit Date: 07/24/2025
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
Enhanced version of the Robocopy Booster that includes A/B testing capabilities for logging vs no-logging modes.
This script runs parallel robocopy commands as PowerShell Jobs to speed up tiny file migrations. 
The script includes a flag to switch between normal logging and silent/no-logging modes for performance testing.
The script handles both files in the root directory and subdirectories, processing them in parallel for optimal performance.

Key Enhancements in V2:
- Added $EnableLogging flag for A/B testing between logging and no-logging modes
- Silent mode uses switches: /NFL /NDL /NJH /NJS /NP /NC /NS /LOG:NUL
- Improved error handling and reduced retry/wait times (/R:0 /W:0)
- Performance optimized for maximum throughput testing
- Handles both root directory files and subdirectories in parallel

Parameters: 
$max_jobs: The maximum number of parallel jobs to run.
$mtreads: Change this to the number of threads to use for each robocopy job
$src: Change this to a directory which contains files and/or subdirectories to be copied in parallel 
$dest: Change this to where you want to backup your files to
$EnableLogging: Set to $true for normal logging, $false for silent/no-logging mode (A/B testing)

Processing Logic:
- Root directory files are copied as a single job (if any exist)
- Each subdirectory is processed as a separate parallel job
- Both root files and subdirectories can be processed simultaneously

Test results from sample size test. 100x 1k files, transferred over 1Gbps network:

Jobs/Threads 	1/1
TotalSeconds    65.037575

Jobs/Threads  	1/256
TotalSeconds    65.3446001

Jobs/Threads 	256/1
TotalSeconds    16.1439964

Jobs/Threads	2/1
TotalSeconds    39.8715172

Jobs/Threads 	16/16
TotalSeconds    16.2536195

Expected Performance Impact:
- No-logging mode should show 5-15% performance improvement
- Larger datasets with many small files will see more benefit
- Network-bound transfers may see minimal improvement

#>

# User Editable Variables:
$max_jobs = 12              # Change this to the number of parallel Robocopy jobs to run 
$mtreads = 128               # Change this to the number of threads to use for each robocopy job (used with the /mt switch)
$src = "Z:\"          # Set $src to a the local folder or share from which you want to copy the data
$dest = "C:\txtest"         # Set $dest to a local folder or share to which you want to copy the data
$EnableLogging = $false     # Set to $true for normal logging, $false for silent/no-logging mode (A/B Testing)

# Display current configuration
Write-Host "=== Robocopy Booster V2 - Configuration ===" -ForegroundColor Cyan
Write-Host "Source Path: $src" -ForegroundColor White
Write-Host "Destination Path: $dest" -ForegroundColor White
Write-Host "Max Parallel Jobs: $max_jobs" -ForegroundColor White
Write-Host "Threads per Job: $mtreads" -ForegroundColor White
Write-Host "Logging Mode: $(if($EnableLogging){'Enabled (Normal)'}else{'Disabled (Silent)'})" -ForegroundColor $(if($EnableLogging){'Green'}else{'Yellow'})
Write-Host "=============================================" -ForegroundColor Cyan

# Verify source path exists
if (-not (Test-Path $src)) {
    Write-Host "ERROR: Source path '$src' does not exist!" -ForegroundColor Red
    exit 1
}

# Create destination path if it doesn't exist
if (-not (Test-Path $dest)) {
    Write-Host "Creating destination path: $dest" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}

# Script execution
$tstart = Get-Date 
Write-Host "Starting parallel robocopy operations at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green

# Check for files in the root directory
$rootFiles = Get-ChildItem $src -File
$directories = Get-ChildItem $src -Directory

Write-Host "Found $($rootFiles.Count) files in root directory" -ForegroundColor Cyan
Write-Host "Found $($directories.Count) subdirectories to process" -ForegroundColor Cyan

if ($rootFiles.Count -eq 0 -and $directories.Count -eq 0) {
    Write-Host "WARNING: No files or subdirectories found in source path '$src'" -ForegroundColor Yellow
    Write-Host "Nothing to copy. Exiting." -ForegroundColor Red
    exit 0
}

# Create array to track all jobs
$allJobs = @()

# If there are root files, create a job to copy them
if ($rootFiles.Count -gt 0) {
    Write-Host "Creating job for root directory files..." -ForegroundColor Yellow
    
    $RootScriptBlock = {
        param($src, $dest, $mtreads, $EnableLogging)
        
        # Build robocopy command for root files only (not subdirectories)
        if ($EnableLogging) {
            # Normal logging mode - copy only files, not subdirectories
            Write-Host "Processing Root Files (Normal): $(Split-Path $src -Leaf)" -ForegroundColor White
            $result = robocopy $src $dest *.* /COPY:DAT /R:1 /W:1 /MT:$mtreads
        } else {
            # Silent/no-logging mode for performance testing - copy only files, not subdirectories
            Write-Host "Processing Root Files (Silent): $(Split-Path $src -Leaf)" -ForegroundColor Gray
            $result = robocopy $src $dest *.* /COPY:DAT /R:0 /W:0 /MT:$mtreads /NFL /NDL /NJH /NJS /NP /NC /NS /LOG:NUL
        }
        
        # Return job completion info
        $exitCode = $LASTEXITCODE
        $timestamp = Get-Date -Format 'HH:mm:ss'
        
        if ($exitCode -le 3) {
            Write-Host "[$timestamp] Completed: Root Files (Exit Code: $exitCode)" -ForegroundColor Green
        } else {
            Write-Host "[$timestamp] Warning/Error: Root Files (Exit Code: $exitCode)" -ForegroundColor Yellow
        }
        
        return @{
            Name = "Root Files"
            ExitCode = $exitCode
            Timestamp = $timestamp
        }
    }
    
    # Start the root files job
    $rootJob = Start-Job -ScriptBlock $RootScriptBlock -ArgumentList $src, $dest, $mtreads, $EnableLogging
    $allJobs += $rootJob
}

# Process subdirectories in parallel
$directories | ForEach-Object {
    $ScriptBlock = {
        param($name, $src, $dest, $mtreads, $EnableLogging)
        
        # Remove the final character from $name if it is a backslash
        if ($name.EndsWith("\")) {
            $name = $name.Substring(0, $name.Length - 1)
        }
        
        $srcPath = Join-Path -Path $src -ChildPath $name
        $destPath = Join-Path -Path $dest -ChildPath $name
          # Build robocopy command based on logging preference
        if ($EnableLogging) {
            # Normal logging mode
            Write-Host "Processing (Normal): $name" -ForegroundColor White
            $result = robocopy $srcPath $destPath /E /COPY:DAT /DCOPY:T /R:1 /W:1 /MT:$mtreads
        } else {
            # Silent/no-logging mode for performance testing
            Write-Host "Processing (Silent): $name" -ForegroundColor Gray
            $result = robocopy $srcPath $destPath /E /COPY:DAT /DCOPY:T /R:0 /W:0 /MT:$mtreads /NFL /NDL /NJH /NJS /NP /NC /NS /LOG:NUL
        }
        
        # Return job completion info
        $exitCode = $LASTEXITCODE
        $timestamp = Get-Date -Format 'HH:mm:ss'
        
        if ($exitCode -le 3) {
            Write-Host "[$timestamp] Completed: $name (Exit Code: $exitCode)" -ForegroundColor Green
        } else {
            Write-Host "[$timestamp] Warning/Error: $name (Exit Code: $exitCode)" -ForegroundColor Yellow
        }
        
        return @{
            Name = $name
            ExitCode = $exitCode
            Timestamp = $timestamp
        }
    }
    
    # Job throttling - wait if we have too many running jobs
    $runningJobs = Get-Job -State "Running"
    while ($runningJobs.Count -ge $max_jobs) {
        Start-Sleep -Milliseconds 250  # Reduced sleep time for better responsiveness
        $runningJobs = Get-Job -State "Running"
        
        # Process completed jobs
        $completedJobs = Get-Job -State "Completed"
        if ($completedJobs.Count -gt 0) {
            $completedJobs | Receive-Job | Out-Null
            $completedJobs | Remove-Job
        }
    }
    
    # Clean up completed jobs before starting new one
    Get-Job -State "Completed" | Receive-Job | Out-Null
    Remove-Job -State "Completed"
      # Start new job
    $newJob = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $_.Name, $src, $dest, $mtreads, $EnableLogging
    $allJobs += $newJob
}

# Wait for all jobs to complete and collect results
Write-Host "Waiting for all jobs to complete..." -ForegroundColor Cyan
$jobResults = @()

# Calculate total expected jobs
$totalExpectedJobs = $directories.Count + $(if($rootFiles.Count -gt 0){1}else{0})
Write-Host "Total jobs to process: $totalExpectedJobs" -ForegroundColor Cyan

While (Get-Job -State "Running") { 
    # Show progress
    $runningJobs = (Get-Job -State "Running").Count
    $completedJobs = (Get-Job -State "Completed").Count
    
    if ($totalExpectedJobs -gt 0) {
        $percentComplete = [math]::Round(($completedJobs / $totalExpectedJobs) * 100, 1)
        Write-Progress -Activity "Processing Robocopy Jobs" -Status "Running: $runningJobs, Completed: $completedJobs of $totalExpectedJobs" -PercentComplete $percentComplete
    }
    
    # Process completed jobs
    $completed = Get-Job -State "Completed"
    if ($completed.Count -gt 0) {
        $jobResults += $completed | Receive-Job
        $completed | Remove-Job
    }
    
    Start-Sleep -Seconds 1
}

# Process any remaining completed jobs
$remaining = Get-Job -State "Completed"
if ($remaining.Count -gt 0) {
    $jobResults += $remaining | Receive-Job
    $remaining | Remove-Job
}

# Clean up any remaining jobs
Get-Job | Remove-Job -Force

# Calculate execution time and display results
$tend = Get-Date 
$duration = New-TimeSpan -Start $tstart -End $tend

Write-Host "`n=== Robocopy Booster V2 - Results ===" -ForegroundColor Cyan
Write-Host "Total Execution Time: $($duration.Hours)h $($duration.Minutes)m $($duration.Seconds)s $($duration.Milliseconds)ms" -ForegroundColor Green
Write-Host "Total Directories Processed: $($directories.Count)" -ForegroundColor White
Write-Host "Root Files Job: $(if($rootFiles.Count -gt 0){"Yes ($($rootFiles.Count) files)"}else{"No"})" -ForegroundColor White
Write-Host "Total Jobs Executed: $totalExpectedJobs" -ForegroundColor White
Write-Host "Logging Mode Used: $(if($EnableLogging){'Normal'}else{'Silent'})" -ForegroundColor $(if($EnableLogging){'Green'}else{'Yellow'})
Write-Host "Max Parallel Jobs: $max_jobs" -ForegroundColor White
Write-Host "Threads per Job: $mtreads" -ForegroundColor White

# Display job results summary
if ($jobResults.Count -gt 0) {
    $successfulJobs = ($jobResults | Where-Object { $_.ExitCode -le 3 }).Count
    $warningJobs = ($jobResults | Where-Object { $_.ExitCode -gt 3 -and $_.ExitCode -lt 8 }).Count
    $errorJobs = ($jobResults | Where-Object { $_.ExitCode -ge 8 }).Count
    
    Write-Host "`nJob Results Summary:" -ForegroundColor Cyan
    Write-Host "  Successful: $successfulJobs" -ForegroundColor Green
    Write-Host "  Warnings: $warningJobs" -ForegroundColor Yellow
    Write-Host "  Errors: $errorJobs" -ForegroundColor Red
}

Write-Host "=====================================" -ForegroundColor Cyan

# A/B Testing recommendation
Write-Host "`nA/B Testing Recommendation:" -ForegroundColor Magenta
Write-Host "To compare performance, run this script twice:" -ForegroundColor White
Write-Host "1. Set `$EnableLogging = `$true (Normal mode)" -ForegroundColor White
Write-Host "2. Set `$EnableLogging = `$false (Silent mode)" -ForegroundColor White
Write-Host "Compare the 'Total Execution Time' to measure performance difference." -ForegroundColor White
