#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'ANF Move AVD Profiles/ANF-Move-AVD-Profiles.ps1'
$readmePath = Join-Path $repoRoot 'ANF Move AVD Profiles/README.md'

$scriptText = Get-Content -LiteralPath $scriptPath -Raw
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

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "PowerShell parser found errors in ANF-Move-AVD-Profiles.ps1: $($parseErrors.Message -join '; ')"
}

Assert-Contains -Haystack $scriptText -Needle '[Parameter(Mandatory = $true)]' -Message 'Expected source and destination paths to be explicit inputs, not placeholder defaults.'
Assert-NotContains -Haystack $scriptText -Needle '\\xyz.file.core.windows.net\xyz' -Message 'Expected placeholder source path default to be removed.'
Assert-NotContains -Haystack $scriptText -Needle 'Ssdfgsdfhsdfh' -Message 'Expected placeholder filter default to be removed.'

Assert-Contains -Haystack $scriptText -Needle 'function Assert-AvdMigrationRuntime' -Message 'Expected live-run Windows/BITS preflight.'
Assert-Contains -Haystack $scriptText -Needle 'Get-Command -Name Start-BitsTransfer' -Message 'Expected explicit BITS availability check.'
Assert-Contains -Haystack $scriptText -Needle 'Assert-AvdMigrationRuntime -RequireBits:(-not $DryRun)' -Message 'Expected live runs to require BITS while allowing dry-run planning.'
Assert-Contains -Haystack $scriptText -Needle 'function Assert-DryRunMutationIsBlocked' -Message 'Expected a fail-closed dry-run mutation safety interlock.'
Assert-Contains -Haystack $scriptText -Needle 'Assert-DryRunMutationIsBlocked -Operation' -Message 'Expected every write path to be protected by the dry-run safety interlock.'

Assert-Contains -Haystack $scriptText -Needle 'function New-StagedDestinationFilePath' -Message 'Expected staged copy path helper.'
Assert-Contains -Haystack $scriptText -Needle '$stagedDestinationFilePath = New-StagedDestinationFilePath -DestinationFilePath $DestinationFilePath' -Message 'Expected copies to target a staged file before replacing destination.'
Assert-Contains -Haystack $scriptText -Needle 'Start-BitsTransfer -Source $SourceFile.FullName -Destination $stagedDestinationFilePath' -Message 'Expected BITS transfer to write to staged file, not directly over destination.'
Assert-Contains -Haystack $scriptText -Needle 'function Move-StagedFileIntoPlace' -Message 'Expected staged file promotion helper.'
Assert-Contains -Haystack $scriptText -Needle 'Restore-BackupFileIfPresent' -Message 'Expected backup restore path for failed replacement validation.'
Assert-NotContains -Haystack $scriptText -Needle 'Remove-DestinationFileIfFailed -DestinationFilePath $DestinationFilePath' -Message 'Expected failures not to delete an existing destination file.'

Assert-Contains -Haystack $scriptText -Needle 'function Copy-FileMetadataFromSource' -Message 'Expected metadata preservation helper.'
Assert-Contains -Haystack $scriptText -Needle 'CreationTimeUtc' -Message 'Expected creation timestamp preservation.'
Assert-Contains -Haystack $scriptText -Needle 'LastWriteTimeUtc' -Message 'Expected last-write timestamp preservation.'
Assert-Contains -Haystack $scriptText -Needle 'Get-Acl -LiteralPath $SourcePath' -Message 'Expected source ACL capture.'
Assert-Contains -Haystack $scriptText -Needle '[System.IO.FileSystemAclExtensions]::SetAccessControl' -Message 'Expected access-only destination ACL application.'
Assert-Contains -Haystack $scriptText -Needle 'MetadataFailures' -Message 'Expected metadata copy failures to be summarized and fail the run.'
Assert-Contains -Haystack $scriptText -Needle 'function Copy-EffectiveDaclAsExplicit' -Message 'Expected inherited source ACLs to be materialized as explicit destination ACEs.'
Assert-Contains -Haystack $scriptText -Needle 'SetAccessRuleProtection($true, $false)' -Message 'Expected unrelated destination inheritance to be removed.'
Assert-Contains -Haystack $scriptText -Needle 'function Get-EffectiveDaclSignature' -Message 'Expected effective ACL verification after writing.'
Assert-Contains -Haystack $scriptText -Needle 'function Copy-DirectoryMetadataFromSource' -Message 'Expected source directory ACL and metadata synchronization.'
Assert-Contains -Haystack $scriptText -Needle 'function Sync-ProfilePermissions' -Message 'Expected post-copy ACL bootstrap for existing profile items.'
Assert-Contains -Haystack $scriptText -Needle '[switch]$DirectoriesOnly' -Message 'Expected ACL-only synchronization mode for profiles whose content copy is skipped.'
Assert-Contains -Haystack $scriptText -Needle '[switch]$ExistingDestinationDirectoriesOnly' -Message 'Expected in-use profile ACL synchronization not to create a missing destination directory.'
Assert-Contains -Haystack $scriptText -Needle 'Sync-ProfilePermissions -SourceProfileDirectoryPath $directory.FullName -DestinationRootPath $resolvedDestination -DirectoriesOnly -ExistingDestinationDirectoriesOnly' -Message 'Expected in-use profiles to receive ACL-only synchronization.'
Assert-Contains -Haystack $scriptText -Needle 'function Sync-RootDirectoryPermissions' -Message 'Expected source-root ACL synchronization.'
Assert-Contains -Haystack $scriptText -Needle 'AclSyncedDirectories' -Message 'Expected directory ACL synchronization summary.'
Assert-Contains -Haystack $scriptText -Needle 'AclSyncedFiles' -Message 'Expected file ACL bootstrap summary.'
Assert-Contains -Haystack $scriptText -Needle 'AclDirectoriesPlanned' -Message 'Expected ACL dry-run planning without writes.'
Assert-Contains -Haystack $scriptText -Needle 'AclSyncFailures' -Message 'Expected ACL synchronization failures to fail the run.'
Assert-Contains -Haystack $scriptText -Needle 'Complete-SourceCleanupAfterAclSync' -Message 'Expected source cleanup to wait for ACL synchronization.'
Assert-Contains -Haystack $scriptText -Needle '[AllowEmptyCollection()]' -Message 'Expected an all-in-use profile run to complete without cleanup binding failures.'

Assert-Contains -Haystack $readmeText -Needle 'Windows VM' -Message 'Expected README to document that this is a Windows VM-side migration script.'
Assert-Contains -Haystack $readmeText -Needle 'staged temporary file' -Message 'Expected README to document staged-copy behavior.'
Assert-Contains -Haystack $readmeText -Needle 'existing destination file is preserved' -Message 'Expected README to document existing destination preservation on failed updates.'
Assert-Contains -Haystack $readmeText -Needle 'ACL Bootstrap' -Message 'Expected README to document ACL synchronization for existing profile items.'
Assert-Contains -Haystack $readmeText -Needle 'existing destination counterparts' -Message 'Expected README to document ACL synchronization for in-use profiles.'
Assert-Contains -Haystack $readmeText -Needle 'fail-closed safety mode' -Message 'Expected README to document that DryRun overrides mutating operations.'

Write-Output 'ANF-Move-AVD-Profiles static checks passed.'
