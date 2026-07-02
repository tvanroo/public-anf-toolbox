# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.


# Download Script:
[ANF Move AVD Profiles](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20Move%20AVD%20Profiles/ANF-Move-AVD-Profiles.ps1)
    - Migrates FSLogix AVD (Azure Virtual Desktop) profiles from existing SMB shares to Azure NetApp Files SMB shares with intelligent conflict resolution and profile-in-use detection. Result: Safe migration of user profiles with minimal downtime and data integrity protection.

## Script Purpose
This script is designed to run from a Windows VM or Windows host that has SMB access to both the source and destination shares. It migrates FSLogix profiles from legacy SMB file shares to Azure NetApp Files (ANF) SMB shares in Azure Virtual Desktop (AVD) environments. It performs intelligent file synchronization with conflict resolution and automatically detects profiles that are currently in use to prevent data corruption.

This is not deployed to Azure Automation because the copy process must run from a machine that can reach both file shares over SMB.

## Key Features
- **Intelligent File Comparison**: Compares creation and modification dates to resolve conflicts intelligently
- **Profile-in-Use Detection**: Automatically skips profiles that contain `.metadata` files (indicating active use)
- **BITS Transfer Technology**: Uses Background Intelligent Transfer Service for efficient file transfers
- **Staged Destination Updates**: Copies to a staged temporary file first, validates it, then replaces the destination only after validation succeeds
- **Metadata Preservation**: Copies timestamps, attributes, and NTFS ACLs from the source file to the destination file
- **Conflict Resolution Logic**: 
  - Overwrites destination files only if source files are more recently modified
  - Preserves newer profiles and prevents overwriting with older versions
  - Skips profiles with conflicting creation dates for manual resolution
- **Transfer Speed Monitoring**: Displays transfer speeds in MiB/s for performance monitoring
- **Optional Cleanup Operations**: Source files and empty directories are only removed when `-DeleteSourceAfterVerifiedCopy` is used
- **Selective Migration**: Supports filtering specific profiles using configurable filter strings

## Migration Logic
The script follows this intelligent decision tree for each file:

1. **Check Profile Usage**: Skip entire profile if `.metadata` file exists (profile in use)
2. **File Existence Check**: 
   - If destination file doesn't exist → Copy source to destination
   - If destination file exists → Apply conflict resolution logic
3. **Conflict Resolution** (when destination exists):
   - If creation times match AND source is newer → Copy to a staged temporary file, validate, then replace destination
   - If creation times match AND destination is newer/same → Skip overwrite
   - If creation times differ → Skip for manual resolution (prevents empty profile overwrites)
4. **Source Cleanup**:
   - Source files remain in place by default
   - With `-DeleteSourceAfterVerifiedCopy`, source files are deleted only after destination size and SHA256 hash validation

If an update fails, the existing destination file is preserved or restored from the temporary backup file. Failed new-file copies remove only the staged artifact by default, so reruns can copy them cleanly. Use `-KeepFailedDestinationFiles` only when you need to inspect a failed staged file.

## Configuration Variables
```powershell
.\ANF-Move-AVD-Profiles.ps1 `
    -SourcePath "\\old-fileserver.domain.com\profiles" `
    -DestinationPath "\\ANF-server.domain.com\anf-profiles" `
    -FilterString "username-filter" `
    -DryRun
```

Remove `-DryRun` to copy/update the destination. Add `-DeleteSourceAfterVerifiedCopy` only for a final cutover cleanup after reviewing the copy results.

## Prerequisites
- **Dual Path Configuration**: Both old and new SMB paths should be configured in FSLogix settings
- **Windows Runtime**: Run from a Windows VM or Windows host. Live copy mode requires `Start-BitsTransfer` and the Background Intelligent Transfer Service.
- **Administrative Access**: Script must run with permissions to both source and destination shares
- **BITS Service**: Background Intelligent Transfer Service must be available
- **Network Connectivity**: Reliable network connection between source and ANF destination
- **Testing**: Always test with non-production data first

## Usage Scenarios

### **Primary Use Case: Final Cutover Migration**
- Configure FSLogix with both old and new paths (old path as primary)
- Run script during maintenance window when users are logged off
- Profiles get migrated and will automatically use new ANF path on next login

### **Selective User Migration**
- Use `$FilterString` to migrate specific users or user groups
- Useful for phased migrations or troubleshooting specific profiles

### **Cleanup Operations**  
- Optionally remove migrated data from legacy storage after verified copies
- Consolidate profiles from multiple legacy shares

## Safety Features
- **Dry Run Mode**: `-DryRun` lists copy, overwrite, and optional cleanup actions without changing files
- **Non-Destructive Default**: Source files are preserved unless `-DeleteSourceAfterVerifiedCopy` is provided
- **Verified Source Cleanup**: Optional source deletion requires matching destination size and SHA256 hash
- **Staged Copy Safety**: Existing destination files are not overwritten until the staged temporary file is copied and validated; source metadata is applied to the final destination before source cleanup is allowed
- **Destination Restore**: If replacement validation fails, the previous destination file is restored when one existed
- **Profile Lock Detection**: Automatically skips profiles with active `.metadata` files
- **Conflict Logging**: Clear console output showing all actions taken
- **Preservation Logic**: Prevents overwriting newer profiles with older versions
- **Manual Resolution Flags**: Identifies conflicts requiring administrator attention

## Output Messages
- **🟢 Green**: Successful file copies and updates with transfer speeds
- **🟡 Yellow**: Optional cleanup actions and conflicts requiring manual resolution
- **⚪ White**: Skipped files with reasoning
- **🔘 Gray**: Filtered or in-use profiles that were skipped

## Migration Best Practices
1. **Test First**: Always test with non-critical profiles in a lab environment
2. **Backup Strategy**: Ensure reliable backups of source profiles before migration
3. **Maintenance Windows**: Run during off-hours when users are not logged in
4. **Phased Approach**: Consider migrating users in batches using filter strings
5. **Monitor Performance**: Watch transfer speeds and adjust timing accordingly
6. **Validate Results**: Confirm successful profile access after migration

## FSLogix Integration Notes
- Designed to work with FSLogix multi-path configurations
- Supports Profile Container and Office Container scenarios  
- Compatible with both user profiles and application data
- Maintains NTFS permissions and ACLs during transfer
- Preserves file timestamps and metadata

## Troubleshooting
- **Slow Transfers**: Check network bandwidth between source and ANF
- **Permission Errors**: Verify service account has full access to both shares
- **Profile Corruption**: Review conflict resolution logs for manual intervention needs
- **BITS Errors**: Ensure BITS service is running and properly configured

## Important Notes
- By default, this is a one-way sync to the destination and does not delete source files
- `-DeleteSourceAfterVerifiedCopy` turns it into a final cutover cleanup tool
- Failed destination copies are removed by default so reruns can copy them cleanly; use `-KeepFailedDestinationFiles` only when you need to inspect failed output
- Manual resolution is required for profiles with conflicting creation dates
- Profiles currently in use (with `.metadata` files) are automatically protected
