# ANF Throughput Metrics Collector

This read-only script exports historical Azure NetApp Files volume throughput metrics to CSV. It supports Standard, Premium, Ultra, and Flexible Service Level capacity pools because it reads Azure Monitor metrics from each target volume and does not depend on service-level-specific throughput calculations.

![ANF Throughput Metrics Collector behavior](media/throughput-metrics-collector.png)

## What It Collects

- `ReadThroughput`
- `WriteThroughput`
- `TotalThroughput`
- `OtherThroughput`

Values are exported in bytes per second and MiB/s.

Each capacity pool is queried independently. The script does not modify pools, volumes, QoS settings, capacity, or throughput.

## Inputs

Set these as environment variables before running from Cloud Shell or a local PowerShell session. Azure Automation variables with the same names are also supported if you choose to run it there.

| Variable | Default | Impact |
| --- | --- | --- |
| `ANF_CapacityPoolResourceId` | required | One or more full capacity pool Resource IDs. Separate multiple IDs with new lines, semicolons, or commas. |
| `ANF_TenantId` | current context | Optional tenant ID used when authentication needs to switch tenants. |
| `ANF_VolumeName` | all volumes | Optional volume name filter. Multiple names can be separated with new lines, semicolons, or commas. |
| `ANF_LookBackDays` | `30` | Number of trailing days to request from Azure Monitor. |
| `ANF_TimeGrainMinutes` | `5` | Metric interval in minutes. |
| `ANF_OutputPath` | `./ANF-throughput-metrics.csv` | CSV output path. |
| `ANF_OverwriteOutput` | `No` | `No` protects an existing output file. Set to `Yes` to overwrite. |

## Example

```powershell
$env:ANF_CapacityPoolResourceId = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.NetApp/netAppAccounts/<account>/capacityPools/<pool>"
$env:ANF_OutputPath = "./anf-throughput.csv"
$env:ANF_OverwriteOutput = "No"
pwsh ./ANF-throughput-metrics-collector.ps1
```

Multiple pools can be collected in one run:

```powershell
$env:ANF_CapacityPoolResourceId = @"
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.NetApp/netAppAccounts/<account>/capacityPools/<pool-a>
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.NetApp/netAppAccounts/<account>/capacityPools/<pool-b>
"@
```

## Output Columns

- `Timestamp`
- `SubscriptionId`
- `ResourceGroup`
- `ANFAccount`
- `ANFPool`
- `ServiceLevel`
- `QoSType`
- `VolumeName`
- `VolumeId`
- `MetricName`
- `AverageBytesPerSecond`
- `AverageMiBps`
- `TimeGrainMinutes`

## Permissions

The authenticated identity needs read access to the ANF account and Azure Monitor metrics access for the target volumes. Monitoring Reader on the ANF account scope is the intended least-surprise permission for metric reads.

## Notes

- New or inactive volumes may have fewer data points than the requested lookback window.
- Large lookback windows and small intervals can produce large CSV files.
- The script uses ARM REST calls and only requires `Az.Accounts`.
