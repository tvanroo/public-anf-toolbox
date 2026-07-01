# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.

## Download Script

[ANF Capacity Autoscale](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20Capacity%20Autoscale/ANF-Capacity-Autoscale.ps1)
    - Monitors volume capacity utilization and automatically adjusts volume sizes to prevent running out of space while keeping the pool size optimized for cost efficiency. Analyzes consumption trends and proactively resizes volumes when utilization thresholds are reached.

## Flexible Service Level behavior

- The main capacity autoscale script now detects the capacity pool service level before planning changes.
- Standard, Premium, and Ultra manual QoS pools keep the previous behavior: available throughput is calculated from the pool-size-derived throughput budget and allocated proportionally to volumes, while respecting `ANF_VolumeMinThroughputMap`.
- Flexible Service Level pools require Manual QoS. Their capacity and throughput are planned independently: resizing the pool for capacity does not reduce or increase throughput just because the pool size changed.
- For Flexible Service Level pools, the script allocates volume throughput from the current pool throughput. It only plans a pool throughput increase when the configured per-volume minimum throughput requirements exceed the current pool throughput or the `ANF_MinimumPoolThroughputMibps` floor.
- `ANF_MinimumPoolThroughputMibps` defaults to `128`, matching the included per-pool Flexible Service Level throughput floor.

## Current settings

Settings can be supplied as Azure Automation variables or as Cloud Shell/local process environment variables using the same `ANF_*` names.

| Setting | Default | Used for |
| --- | --- | --- |
| `ANF_SubscriptionId` | placeholder | Azure subscription selection. |
| `ANF_TenantId` | placeholder | Optional tenant selection. |
| `ANF_ResourceGroupName` | required | Target ANF resource group. |
| `ANF_AccountName` | required | Target ANF account. |
| `ANF_PoolName` | required | Target capacity pool. |
| `ANF_TestMode` | `Yes` | `Yes` previews only; `No` applies changes. |
| `ANF_CapacityResizeThreshold` | `99` | Expands a volume when max observed utilization is at or above this percent. |
| `ANF_MinimumFreeSpaceGiB` | `256` | Expands a volume when free space is at or below this value; also sizes expansion/contraction targets. |
| `ANF_MinimumVolumeGrowthPercent` | `0` | Minimum percent growth when expanding a volume. |
| `ANF_MaximumVolumeGrowthPercent` | `10000000` | Maximum percent growth allowed in one run. |
| `ANF_CapacityLookBackHours` | `24` | Lookback window for the `VolumeLogicalSize` metric. |
| `ANF_VolumeMinThroughputMap` | empty map | JSON volume-to-minimum-throughput map, for example `{"vol1":10,"vol2":15}`. |
| `ANF_MaxThroughputPerTiB` | `68` | Classic manual QoS cap for calculated pool throughput per TiB. Not used to derive FSL throughput. |
| `ANF_MinimumPoolThroughputMibps` | `128` | Flexible Service Level pool throughput floor. |

## Hard-coded decisions

These values are currently fixed in the script rather than exposed as inputs.

| Decision | Value | Notes |
| --- | --- | --- |
| Minimum volume size | `50` GiB | ANF minimum volume size guard. |
| Maximum volume size | `102400` GiB | 100 TiB volume size guard. |
| Default volume minimum throughput | `1` MiB/s | Used when a volume is absent from `ANF_VolumeMinThroughputMap`. |
| Contraction utilization buffer | `15` percentage points | Contraction requires utilization at or below `ANF_CapacityResizeThreshold - 15`. |
| Contraction free-space gate | `3x` | Contraction requires free space at or above `ANF_MinimumFreeSpaceGiB * 3`. |
| Pool sizing increment | `1024` GiB | Pool targets are rounded to whole TiB. |
| Minimum pool size | `1` TiB | Pool target is never below 1 TiB. |
| Capacity metric time grain | `01:00:00` | `VolumeLogicalSize` is queried hourly over the lookback window. |
| Missing capacity metric data | `0` consumed | Missing or empty metric data is treated as 0 GiB consumed. |

## GA Safety Notes

- Both autoscale scripts default to test mode. `ANF_TestMode` must be set to `No` before pool, volume, or throughput changes are applied.
- If `ANF_TestMode` is missing in Azure Automation, the scripts now fall back to `Yes` instead of live mode.
- Local defaults are placeholders. Set `ANF_ResourceGroupName`, `ANF_AccountName`, and `ANF_PoolName` before running against real ANF resources.
- Re-runs recalculate current capacity and throughput state before acting, so delta runs only apply changes that are still needed.
