# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.


# Download Scripts:

## [Robocopy Booster (Original)](https://github.com/tvanroo/public-anf-toolbox/blob/main/Robocopy%20Booster/robocopy-booster.ps1)
- Runs multiple Robocopy commands in parallel, each with multiple threads to speed up the transfer of datasets containing numerous files where throughput limits are not being reached due to file count.

## [Robocopy Booster V2 (A/B Testing)](https://github.com/tvanroo/public-anf-toolbox/blob/main/Robocopy%20Booster/robocopy-booster-v2.ps1)
- Enhanced version with A/B testing capabilities for logging vs no-logging performance comparison. Includes silent mode with optimized switches for maximum throughput testing.

## Script Purpose
These scripts are designed to accelerate file transfers in scenarios where you have many small files and standard single-threaded robocopy operations are not saturating available network bandwidth or storage throughput. The parallel approach distributes the workload across multiple robocopy processes running simultaneously.

## Key Features

### Original Script
- **Parallel Processing**: Runs multiple robocopy jobs simultaneously
- **Configurable Concurrency**: Control max parallel jobs and threads per job  
- **Automatic Throttling**: Manages job queue to prevent system overload
- **Progress Monitoring**: Real-time job status and completion tracking

### V2 Enhanced Features
- **A/B Testing Flag**: `$EnableLogging` parameter for performance comparison
- **Silent Mode**: Uses `/NFL /NDL /NJH /NJS /NP /NC /NS /LOG:NUL` switches
- **Optimized Error Handling**: `/R:0 /W:0` for faster processing
- **Detailed Results**: Comprehensive execution time and job status reporting
- **Progress Indicators**: Real-time progress bar and completion percentages

## Performance Optimization

### Silent Mode Switches (V2)
- `/NFL` - No File List (don't log individual files)
- `/NDL` - No Directory List (don't log directories)
- `/NJH` - No Job Header (suppress job header)
- `/NJS` - No Job Summary (suppress job summary)
- `/NP` - No Progress (don't show progress percentage)
- `/NC` - No Class (don't log file classes)
- `/NS` - No Size (don't log file sizes)
- `/LOG:NUL` - Redirect log to null device

### Expected Performance Gains
- **Small Files**: 5-15% improvement in silent mode
- **Network-Bound**: Minimal improvement for bandwidth-saturated transfers
- **CPU-Bound**: More significant gains when processing overhead is the bottleneck

## Configuration Variables

### Common Settings (Both Versions)
```powershell
$max_jobs = 16          # Maximum parallel robocopy jobs
$mtreads = 16           # Threads per robocopy job (/MT switch)
$src = "Z:\source"      # Source directory path
$dest = "C:\destination" # Destination directory path
```

### V2 Additional Settings
```powershell
$EnableLogging = $false  # $true = normal logging, $false = silent mode
```

## Usage Scenarios

### Standard File Migration
- Use original script for general purpose file transfers
- Good for testing and debugging with full logging

### Performance Testing
- Use V2 script with `$EnableLogging = $true` for baseline test
- Use V2 script with `$EnableLogging = $false` for performance test
- Compare execution times to measure logging overhead

### Production Migrations
- Use V2 script in silent mode for maximum throughput
- Monitor results summary for success/failure counts

## Best Practices

### Directory Structure
- Source should contain multiple subdirectories for parallel processing
- Each subdirectory becomes a separate robocopy job
- Works best with balanced directory sizes

### Resource Planning
- Start with conservative job counts (4-8) and increase gradually
- Monitor CPU and network utilization during transfers
- Adjust threads per job based on storage capabilities

### Testing Approach
1. **Small Test**: Run with 2-3 directories first
2. **Baseline**: Test with logging enabled
3. **Performance**: Test with logging disabled
4. **Scale Up**: Increase job count based on system resources

## Troubleshooting

### Common Issues
- **High CPU Usage**: Reduce `$max_jobs` or `$mtreads`
- **Network Saturation**: Reduce total concurrent operations
- **Slow Performance**: Check if source has enough directories for parallelization

### Exit Codes
- **0-3**: Success (normal completion)
- **4-7**: Warnings (some files skipped)
- **8+**: Errors (significant issues encountered)

## Use Cases
- **Azure NetApp Files**: Migrating to ANF volumes with high IOPS requirements
- **File Server Migrations**: Moving from legacy storage to modern platforms
- **Data Center Moves**: Bulk file transfers between locations
- **Backup Operations**: Parallel backup of directory structures
- **Performance Testing**: Measuring storage system capabilities
