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
This script copies FSLogix profile data from an old SMB path to a new SMB path, using BITS and post-copy validation.
By default it is a non-destructive copy/update tool: source files and source directories are preserved.

To use it as a final cutover move tool, pass -DeleteSourceAfterVerifiedCopy. Source files are deleted only after
the matching destination file validates by SHA256 hash and file size. Source directories are removed only when
that cutover mode is enabled and the directory is truly empty.

Reruns:
- Profiles containing .metadata files are skipped.
- New files are copied and validated.
- Source files newer than matching destination files are copied and validated.
- Identical already-copied source files are left in place unless -DeleteSourceAfterVerifiedCopy is used.
- Destination files with conflicting creation times are skipped for manual review.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [Parameter()]
    [AllowNull()]
    [string]$FilterString = $null,

    [Parameter()]
    [switch]$DeleteSourceAfterVerifiedCopy,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$KeepFailedDestinationFiles
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-AvdMigrationRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RequireBits
    )

    $isWindowsHost = $true
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        $isWindowsHost = [bool]$isWindowsVariable.Value
    }
    elseif ($PSVersionTable.PSEdition -eq 'Core') {
        $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    }

    if (-not $isWindowsHost) {
        if ($RequireBits) {
            throw 'Live copy mode requires a Windows VM or Windows host with access to both SMB shares.'
        }

        Write-Warning 'Dry run is running on a non-Windows host. Live copy mode requires a Windows VM or Windows host with BITS and access to both SMB shares.'
    }

    if ($RequireBits -and -not (Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        throw 'Live copy mode requires the Start-BitsTransfer cmdlet. Run from a Windows VM or Windows host where BITS is available.'
    }
}

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

function Test-VerifiedCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath
    )

    if (-not (Test-Path -LiteralPath $SourceFilePath -PathType Leaf) -or -not (Test-Path -LiteralPath $DestinationFilePath -PathType Leaf)) {
        return $false
    }

    $sourceHash = Get-FileHash -LiteralPath $SourceFilePath -Algorithm SHA256
    $destinationHash = Get-FileHash -LiteralPath $DestinationFilePath -Algorithm SHA256
    $sourceSize = (Get-Item -LiteralPath $SourceFilePath).Length
    $destinationSize = (Get-Item -LiteralPath $DestinationFilePath).Length

    return ($sourceHash.Hash -eq $destinationHash.Hash -and $sourceSize -eq $destinationSize)
}

function New-StagedDestinationFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath,

        [Parameter()]
        [string]$Purpose = 'copy'
    )

    $destinationDirectory = Split-Path -Path $DestinationFilePath -Parent
    $destinationFileName = Split-Path -Path $DestinationFilePath -Leaf
    $safePurpose = $Purpose -replace '[^A-Za-z0-9-]', '-'
    $uniqueSuffix = [guid]::NewGuid().ToString('N')

    return (Join-Path -Path $destinationDirectory -ChildPath ".$destinationFileName.anfmove-$safePurpose-$uniqueSuffix.tmp")
}

function Remove-FailedCopyArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return
    }

    if ($KeepFailedDestinationFiles) {
        Write-Host "Keeping failed $Description for inspection: $FilePath" -ForegroundColor Yellow
        return
    }

    if ($DryRun) {
        Write-Host "DRY RUN: Would remove failed $Description`: $FilePath" -ForegroundColor Red
        return
    }

    Remove-Item -LiteralPath $FilePath -Force
    Write-Host "Removed failed $Description`: $FilePath" -ForegroundColor Red
}

function Restore-BackupFileIfPresent {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$BackupFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath
    )

    if ([string]::IsNullOrWhiteSpace($BackupFilePath) -or -not (Test-Path -LiteralPath $BackupFilePath -PathType Leaf)) {
        return
    }

    Move-Item -LiteralPath $BackupFilePath -Destination $DestinationFilePath -Force
    Write-Host "Restored previous destination file after failed replacement: $DestinationFilePath" -ForegroundColor Yellow
}

function Remove-BackupFileIfPresent {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$BackupFilePath
    )

    if ([string]::IsNullOrWhiteSpace($BackupFilePath) -or -not (Test-Path -LiteralPath $BackupFilePath -PathType Leaf)) {
        return
    }

    Remove-Item -LiteralPath $BackupFilePath -Force
}

function Copy-FileMetadataFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath
    )

    $sourceItem = Get-Item -LiteralPath $SourceFilePath -Force
    $destinationItem = Get-Item -LiteralPath $DestinationFilePath -Force
    $sourceAcl = Get-Acl -LiteralPath $SourceFilePath

    Set-Acl -LiteralPath $DestinationFilePath -AclObject $sourceAcl

    $destinationItem.CreationTimeUtc = $sourceItem.CreationTimeUtc
    $destinationItem.LastWriteTimeUtc = $sourceItem.LastWriteTimeUtc
    $destinationItem.LastAccessTimeUtc = $sourceItem.LastAccessTimeUtc
    $destinationItem.Attributes = $sourceItem.Attributes
}

function Move-StagedFileIntoPlace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagedDestinationFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath
    )

    if (Test-Path -LiteralPath $DestinationFilePath -PathType Leaf) {
        $backupFilePath = New-StagedDestinationFilePath -DestinationFilePath $DestinationFilePath -Purpose 'backup'
        [System.IO.File]::Replace($StagedDestinationFilePath, $DestinationFilePath, $backupFilePath, $true)
        return $backupFilePath
    }

    Move-Item -LiteralPath $StagedDestinationFilePath -Destination $DestinationFilePath -Force
    return $null
}

function Remove-SourceFileIfRequested {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFilePath
    )

    if (-not $DeleteSourceAfterVerifiedCopy) {
        Write-Host "Source retained: $SourceFilePath" -ForegroundColor Gray
        return
    }

    if ($DryRun) {
        Write-Host "DRY RUN: Would delete verified source file: $SourceFilePath" -ForegroundColor Yellow
        return
    }

    Remove-Item -LiteralPath $SourceFilePath -Force
    Write-Host "Deleted verified source file: $SourceFilePath" -ForegroundColor Yellow
}

function Copy-ProfileFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath,

        [Parameter(Mandatory = $true)]
        [string]$ActionLabel
    )

    $destinationDirectory = Split-Path -Path $DestinationFilePath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        if ($DryRun) {
            Write-Host "DRY RUN: Would create destination directory: $destinationDirectory" -ForegroundColor Cyan
        }
        else {
            New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
            Write-Host "Created destination directory: $destinationDirectory" -ForegroundColor Cyan
        }
    }

    if ($DryRun) {
        Write-Host "DRY RUN: Would $ActionLabel '$($SourceFile.FullName)' to '$DestinationFilePath'" -ForegroundColor Yellow
        $script:Summary.PlannedCopies++
        return
    }

    $stagedDestinationFilePath = New-StagedDestinationFilePath -DestinationFilePath $DestinationFilePath
    $backupFilePath = $null
    $startTime = Get-Date
    try {
        Start-BitsTransfer -Source $SourceFile.FullName -Destination $stagedDestinationFilePath -DisplayName "FSLogix Profile File Transfer" -ErrorAction Stop

        if (-not (Test-VerifiedCopy -SourceFilePath $SourceFile.FullName -DestinationFilePath $stagedDestinationFilePath)) {
            Write-Host "ERROR: Staged copy validation failed for $DestinationFilePath - source retained" -ForegroundColor Red
            $script:Summary.ValidationFailures++
            Remove-FailedCopyArtifact -FilePath $stagedDestinationFilePath -Description 'staged copy'
            return
        }

        $backupFilePath = Move-StagedFileIntoPlace -StagedDestinationFilePath $stagedDestinationFilePath -DestinationFilePath $DestinationFilePath
        $endTime = Get-Date

        try {
            Copy-FileMetadataFromSource -SourceFilePath $SourceFile.FullName -DestinationFilePath $DestinationFilePath
        }
        catch {
            Write-Host "ERROR: Failed to copy metadata to destination file for $DestinationFilePath - source retained" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            $script:Summary.MetadataFailures++
            try {
                Restore-BackupFileIfPresent -BackupFilePath $backupFilePath -DestinationFilePath $DestinationFilePath
            }
            catch {
                Write-Host "ERROR: Failed to restore previous destination file: $($_.Exception.Message)" -ForegroundColor Red
                $script:Summary.RestoreFailures++
            }

            if ([string]::IsNullOrWhiteSpace($backupFilePath)) {
                Remove-FailedCopyArtifact -FilePath $DestinationFilePath -Description 'new destination file'
            }

            return
        }

        if (-not (Test-VerifiedCopy -SourceFilePath $SourceFile.FullName -DestinationFilePath $DestinationFilePath)) {
            Write-Host "ERROR: Final copy validation failed for $DestinationFilePath - source retained" -ForegroundColor Red
            $script:Summary.ValidationFailures++
            try {
                Restore-BackupFileIfPresent -BackupFilePath $backupFilePath -DestinationFilePath $DestinationFilePath
            }
            catch {
                Write-Host "ERROR: Failed to restore previous destination file: $($_.Exception.Message)" -ForegroundColor Red
                $script:Summary.RestoreFailures++
            }

            if ([string]::IsNullOrWhiteSpace($backupFilePath)) {
                Remove-FailedCopyArtifact -FilePath $DestinationFilePath -Description 'new destination file'
            }

            return
        }

        Remove-BackupFileIfPresent -BackupFilePath $backupFilePath

        $duration = ($endTime - $startTime).TotalSeconds
        $fileSizeMiB = $SourceFile.Length / 1MB
        $speed = if ($duration -gt 0) { $fileSizeMiB / $duration } else { 0 }

        Write-Host ("$ActionLabel validated: $DestinationFilePath at {0:N2} MiB/s" -f $speed) -ForegroundColor Green
        $script:Summary.CopiedFiles++
        Remove-SourceFileIfRequested -SourceFilePath $SourceFile.FullName
    }
    catch {
        Write-Host "ERROR: Failed to copy $($SourceFile.FullName) to $DestinationFilePath - source retained" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $script:Summary.CopyFailures++
        try {
            Restore-BackupFileIfPresent -BackupFilePath $backupFilePath -DestinationFilePath $DestinationFilePath
        }
        catch {
            Write-Host "ERROR: Failed to restore previous destination file: $($_.Exception.Message)" -ForegroundColor Red
            $script:Summary.RestoreFailures++
        }

        Remove-FailedCopyArtifact -FilePath $stagedDestinationFilePath -Description 'staged copy'
    }
}

Assert-AvdMigrationRuntime -RequireBits:(-not $DryRun)

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
    New-Item -Path $resolvedDestination -ItemType Directory -Force | Out-Null
}

Write-Host '=== ANF Move AVD Profiles - Configuration ===' -ForegroundColor Cyan
Write-Host "Source Path: $resolvedSource" -ForegroundColor White
Write-Host "Destination Path: $resolvedDestination" -ForegroundColor White
Write-Host "Filter String: $(if ([string]::IsNullOrWhiteSpace($FilterString)) { '<none>' } else { $FilterString })" -ForegroundColor White
Write-Host "Delete Source After Verified Copy: $($DeleteSourceAfterVerifiedCopy.IsPresent)" -ForegroundColor White
Write-Host "Dry Run: $($DryRun.IsPresent)" -ForegroundColor White
Write-Host 'Default mode is copy/update only; source files are preserved.' -ForegroundColor Green
Write-Host '=============================================' -ForegroundColor Cyan

$script:Summary = [ordered]@{
    DirectoriesProcessed = 0
    DirectoriesSkippedByFilter = 0
    DirectoriesSkippedInUse = 0
    PlannedCopies = 0
    CopiedFiles = 0
    IdenticalFiles = 0
    ConflictFiles = 0
    CopyFailures = 0
    ValidationFailures = 0
    MetadataFailures = 0
    RestoreFailures = 0
}

$directories = @(Get-ChildItem -LiteralPath $resolvedSource -Directory)

foreach ($directory in $directories) {
    if (-not [string]::IsNullOrWhiteSpace($FilterString) -and $directory.Name -notlike "*$FilterString*") {
        Write-Host "Skipped directory (does not match filter): $($directory.FullName)" -ForegroundColor Gray
        $script:Summary.DirectoriesSkippedByFilter++
        continue
    }

    $metadataFiles = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -File | Where-Object { $_.Extension -eq '.metadata' })
    if ($metadataFiles.Count -gt 0) {
        Write-Host "Skipped directory (profile in use or metadata present): $($directory.FullName)" -ForegroundColor DarkGray
        $script:Summary.DirectoriesSkippedInUse++
        continue
    }

    $script:Summary.DirectoriesProcessed++
    $sourceFiles = @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse | Where-Object { $_.Extension -ne '.metadata' })

    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
        $destinationFilePath = Join-Path -Path $resolvedDestination -ChildPath $relativePath

        if (Test-Path -LiteralPath $destinationFilePath -PathType Leaf) {
            $destinationFile = Get-Item -LiteralPath $destinationFilePath

            if ($sourceFile.CreationTime -eq $destinationFile.CreationTime) {
                if ($sourceFile.LastWriteTime -gt $destinationFile.LastWriteTime) {
                    Copy-ProfileFile -SourceFile $sourceFile -DestinationFilePath $destinationFilePath -ActionLabel 'Updated'
                }
                elseif (Test-VerifiedCopy -SourceFilePath $sourceFile.FullName -DestinationFilePath $destinationFilePath) {
                    Write-Host "Identical already copied file: $destinationFilePath" -ForegroundColor White
                    $script:Summary.IdenticalFiles++
                    Remove-SourceFileIfRequested -SourceFilePath $sourceFile.FullName
                }
                else {
                    Write-Host "WARNING: Destination is not older, but files differ - source retained: $($sourceFile.FullName)" -ForegroundColor Red
                    $script:Summary.ConflictFiles++
                }
            }
            else {
                Write-Host "Skipped conflict (creation dates differ, resolve manually): $destinationFilePath" -ForegroundColor Yellow
                $script:Summary.ConflictFiles++
            }
        }
        else {
            Copy-ProfileFile -SourceFile $sourceFile -DestinationFilePath $destinationFilePath -ActionLabel 'Copied new file'
        }
    }

    if ($DeleteSourceAfterVerifiedCopy) {
        try {
            $remainingItems = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force)
            if ($remainingItems.Count -eq 0) {
                if ($DryRun) {
                    Write-Host "DRY RUN: Would delete empty source directory: $($directory.FullName)" -ForegroundColor Yellow
                }
                else {
                    Remove-Item -LiteralPath $directory.FullName -Force
                    Write-Host "Deleted empty source directory: $($directory.FullName)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Directory not empty, keeping: $($directory.FullName)" -ForegroundColor Gray
                Write-Host "  Remaining items: $($remainingItems.Count)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "WARNING: Could not inspect or remove directory $($directory.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host '=== ANF Move AVD Profiles - Summary ===' -ForegroundColor Cyan
foreach ($key in $script:Summary.Keys) {
    Write-Host "$key`: $($script:Summary[$key])" -ForegroundColor White
}
Write-Host '=======================================' -ForegroundColor Cyan

if ($script:Summary.CopyFailures -gt 0 -or $script:Summary.ValidationFailures -gt 0 -or $script:Summary.MetadataFailures -gt 0 -or $script:Summary.RestoreFailures -gt 0 -or $script:Summary.ConflictFiles -gt 0) {
    exit 1
}

exit 0
