# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.


# Download Script:
[Throughput Metrics Collector](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20Throughput%20Metrics%20Collector/ANF-throughput-metrics-collector.ps1)
    - Collects the last 30 days of throughput metrics for Azure NetApp Files volumes with 5-minute resolution and exports the data to CSV format. Result: Historical throughput data for analysis and reporting.

## Script Purpose
This script automates the collection of Azure NetApp Files volume throughput metrics over a 30-day period with 5-minute granularity. Unlike the other scripts in this repository that focus on QoS allocation and performance optimization, this script is purely for data collection and analysis.

## Key Features
- **Historical Data Collection**: Retrieves 30 days of throughput metrics
- **High Resolution**: 5-minute data granularity for detailed analysis
- **Multiple Metrics**: Collects ReadThroughput, WriteThroughput, TotalThroughput, and OtherThroughput
- **CSV Export**: Exports data in a structured CSV format for easy analysis
- **Configurable Targeting**: Can target specific volumes or entire capacity pools
- **No Volume Modifications**: Read-only operation - does not modify any ANF resources

## Metrics Collected
- **ReadThroughput**: Throughput for read operations (BytesPerSecond)
- **WriteThroughput**: Throughput for write operations (BytesPerSecond)
- **TotalThroughput**: Combined read and write throughput (BytesPerSecond)
- **OtherThroughput**: Other operations throughput (BytesPerSecond)

## Configuration Variables
The script uses the following configurable variables for targeting specific ANF resources:

```powershell
$tenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"      # Azure tenant ID
$subscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" # Subscription ID (optional)
$resourceGroupName = "example-rg"                       # Resource group name
$anfAccountName = "example-anf-acct"                    # ANF account name
$anfPoolName = "example-anf-pool"                       # ANF pool name
$volumeName = ""                                        # Specific volume (empty = all volumes)
```

## Script Configuration
- **Look-back Period**: 30 days (configurable via `$lookBackDays`)
- **Time Resolution**: 5 minutes (configurable via `$timeGrainMinutes`)
- **Output Location**: `C:\temp\ANF-throughput-metrics.csv` (configurable via `$outputPath`)

## Prerequisites
- Azure PowerShell modules: `Az.Accounts`, `Az.NetAppFiles`, `Az.Monitor`
- Authenticated Azure session with read permissions to ANF resources
- Access to Azure Monitor metrics for the target ANF resources

## Usage Examples
1. **Collect metrics for a specific volume**:
   - Set `$volumeName = "my-volume-name"`
   - Run the script

2. **Collect metrics for all volumes in a pool**:
   - Leave `$volumeName = ""` (empty)
   - Run the script

3. **Custom time range**:
   - Modify `$lookBackDays` for different time periods
   - Modify `$timeGrainMinutes` for different resolution

## CSV Output Format
The exported CSV contains the following columns:
- `Timestamp`: When the metric was recorded
- `ResourceGroup`: Azure resource group name
- `ANFAccount`: ANF account name
- `ANFPool`: ANF capacity pool name
- `VolumeName`: Volume name
- `VolumeId`: Full Azure resource ID
- `MetricName`: Type of throughput metric
- `Value`: Raw value in bytes per second
- `Unit`: Always "BytesPerSecond"
- `ValueMiBps`: Converted value in MiB/s
- `TimeGrainMinutes`: Time resolution (5 minutes)

## Use Cases
- **Performance Analysis**: Analyze historical throughput patterns
- **Capacity Planning**: Understand peak usage periods and trends
- **Troubleshooting**: Identify performance bottlenecks and anomalies
- **Reporting**: Generate throughput reports for management
- **Integration**: Import data into other analytics tools

## Notes
- The script only collects existing metrics data - if a volume is new or has been inactive, less than 30 days of data may be available
- Authentication to Azure is required before running the script
- The script is read-only and does not modify any ANF resources
- Large datasets may take several minutes to collect and export
