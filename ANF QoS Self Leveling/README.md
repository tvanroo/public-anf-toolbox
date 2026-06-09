# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.

# Download Script:
[Self Leveling](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Self%20Leveling/ANF-QoS-Autoscale-SelfLeveling.ps1)
    - Reallocates a defined percentage of throughput to volumes based on the historical frequency of Throughput Limit Reached metrics. Result: Volume performance is adjusted to minimize Throughput Limit Reached incidents.
[Self Leveling - FSL](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Self%20Leveling/ANF-QoS-Autoscale-SelfLeveling-FSL.ps1)
    - Flexible Service Level variant with Manual QoS assumptions, guarded decreases, and safer defaults for recurring automation.

## Deploy in Azure (FSL variant)
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftvanroo%2Fpublic-anf-toolbox%2F555984e%2FANF%2520QoS%2520Self%2520Leveling%2Fdeploy%2Fazuredeploy.json)
[![Deploy to Azure Gov](https://aka.ms/deploytoazurebutton)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftvanroo%2Fpublic-anf-toolbox%2F555984e%2FANF%2520QoS%2520Self%2520Leveling%2Fdeploy%2Fazuredeploy-gov.json)

Template file:
- `ANF QoS Self Leveling/deploy/azuredeploy.json`
- `ANF QoS Self Leveling/deploy/azuredeploy-gov.json` (Azure Government portal button target)
- This button deploys automation for `ANF-QoS-Autoscale-SelfLeveling-FSL.ps1` (Flexible Service Level version).

Post-deploy requirement:
- Deployment now attempts to grant the Automation Account managed identity Contributor at subscription scope automatically.
- If deployment IAM rights are insufficient for role assignment, grant Contributor at subscription scope manually before running live mode.
- Deployment uses Azure Automation runtime Az modules (no explicit PSG module pinning/import in the template).
- If you manually import custom Az modules, validate compatibility in a test Automation Account first.

## GA Safety Notes

- The script defaults to `$testMode = "Yes"`, so it reports planned throughput allocation without updating volumes.
- Live updates require `$testMode = "No"`.
- Auto QoS to Manual conversion is previewed in test mode and only executed when both `$ConvertToManualMode = "Yes"` and `$testMode = "No"`.
- Re-runs compare the current volume throughput values and only apply changes when the calculated target differs.

## FSL variant behavior (ANF-QoS-Autoscale-SelfLeveling-FSL.ps1)

- Expects a Manual QoS pool and exits if QoS is not Manual.
- Enforces floor checks:
  - Minimum pool throughput: `128 MiB/s`
  - Minimum per-volume throughput: `1 MiB/s`
- Uses `throughputLimitReached` history to rebalance throughput.
- Allows increases immediately when metrics indicate pressure.
- In live mode, increases pool throughput first (if needed), applies volume updates, then decreases pool throughput last (if needed).
- Throughput-only behavior: no volume capacity resize and no pool size/capacity resize operations are performed.
- Supports tag-based pool targeting across multiple ANF accounts/pools in the subscription.
  - Default include tag: `AnfQosSelfLevelingTarget=true`
- Allows decreases only when:
  - The last 3 rolling 24-hour windows are clean (aligned to script runtime), and
  - Any decrease update gate is satisfied by retry logic.
- For decrease updates that fail near timing boundaries, retries every 5 minutes for up to 1 hour before skipping that decrease.
- Supports tag-based volume exclusion. Volumes tagged with `ExcludeFromAnfQosSelfLeveling=true` are ignored by automation and remain unchanged.

## Quick safe start (recommended)

1. Set `testMode = "Yes"` and run once.
2. Review output table and verify proposed increases/decreases match expectations for your pool.
3. Keep defaults for first live run (`levelingAgressionPercent=10`, `throughputLimitMetricAllowance=6`), then set `testMode = "No"`.
4. Re-check next 1-2 runs and adjust aggressiveness only if needed.
5. Tag each capacity pool you want automated with `AnfQosSelfLevelingTarget=true`.
6. If a volume should be left untouched, add exclusion tag `ExcludeFromAnfQosSelfLeveling=true`.

## Deploy wizard inputs (what you set during Deploy to Azure)

### `targetPoolIncludeTagKey` (default `AnfQosSelfLevelingTarget`)
- Capacity-pool include tag key.
- Only pools with this key/value pair are processed.

### `targetPoolIncludeTagValue` (default `true`)
- Capacity-pool include tag value (case-insensitive).

### `testMode` (default `Yes`)
- `Yes`: dry run only.
- `No`: apply live throughput updates.

### `levelingAgressionPercent` (default `10`)
- Max share of movable throughput shifted each run.
- Lower = slower/steadier; higher = faster/more churn.

### `throughputLimitMetricAllowance` (default `6`)
- Equilibrium threshold.
- Above threshold: increase candidate.
- At/below threshold: decrease candidate (subject to decrease clean-window gate).

### `scheduleTimeZone` / `scheduleStartTimeUtc`
- Controls schedule timing only.

## Automation Shared Variables (post-deploy tuning in portal)

Edit these in **Automation Account → Shared Resources → Variables**.

### Targeting and run mode
- `ANF_SubscriptionId`: subscription scope for discovery.
- `ANF_TargetPoolIncludeTagKey` / `ANF_TargetPoolIncludeTagValue`: pool targeting tags.
- `ANF_TestMode`: `Yes` (preview) or `No` (live).

### Increase/decrease behavior
- `ANF_IncreaseLookBackHours` (default `24`): increase-signal lookback window.
- `ANF_DecreaseRequiredCleanDays` (default `3`): number of clean 24-hour windows required before decreases are allowed.
- `ANF_ThroughputLimitMetricAllowance` (default `6`): over/under threshold target.
- `ANF_LevelingAgressionPercent` (default `10`): per-run movement aggressiveness.

### Throughput safety floors
- `ANF_MinimumThroughputPerVolume` (default `1`)
- `ANF_MinimumPoolThroughputMibps` (default `128`)

### Decrease retry behavior
- `ANF_DecreaseRetrySleepSeconds` (default `300`)
- `ANF_DecreaseRetryMaxWaitSeconds` (default `3600`)

### Exclusions
- `ANF_ExcludeTagKey` (default `ExcludeFromAnfQosSelfLeveling`)
- `ANF_ExcludeTagValue` (default `true`)

### Optional auth overrides
- `ANF_TenantId` (usually not needed when Managed Identity context is healthy)

## Runtime decision flow (high level)

1. Discover tagged pools.
2. For each pool, evaluate volume metrics using `ANF_IncreaseLookBackHours`.
3. If pressure exists, rebalance toward the allowance threshold.
4. If no pressure exists, still evaluate eligible per-volume decreases.
5. Apply decrease gate: only volumes clean for `ANF_DecreaseRequiredCleanDays` can decrease.
6. Respect min floors and exclusion tags.

## Resource metadata/callback guidance for future admins

Recommended tags on deployed resources:
- `managed-by=public-anf-toolbox`
- `solution=anf-qos-self-leveling-fsl`
- `repository=https://github.com/tvanroo/public-anf-toolbox`
- `documentation=https://github.com/tvanroo/public-anf-toolbox/tree/main/ANF%20QoS%20Self%20Leveling`
- `script=ANF-QoS-Autoscale-SelfLeveling-FSL.ps1`
- `owner=<team-or-alias>`
- `support=<email-or-channel>`

Also populate a runbook description with purpose + documentation URL so operators can identify intent directly in Azure Automation.
