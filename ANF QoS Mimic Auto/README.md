# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.


# Download Script:
[Mimic Auto](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Mimic%20Auto/ANF-QoS-Autoscale-MimicAuto.ps1)
    - Allocates _all_ pool throughput to volumes based on relative volume size. Result: Volume performance is governed by volume size.

## GA Safety Notes

- The script defaults to `$testMode = "Yes"`, so it reports planned throughput allocation without updating volumes.
- Live updates require `$testMode = "No"`.
- Auto QoS to Manual conversion is previewed in test mode and only executed when both `$ConvertToManualMode = "Yes"` and `$testMode = "No"`.
- Re-runs compare the current volume throughput values and only apply changes when the calculated target differs.
