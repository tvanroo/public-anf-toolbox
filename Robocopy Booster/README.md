# Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.

# Robocopy Booster

Robocopy Booster accelerates large file-copy migrations that contain many small files by running multiple Robocopy jobs in parallel. Each top-level source directory becomes a separate Robocopy job, and root-level source files are copied as one additional job.

## Download Scripts

### [Robocopy Booster](https://github.com/tvanroo/public-anf-toolbox/blob/main/Robocopy%20Booster/robocopy-booster.ps1)

Baseline version with normal Robocopy output, parallel directory processing, dry-run support, source/destination path validation, and safe exit-code handling.

### [Robocopy Booster V2](https://github.com/tvanroo/public-anf-toolbox/blob/main/Robocopy%20Booster/robocopy-booster-v2.ps1)

Enhanced version with the same copy behavior plus an `-EnableLogging` switch for A/B testing normal Robocopy output against silent/no-logging mode. When Robocopy reports a transfer speed in normal logging mode, V2 includes that per-job speed in the completion output.

## Sync Contract

These scripts are one-way source-to-destination copy/update tools.

- Source data is not deleted, moved, renamed, or purged.
- The scripts do not use Robocopy `/MOV`, `/MOVE`, `/MIR`, or `/PURGE`.
- The destination is created if it does not already exist, unless `-DryRun` is used.
- The destination must not be inside the source path. The scripts block this because it would create or update files under the source tree.
- Existing destination reparse points, junctions, and symlinks are blocked. Use the real destination path.
- Top-level source reparse directories are skipped, and Robocopy runs with `/XJ` to avoid junction traversal.
- Destination files may be created or overwritten when source files are new or changed.
- Extra destination files are left in place. These scripts are not mirror/purge tools.

## First Run Behavior

On the first run, the scripts:

1. Validate that Robocopy is available.
2. Validate that the source exists and is a directory.
3. Resolve the destination path and create it if needed.
4. Block unsafe destination paths, including destination paths inside the source tree or through reparse points.
5. Copy source root files to the destination root.
6. Copy each non-reparse top-level source directory to the matching destination directory in parallel.

## Rerun / Delta Behavior

On subsequent reruns, Robocopy handles delta behavior:

- Matching files are skipped.
- New source files are copied to the destination.
- Changed source files are copied to the destination.
- Deleted source files do not cause destination deletes.
- Extra destination files are reported by Robocopy but left in place.

This makes the scripts suitable for repeated catch-up passes before a final migration cutover where the source should remain untouched.

## Example Usage

Run a dry run first:

```powershell
.\robocopy-booster-v2.ps1 `
  -SourcePath "\\old-file-server\profiles" `
  -DestinationPath "\\anf-smb-volume\profiles" `
  -MaxJobs 8 `
  -ThreadsPerJob 32 `
  -DryRun
```

Run the copy/update pass:

```powershell
.\robocopy-booster-v2.ps1 `
  -SourcePath "\\old-file-server\profiles" `
  -DestinationPath "\\anf-smb-volume\profiles" `
  -MaxJobs 8 `
  -ThreadsPerJob 32
```

Run V2 with normal Robocopy output for troubleshooting:

```powershell
.\robocopy-booster-v2.ps1 `
  -SourcePath "\\old-file-server\profiles" `
  -DestinationPath "\\anf-smb-volume\profiles" `
  -MaxJobs 4 `
  -ThreadsPerJob 16 `
  -EnableLogging
```

The original script supports the same core parameters, except it does not include `-EnableLogging` because it always uses normal Robocopy output.

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-SourcePath` | `Z:\` | Source directory to copy from. Alias: `-src`. |
| `-DestinationPath` | `C:\txtest` | Destination directory to copy to. Alias: `-dest`. |
| `-MaxJobs` | `12` | Maximum parallel Robocopy jobs. Alias: `-max_jobs`. |
| `-ThreadsPerJob` | `128` | Robocopy `/MT` threads per job. Alias: `-mtreads`. |
| `-RetryCount` | `1` | Robocopy `/R` retry count. |
| `-WaitSeconds` | `1` | Robocopy `/W` wait time between retries. |
| `-DryRun` | Off | Adds Robocopy `/L` so actions are listed without writing to the destination. |
| `-EnableLogging` | Off | V2 only. Shows normal Robocopy output. When omitted, V2 uses silent/no-logging switches. |

## V2 Silent Mode Switches

When `-EnableLogging` is omitted, V2 adds these switches:

- `/NFL` - No file list.
- `/NDL` - No directory list.
- `/NJH` - No job header.
- `/NJS` - No job summary.
- `/NP` - No progress percentage.
- `/NC` - No file classes.
- `/NS` - No file sizes.
- `/LOG:NUL` - Redirect Robocopy log output to the null device.

## Exit Codes

Each Robocopy job returns its Robocopy exit code. The scripts summarize all jobs and then return:

- `0` when the highest Robocopy exit code is below `8`.
- `1` when any job returns Robocopy exit code `8` or higher, or when script validation fails.

Robocopy exit-code ranges:

- `0-3`: Normal success states.
- `4-7`: Warning states, often including extras or mismatches.
- `8+`: Failure states.

## Best Practices

- Start with `-DryRun` against the real source and destination paths.
- Use conservative values such as `-MaxJobs 4` and `-ThreadsPerJob 16`, then scale up while watching CPU, SMB sessions, network throughput, and storage latency.
- Keep the destination outside the source tree.
- Use V2 silent mode for throughput tests and `-EnableLogging` when troubleshooting.
- For cutover planning, run multiple delta passes and review the final summary for warning/error jobs.

## Important Limitations

- These scripts are designed for Windows environments where Robocopy is available.
- They intentionally do not delete extra destination files. If you need mirror semantics, use a separate, carefully reviewed Robocopy command.
- They intentionally skip top-level source reparse directories and exclude junction traversal. If reparse-point content must be copied, review and run a purpose-built Robocopy command for that specific path.
- They parallelize by top-level source directory, so performance is best when source data is spread across multiple reasonably balanced directories.
