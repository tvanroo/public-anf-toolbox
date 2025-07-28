<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************

Last Edit Date: 12/26/2024
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
1. This script copies and then deletes the contents of a source directory to a destination directory using BITS and is tuned for FSLogix Profile data and moving from an old SMB path to an Azure NetApp Files (ANF) SMB share. 
2. The script compares the creation and modified dates of files in the source and destination. 
    - If the source file is more recently modified, it will overwrite the destination file. (don't overwrite a real profile with a recently created empty profile file)
    - If the source file is more recently created, it will not overwrite the destination file. (Don't overwrite a real profile with an older version of the same profile)
3. To skip syncing profiles that are in use, the script will check for a .metadata file in the source directory or any subdirectory.

This is the final Cutover script for an FSLogix SMB path move. 
It should be used when both the old and new paths are in the FSLogix Profile container setting. (ususally with the old Path in the primary position)
Then for profile(s) that are not in use to be copied form the old SMB to the new SMB and the source data removed. 
This will cause any moved profiles to start being used from the new SMB path.
Profiles that are currently in use and profiles with conflicting metadata are skipped. 

#>

# Define source and destination paths
$SourcePath = "\\xyz.file.core.windows.net\xyz"
$DestinationPath = "\\ANF-xyz.abc.gov\xyz-prod-001-anf-vol1-profiles"
$FilterString = "Ssdfgsdfhsdfh"  # Replace with your filter string

# Get all top-level directories in the source path
$Directories = Get-ChildItem -Path $SourcePath -Directory



# Loop through each directory in the source path
foreach ($Directory in $Directories) {
    # Debugging: Output the directory name and filter string
    #Write-Host "Checking Directory: $($Directory.Name)" -ForegroundColor Gray

    # Check if the directory name matches the filter string
    if ($null -eq $FilterString -or $Directory.Name -like "*$FilterString*") {
        # Check if the directory or any subdirectory contains a .metadata file
        $MetadataFile = Get-ChildItem -Path $Directory.FullName -Recurse -File | Where-Object { $_.Extension -eq ".metadata" }
        if ($MetadataFile) {
            Write-Host "Skipped directory (Profile in use and contains .metadata file): $($Directory.FullName)" -ForegroundColor DarkGray
            continue
        }

        # Get all files in the current directory recursively, excluding .metadata files
        $SourceFiles = Get-ChildItem -Path $Directory.FullName -File -Recurse | Where-Object { $_.Extension -ne ".metadata" }

        # Loop through each file in the source directory
        foreach ($SourceFile in $SourceFiles) {
            # Define the corresponding destination file path
            $DestinationFilePath = $SourceFile.FullName -replace [regex]::Escape($SourcePath), $DestinationPath

            # Check if the destination file exists
            if (Test-Path $DestinationFilePath) {
                # Get the destination file object
                $DestinationFile = Get-Item -Path $DestinationFilePath

                # Compare creation and modified dates
                if ($SourceFile.CreationTime -eq $DestinationFile.CreationTime) {
                    if ($SourceFile.LastWriteTime -gt $DestinationFile.LastWriteTime) {
                        # Measure the time taken for the transfer
                        $startTime = Get-Date
                        ############################
                        #Start-BitsTransfer -Source $SourceFile.FullName -Destination $DestinationFilePath -DisplayName "File Transfer"
                        $endTime = Get-Date

                        # Calculate the transfer speed
                        $duration = ($endTime - $startTime).TotalSeconds
                        $fileSize = (Get-Item $SourceFile.FullName).Length / 1MB
                        $speed = $fileSize / $duration

                        Write-Host ("Updated: $DestinationFilePath at {0:N2} MiB/s" -f $speed) -ForegroundColor Green

                        # Remove the source file after successful transfer
                        ############################
                        #Remove-Item -Path $SourceFile.FullName -Force
                        Write-Host "Deleted: $(Join-Path -Path $SourceFile.Directory.FullName -ChildPath $SourceFile.Name)" -ForegroundColor Yellow
                    } else {
                        Write-Host "Skipped (destination file modified date is -ge the source.): $DestinationFilePath" -ForegroundColor White

                        # Remove the source file if it matches the destination
                        ###############################
                        #Remove-Item -Path $SourceFile.FullName -Force
                        Write-Host "Deleted: $(Join-Path -Path $SourceFile.Directory.FullName -ChildPath $SourceFile.Name)" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "Skipped (creation dates differ, new empty profile likely created, resolve manually.): $DestinationFilePath" -ForegroundColor Yellow
                }
            } else {
                # Measure the time taken for the transfer
                $startTime = Get-Date
                ############################
                #Start-BitsTransfer -Source $SourceFile.FullName -Destination $DestinationFilePath -DisplayName "File Transfer"
                $endTime = Get-Date

                # Calculate the transfer speed
                $duration = ($endTime - $startTime).TotalSeconds
                $fileSize = (Get-Item $SourceFile.FullName).Length / 1MB
                $speed = $fileSize / $duration

                Write-Host ("Copied new file: $DestinationFilePath at {0:N2} MiB/s" -f $speed) -ForegroundColor Green

                # Remove the source file after successful transfer
                ############################
                #Remove-Item -Path $SourceFile.FullName -Force
                Write-Host "Deleted: $(Join-Path -Path $SourceFile.Directory.FullName -ChildPath $SourceFile.Name)" -ForegroundColor Yellow
            }
        }

        # Remove the source directory if it is empty
        if (-not (Get-ChildItem -Path $Directory.FullName -Recurse)) {
            ############################
            #Remove-Item -Path $Directory.FullName -Force
            Write-Host "Deleted: $($Directory.FullName)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Skipped directory (does not match filter): $($Directory.FullName)" -ForegroundColor Gray
    }
}
