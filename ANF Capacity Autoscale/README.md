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

## GA Safety Notes

- Both autoscale scripts default to test mode. `ANF_TestMode` must be set to `No` before pool, volume, or throughput changes are applied.
- If `ANF_TestMode` is missing in Azure Automation, the scripts now fall back to `Yes` instead of live mode.
- Local defaults are placeholders. Replace the resource group, account, pool, and volume values before running against real ANF resources.
- Re-runs recalculate current capacity and throughput state before acting, so delta runs only apply changes that are still needed.
