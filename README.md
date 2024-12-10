# Toby's Public ANF Scripts & Tools

# ⚠️ Warning

**Important Notice:**

This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.


# Index of Resources

- [Awesome Azure NetApp Files (ANF) - A curated list of Azure NetApp Files Resources](https://github.com/ANFTechTeam/awesome-anf)

- [Toby's ANF Scripts](#tobys-anf-scripts)

# Resource Contents

## Toby's ANF Scripts

### QoS Automation

- [Mimic Auto](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Mimic%20Auto)
    - Allocates _all_ pool throughput to volumes based on relative volume size. Result: Volume performance is governed by volume size.
- [Volume Equity](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Volume%20Equity)
    - Allocates _all_ pool throughput to volumes equally, regardless of volume size. Result: Volume performance is governed by volume quantity.
- [Performance](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Performance)
    - Allocates _all_ pool throughput to volumes based on historical average throughput usage metrics. Result: Volume performance is governed by historical throughput usage.
- [Self Leveling](https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS%20Self%20Leveling)
    - Reallocates a defined percentage of throughput to volumes based on the historical frequency of Throughput Limit Reached metrics. Result: Volume performance is adjusted to minimize Throughput Limit Reached incidents.

### ANF Build Automation

- [Automated ANF Build & Teardown](https://github.com/tvanroo/public-anf-toolbox/blob/main/Automated%20Build%20and%20Teardown)
    - Quick build/teardown of ANF Account, Capacity Pool, and Volume(s). Variables can be edited to match deployment requirements.

### ANF Scaling Plan
- [ANF Weekend Scaling Plan (Move volumes between tiers)](https://github.com/tvanroo/public-anf-toolbox/tree/main/ANF%20Weekend%20Scaling%20Plan)
    - Moves volumes to a lower Service Level on the weekend and back to the higher Service Level for the work week to reduce active data costs for ~35% of the week.
    - Note: Moving a volume back down to a lower Service Level (e.g. from Premium to Standard) requires 24 hours on the higher tier. Therefore, this cost saving strategy works for weekends but is not able to reach daily after-hours granularity.
- [ANF Daily Pool Size Scaling Plan (Increase size & throughput of Pool & Volume)](https://github.com/tvanroo/public-anf-toolbox/tree/main/ANF%20Daily%20Pool%20Size%20Scaling%20Plan)
    - Resizes the Capacity Pool and allocates throughput to volumes equally to scale up/down performance for on/off hours.
    - Note: Unlike switching Service Levels, increasing and decreasing the size of the pool and then throughput allocation can happen anytime. This cost saving strategy can capture after-hours and weekend savings.

### Migration Tools
- [Robocopy Booster](https://github.com/tvanroo/public-anf-toolbox/tree/main/Robocopy%20Booster)
    - Runs multiple Robocopy commands in parallel, each with multiple threads to speed up the transfer of datasets containing numerous files where throughput limits are not being reached due to file count.
