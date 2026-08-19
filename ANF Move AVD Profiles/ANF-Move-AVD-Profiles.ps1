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
- Profiles containing .metadata files are not copied; existing destination profile directories still receive ACL and metadata synchronization.
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

function Assert-DryRunMutationIsBlocked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    if ($DryRun) {
        throw "DRY RUN safety interlock prevented $Operation. -DryRun overrides every operation that can change source or destination files."
    }
}

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

    $providerPrefix = 'Microsoft.PowerShell.Core\FileSystem::'

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Path is not a directory: $Path"
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    }
    else {
        if ($MustExist) {
            throw "Directory does not exist: $Path"
        }

        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    if ($resolvedPath.StartsWith($providerPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolvedPath = $resolvedPath.Substring($providerPrefix.Length)
    }

    return $resolvedPath
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

    Assert-DryRunMutationIsBlocked -Operation "removing failed $Description"
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

    Assert-DryRunMutationIsBlocked -Operation 'restoring a destination backup file'
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

    Assert-DryRunMutationIsBlocked -Operation 'removing a destination backup file'
    Remove-Item -LiteralPath $BackupFilePath -Force
}

function Get-EffectiveDaclSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $acl = Get-Acl -LiteralPath $Path
    return @($acl.Access | ForEach-Object {
        $identity = try {
            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $_.IdentityReference.Value
        }

        '{0}|{1}|{2}|{3}|{4}' -f @(
            $identity,
            [int]$_.FileSystemRights,
            [int]$_.InheritanceFlags,
            [int]$_.PropagationFlags,
            [int]$_.AccessControlType
        )
    } | Sort-Object)
}

function Copy-EffectiveDaclAsExplicit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Assert-DryRunMutationIsBlocked -Operation 'synchronizing destination ACLs'

    $sourceAcl = Get-Acl -LiteralPath $SourcePath
    $destinationAcl = if (Test-Path -LiteralPath $DestinationPath -PathType Container) {
        [System.Security.AccessControl.DirectorySecurity]::new()
    }
    else {
        [System.Security.AccessControl.FileSecurity]::new()
    }

    # Inherited ACEs cannot be copied as inherited ACEs when the destination parent has a different ACL.
    # Protect the destination DACL and materialize the source's effective ACEs as explicit entries instead.
    $destinationAcl.SetAccessRuleProtection($true, $false)
    foreach ($sourceRule in @($sourceAcl.Access)) {
        $explicitRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sourceRule.IdentityReference,
            $sourceRule.FileSystemRights,
            $sourceRule.InheritanceFlags,
            $sourceRule.PropagationFlags,
            $sourceRule.AccessControlType
        )
        [void]$destinationAcl.AddAccessRule($explicitRule)
    }

    $destinationItem = Get-Item -LiteralPath $DestinationPath -Force
    [System.IO.FileSystemAclExtensions]::SetAccessControl($destinationItem, $destinationAcl)

    $sourceSignature = @(Get-EffectiveDaclSignature -Path $SourcePath)
    $destinationSignature = @(Get-EffectiveDaclSignature -Path $DestinationPath)
    $differences = @(Compare-Object -ReferenceObject $sourceSignature -DifferenceObject $destinationSignature)
    if ($differences.Count -gt 0) {
        throw "Destination effective DACL does not match source after ACL synchronization: $DestinationPath"
    }
}

function Copy-FileMetadataFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath
    )

    Assert-DryRunMutationIsBlocked -Operation 'synchronizing destination file metadata'

    $sourceItem = Get-Item -LiteralPath $SourceFilePath -Force
    $destinationItem = Get-Item -LiteralPath $DestinationFilePath -Force
    Copy-EffectiveDaclAsExplicit -SourcePath $SourceFilePath -DestinationPath $DestinationFilePath

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

    Assert-DryRunMutationIsBlocked -Operation 'promoting a staged destination file'

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

    $script:SourceFilesPendingDeletion.Add($SourceFilePath)
    Write-Host "Source cleanup deferred until ACL synchronization completes: $SourceFilePath" -ForegroundColor Gray
}

function Copy-DirectoryMetadataFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectoryPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectoryPath
    )

    Assert-DryRunMutationIsBlocked -Operation 'synchronizing destination directory metadata'

    $sourceItem = Get-Item -LiteralPath $SourceDirectoryPath -Force
    $destinationItem = Get-Item -LiteralPath $DestinationDirectoryPath -Force
    Copy-EffectiveDaclAsExplicit -SourcePath $SourceDirectoryPath -DestinationPath $DestinationDirectoryPath

    $destinationItem.CreationTimeUtc = $sourceItem.CreationTimeUtc
    $destinationItem.LastWriteTimeUtc = $sourceItem.LastWriteTimeUtc
    $destinationItem.LastAccessTimeUtc = $sourceItem.LastAccessTimeUtc
    $destinationItem.Attributes = $sourceItem.Attributes
}

function Sync-ProfilePermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceProfileDirectoryPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRootPath,

        [Parameter()]
        [switch]$DirectoriesOnly,

        [Parameter()]
        [switch]$ExistingDestinationDirectoriesOnly
    )

    $sourceProfileRoot = Get-Item -LiteralPath $SourceProfileDirectoryPath -Force
    $sourceDirectories = @($sourceProfileRoot) + @(Get-ChildItem -LiteralPath $SourceProfileDirectoryPath -Directory -Recurse -Force)

    if ($DryRun) {
        foreach ($sourceDirectory in $sourceDirectories) {
            $relativePath = $sourceDirectory.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
            $destinationDirectoryPath = Join-Path -Path $DestinationRootPath -ChildPath $relativePath
            if ($ExistingDestinationDirectoriesOnly -and -not (Test-Path -LiteralPath $destinationDirectoryPath -PathType Container)) {
                Write-Host "DRY RUN: Would skip ACL-only synchronization because destination directory is missing: $destinationDirectoryPath" -ForegroundColor DarkGray
                $script:Summary.AclDirectoriesSkippedMissingDestination++
                continue
            }

            Write-Host "DRY RUN: Would synchronize ACL and metadata for directory: $destinationDirectoryPath" -ForegroundColor Yellow
            $script:Summary.AclDirectoriesPlanned++
        }

        if ($DirectoriesOnly) {
            return
        }

        $sourceFiles = @(Get-ChildItem -LiteralPath $SourceProfileDirectoryPath -File -Recurse -Force | Where-Object { $_.Extension -ne '.metadata' })
        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
            $destinationFilePath = Join-Path -Path $DestinationRootPath -ChildPath $relativePath
            Write-Host "DRY RUN: Would synchronize ACL and metadata for file: $destinationFilePath" -ForegroundColor Yellow
            $script:Summary.AclFilesPlanned++
        }

        return
    }

    foreach ($sourceDirectory in ($sourceDirectories | Sort-Object { $_.FullName.Length })) {
        $relativePath = $sourceDirectory.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
        $destinationDirectoryPath = Join-Path -Path $DestinationRootPath -ChildPath $relativePath

        try {
            if (-not (Test-Path -LiteralPath $destinationDirectoryPath -PathType Container)) {
                if ($ExistingDestinationDirectoriesOnly) {
                    Write-Host "Skipped ACL-only synchronization because destination directory is missing: $destinationDirectoryPath" -ForegroundColor DarkGray
                    $script:Summary.AclDirectoriesSkippedMissingDestination++
                    continue
                }

                Assert-DryRunMutationIsBlocked -Operation 'creating an empty destination directory'
                New-Item -Path $destinationDirectoryPath -ItemType Directory -Force | Out-Null
                Write-Host "Created empty destination directory: $destinationDirectoryPath" -ForegroundColor Cyan
            }

            Copy-DirectoryMetadataFromSource -SourceDirectoryPath $sourceDirectory.FullName -DestinationDirectoryPath $destinationDirectoryPath
            $script:Summary.AclSyncedDirectories++
        }
        catch {
            Write-Host "ERROR: Failed to synchronize ACL and metadata for directory $destinationDirectoryPath" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            $script:Summary.AclSyncFailures++
        }
    }

    if ($DirectoriesOnly) {
        return
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $SourceProfileDirectoryPath -File -Recurse -Force | Where-Object { $_.Extension -ne '.metadata' })
    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
        $destinationFilePath = Join-Path -Path $DestinationRootPath -ChildPath $relativePath

        if (-not (Test-Path -LiteralPath $destinationFilePath -PathType Leaf)) {
            Write-Host "ERROR: Cannot synchronize ACL; destination file is missing: $destinationFilePath" -ForegroundColor Red
            $script:Summary.AclMissingDestinationFiles++
            continue
        }

        if (-not (Test-VerifiedCopy -SourceFilePath $sourceFile.FullName -DestinationFilePath $destinationFilePath)) {
            Write-Host "WARNING: Skipped ACL synchronization because source and destination content differ: $destinationFilePath" -ForegroundColor Yellow
            $script:Summary.AclFilesSkippedContentMismatch++
            continue
        }

        try {
            Copy-FileMetadataFromSource -SourceFilePath $sourceFile.FullName -DestinationFilePath $destinationFilePath
            $script:Summary.AclSyncedFiles++
        }
        catch {
            Write-Host "ERROR: Failed to synchronize ACL and metadata for file $destinationFilePath" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            $script:Summary.AclSyncFailures++
        }
    }
}

function Sync-RootDirectoryPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRootPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRootPath
    )

    if ($DryRun) {
        Write-Host "DRY RUN: Would synchronize ACL and metadata for root directory: $DestinationRootPath" -ForegroundColor Yellow
        $script:Summary.AclDirectoriesPlanned++
        return
    }

    try {
        Copy-DirectoryMetadataFromSource -SourceDirectoryPath $SourceRootPath -DestinationDirectoryPath $DestinationRootPath
        $script:Summary.AclSyncedDirectories++
    }
    catch {
        Write-Host "ERROR: Failed to synchronize ACL and metadata for root directory $DestinationRootPath" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $script:Summary.AclSyncFailures++
    }
}

function Complete-SourceCleanupAfterAclSync {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.IO.DirectoryInfo[]]$SourceProfileDirectories
    )

    if (-not $DeleteSourceAfterVerifiedCopy -or $DryRun) {
        return
    }

    Assert-DryRunMutationIsBlocked -Operation 'deleting verified source files'

    if ($script:Summary.AclSyncFailures -gt 0 -or $script:Summary.AclMissingDestinationFiles -gt 0) {
        Write-Warning 'Source cleanup was skipped because ACL synchronization did not complete successfully.'
        return
    }

    foreach ($sourceFilePath in $script:SourceFilesPendingDeletion) {
        if (-not (Test-Path -LiteralPath $sourceFilePath -PathType Leaf)) {
            continue
        }

        $relativePath = $sourceFilePath.Substring($resolvedSource.Length).TrimStart([char[]]@('\', '/'))
        $destinationFilePath = Join-Path -Path $resolvedDestination -ChildPath $relativePath
        if (Test-VerifiedCopy -SourceFilePath $sourceFilePath -DestinationFilePath $destinationFilePath) {
            Remove-Item -LiteralPath $sourceFilePath -Force
            Write-Host "Deleted verified source file after ACL synchronization: $sourceFilePath" -ForegroundColor Yellow
        }
        else {
            Write-Warning "Source file changed or destination no longer validates; source retained: $sourceFilePath"
        }
    }

    foreach ($sourceDirectory in $SourceProfileDirectories) {
        if (-not (Test-Path -LiteralPath $sourceDirectory.FullName -PathType Container)) {
            continue
        }

        $remainingItems = @(Get-ChildItem -LiteralPath $sourceDirectory.FullName -Recurse -Force)
        if ($remainingItems.Count -eq 0) {
            Remove-Item -LiteralPath $sourceDirectory.FullName -Force
            Write-Host "Deleted empty source directory: $($sourceDirectory.FullName)" -ForegroundColor Yellow
        }
        else {
            Write-Host "Directory not empty, keeping: $($sourceDirectory.FullName)" -ForegroundColor Gray
            Write-Host "  Remaining items: $($remainingItems.Count)" -ForegroundColor Gray
        }
    }
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
            Assert-DryRunMutationIsBlocked -Operation 'creating a destination directory'
            New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
            Write-Host "Created destination directory: $destinationDirectory" -ForegroundColor Cyan
        }
    }

    if ($DryRun) {
        Write-Host "DRY RUN: Would $ActionLabel '$($SourceFile.FullName)' to '$DestinationFilePath'" -ForegroundColor Yellow
        $script:Summary.PlannedCopies++
        return
    }

    Assert-DryRunMutationIsBlocked -Operation 'copying a profile file'

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
    Assert-DryRunMutationIsBlocked -Operation 'creating the destination root directory'
    New-Item -Path $resolvedDestination -ItemType Directory -Force | Out-Null
}

Write-Host '=== ANF Move AVD Profiles - Configuration ===' -ForegroundColor Cyan
Write-Host "Source Path: $resolvedSource" -ForegroundColor White
Write-Host "Destination Path: $resolvedDestination" -ForegroundColor White
Write-Host "Filter String: $(if ([string]::IsNullOrWhiteSpace($FilterString)) { '<none>' } else { $FilterString })" -ForegroundColor White
Write-Host "Delete Source After Verified Copy: $($DeleteSourceAfterVerifiedCopy.IsPresent)$(if ($DryRun -and $DeleteSourceAfterVerifiedCopy) { ' (ignored by DryRun)' })" -ForegroundColor White
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
    AclDirectoriesPlanned = 0
    AclDirectoriesSkippedMissingDestination = 0
    AclFilesPlanned = 0
    AclSyncedDirectories = 0
    AclSyncedFiles = 0
    AclFilesSkippedContentMismatch = 0
    AclMissingDestinationFiles = 0
    AclSyncFailures = 0
}

$script:SourceFilesPendingDeletion = [System.Collections.Generic.List[string]]::new()
$processedProfileDirectories = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
$inUseProfileDirectories = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
$directories = @(Get-ChildItem -LiteralPath $resolvedSource -Directory -Force)

foreach ($directory in $directories) {
    if (-not [string]::IsNullOrWhiteSpace($FilterString) -and $directory.Name -notlike "*$FilterString*") {
        Write-Host "Skipped directory (does not match filter): $($directory.FullName)" -ForegroundColor Gray
        $script:Summary.DirectoriesSkippedByFilter++
        continue
    }

    $metadataFiles = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -File -Force | Where-Object { $_.Extension -eq '.metadata' })
    if ($metadataFiles.Count -gt 0) {
        Write-Host "Skipped directory (profile in use or metadata present): $($directory.FullName)" -ForegroundColor DarkGray
        $script:Summary.DirectoriesSkippedInUse++
        $inUseProfileDirectories.Add($directory)
        continue
    }

    $script:Summary.DirectoriesProcessed++
    $processedProfileDirectories.Add($directory)
    $sourceFiles = @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force | Where-Object { $_.Extension -ne '.metadata' })

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

}

foreach ($directory in $processedProfileDirectories) {
    Sync-ProfilePermissions -SourceProfileDirectoryPath $directory.FullName -DestinationRootPath $resolvedDestination
}

foreach ($directory in $inUseProfileDirectories) {
    Write-Host "Synchronizing directory ACLs only for in-use profile; profile content remains untouched: $($directory.FullName)" -ForegroundColor DarkGray
    Sync-ProfilePermissions -SourceProfileDirectoryPath $directory.FullName -DestinationRootPath $resolvedDestination -DirectoriesOnly -ExistingDestinationDirectoriesOnly
}

Sync-RootDirectoryPermissions -SourceRootPath $resolvedSource -DestinationRootPath $resolvedDestination

Complete-SourceCleanupAfterAclSync -SourceProfileDirectories $processedProfileDirectories.ToArray()

Write-Host ''
Write-Host '=== ANF Move AVD Profiles - Summary ===' -ForegroundColor Cyan
foreach ($key in $script:Summary.Keys) {
    Write-Host "$key`: $($script:Summary[$key])" -ForegroundColor White
}
Write-Host '=======================================' -ForegroundColor Cyan

if ($script:Summary.CopyFailures -gt 0 -or $script:Summary.ValidationFailures -gt 0 -or $script:Summary.MetadataFailures -gt 0 -or $script:Summary.RestoreFailures -gt 0 -or $script:Summary.AclSyncFailures -gt 0 -or $script:Summary.AclMissingDestinationFiles -gt 0 -or $script:Summary.ConflictFiles -gt 0) {
    exit 1
}

exit 0
