<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************


Last Edit Date: 10/24/2024
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script runs parallel robocopy commands as PowerShell Jobs to speed up tiny file migrations. 
The variables you can control are: the maximum number of jobs and the /mt threads used in the command. 
The script will throttle the number of concurrent jobs based on $max_jobs. 
Simply change $src to get the list of folders to backup and the list is used to feed $ScriptBlock. 

Parameters: 
$max_jobs: The maximum number of parallel jobs to run.
$mtreads Change this to the number of threads to use for each robocopy job
$src Change this to a directory which has lots of subdirectories that can be processed in parallel 
$dest Change this to where you want to backup your files to $max_jobs Change this to the number of parallel jobs to run ( <= 8 ) 

Test results from a small smaple size test. 100x 1k files, transfered over 1Gbps network:

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

#>


# User Editable Variables:
$max_jobs = 16          # Change this to the number of parallel Robocopy jobs to run 
$mtreads = 16           # Change this to the number of threads to use for each robocopy job (used with the /mt switch)
$src = "Z:\txtest"      # Set $src to a the local folder or share from which you want to copy the data
$dest = "C:\txtest"     # Set $dest to a local folder or share to which you want to copy the data

# Script:
$tstart = get-date 
$files = ls $src 
$files | %{
    $ScriptBlock = {
        param($name, $src, $dest)
        # Remove the final character from $name if it is a backslash
        if ($name.EndsWith("\")) {
            $name = $name.Substring(0, $name.Length - 1)
        }
        $srcPath = Join-Path -Path $src -ChildPath $name
        $destPath = Join-Path -Path $dest -ChildPath $name
        write-host "name $name"
        write-host "src $src"
        write-host "srcpath $srcPath"
        write-host "destpath $destPath"
        robocopy $src $dest $name /E /nfl /XO /np /mt:$mtreads /ndl
        Write-Host $srcPath " completed"
    }
    $j = Get-Job -State "Running"
    while ($j.count -ge $max_jobs) {
        Start-Sleep -Milliseconds 500
        $j = Get-Job -State "Running"
    }
    Get-job -State "Completed" | Receive-job
    Remove-job -State "Completed"
    Start-Job $ScriptBlock -ArgumentList $_.Name, $src, $dest
}
# 
# No more jobs to process. Wait for all of them to complete 
# 
While (Get-Job -State "Running") { Start-Sleep 2 } 
Remove-Job -State "Completed" 
Get-Job | Write-host 

$tend = get-date 

new-timespan -start $tstart -end $tend