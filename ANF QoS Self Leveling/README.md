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
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Ftvanroo%2Fpublic-anf-toolbox%2F4bb1b13593bcccf028d2a831fc5b72786cdb7c66%2FANF%2520QoS%2520Self%2520Leveling%2Fdeploy%2Fazuredeploy.json)

Template file:
- `ANF QoS Self Leveling/deploy/azuredeploy.json`
- This button deploys automation for `ANF-QoS-Autoscale-SelfLeveling-FSL.ps1` (Flexible Service Level version).

Post-deploy requirement:
- Grant the Automation Account managed identity access to your ANF target scope before running live mode (for example, Reader at subscription for discovery + Contributor on tagged ANF resource groups for updates).
- In the Automation Account, confirm module `Az.NetAppFiles` import reaches `Available` before first Test Pane run (initial import can take several minutes).

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

## Detailed script input guidance (FSL variant)

### `tenantId`
- What it is: Azure tenant used for authentication.
- Default in script: placeholder.
- Typical value: your Entra tenant GUID.
- Impact: wrong value prevents authentication.

### `subscriptionId`
- What it is: subscription scope used for capacity pool discovery.
- Typical value: set automatically by deploy template.
- Impact: script discovers tagged pools in this subscription.

### `targetPoolIncludeTagKey` (default: `AnfQosSelfLevelingTarget`)
- What it is: capacity pool include tag key.
- Impact: only pools with this key/value pair are targeted.

### `targetPoolIncludeTagValue` (default: `true`)
- What it is: include tag value (case-insensitive match).
- Impact: controls which pools are in-scope for automation.

### `testMode` (default: `Yes`)
- What it is: dry-run vs live mode.
- `Yes`: shows proposed changes only.
- `No`: applies updates with `Update-AzNetAppFilesVolume`.
- Why default is `Yes`: safest first-run behavior for production pools.

### `minimumThroughputPerVolume` (fixed minimum allowed: `1`)
- What it is: per-volume floor.
- Impact: prevents over-shrinking smaller or less active volumes.
- Typical option: keep at `1` unless policy requires higher minimum guarantees.

### `minimumPoolThroughputMibps` (default: `128`)
- What it is: pool floor guard for FSL.
- Impact: exits if pool throughput is below supported floor for this workflow.
- Typical option: keep at `128`.

### `throughputLookBackHours` (default: `24`)
- What it is: metric window for primary rebalancing signal.
- Lower values: more reactive, more movement run-to-run.
- Higher values: smoother behavior, slower reaction.
- Typical options: `24` (daily cadence), sometimes `12` for higher reactivity.

### `levelingAgressionPercent` (default: `10`)
- What it is: max share of allocatable throughput moved per run.
- Lower values (5-10): conservative, stable, slower convergence.
- Higher values (15-25): faster convergence, more churn.
- Why default is `10`: balanced tradeoff for most steady-state production pools.

### `throughputLimitMetricAllowance` (default: `6`)
- What it is: acceptable threshold for considering a volume “performant”.
- Lower values: stricter, more volumes treated as needing help.
- Higher values: more permissive, fewer reallocations.
- Why default is `6`: practical middle ground to reduce noisy reallocations.

### `decreaseRetrySleepSeconds` (default: `300`)
- What it is: retry interval for failed decrease updates.
- Typical option: keep at 300 (5 min).
- Impact: smaller value retries faster but increases API activity.

### `decreaseRetryMaxWaitSeconds` (default: `3600`)
- What it is: max cumulative wait for decrease retries in one run.
- Typical option: 1800-3600.
- Why default is `3600`: avoids losing a full day due to near-boundary timing while keeping run time bounded.

### `excludeTagKey` (default: `ExcludeFromAnfQosSelfLeveling`)
- What it is: tag key used to identify excluded volumes.
- Typical option: keep default.
- Impact: volumes matching key/value are not rebalanced.

### `excludeTagValue` (default: `true`)
- What it is: required tag value for exclusion (case-insensitive match).
- Typical option: keep default and tag excluded volumes as `ExcludeFromAnfQosSelfLeveling=true`.
- Impact: excluded volumes are ignored by automation and their allocated throughput is reserved out of the managed throughput budget.

## Deploy-in-Azure input guidance (proposed)

### Inputs to prompt for
- `targetPoolIncludeTagKey` (recommended default: `AnfQosSelfLevelingTarget`)
- `targetPoolIncludeTagValue` (recommended default: `true`)
- `testMode` (recommended default: `Yes`)
- `levelingAgressionPercent` (recommended default: `10`)
- `throughputLimitMetricAllowance` (recommended default: `6`)
- `scheduleTimeZone` (recommended default: `UTC`)

### Inputs to auto-generate or fix
- Automation account name: auto-generated
- Region/location: uses the deployment resource group's region (portal Region selector)
- Managed identity type: fixed to SystemAssigned
- Runbook name: fixed
- Schedule name: fixed
- Frequency: every 24 hours
- Start time: auto-generated
- SubscriptionId: auto-set to deployment subscription
- `throughputLookBackHours`: fixed to `24`
- `minimumThroughputPerVolume`: fixed to `1`
- `minimumPoolThroughputMibps`: fixed to `128`
- No deploy-time exclusion list input is exposed. Use volume tags post-deployment (`ExcludeFromAnfQosSelfLeveling=true`) to exclude specific volumes.

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
