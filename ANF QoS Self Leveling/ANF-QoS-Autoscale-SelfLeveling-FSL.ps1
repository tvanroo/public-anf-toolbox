<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 06/09/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script automates the allocation of Throughput MiBs/Sec to Azure NetApp Files Flexible Service Level volumes based on past throughput limits reached metrics.

Recommended use:
Run on a recurring basis and allow it to balance the throughput of the volumes based on the past throughput limits reached metrics over time. 
You can adjust how aggressive the script is in a few ways:
    1. Adjust the $levelingAgressionPercent variable to a higher or lower value. This defines how much throughput from drives is reallocated to non-performant drives.
    2. Run this script more or less frequently and adjust the $throughputLookBackHours variable to define how far back in time the script looks for throughput limit metrics.
        a. More frequent running of the script will move the throughput around more frequently.
        b. A shorter look-back period will make the script more reactive (with each run) to changes in throughput usage.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# User Editable Variables (environment-first):
    $tenantId = $env:ANF_TenantId                           # Tenant ID for Azure authentication (optional)
    $subscriptionId = $env:ANF_SubscriptionId               # Optional subscription ID override (recommended for Automation)
    $resourceGroupName = $env:ANF_ResourceGroupName         # Optional fallback single-target resource group name
    $anfAccountName = $env:ANF_AccountName                  # Optional fallback single-target ANF account name
    $anfPoolName = $env:ANF_PoolName                        # Optional fallback single-target ANF pool name
    $targetPoolIncludeTagKey = if ($env:ANF_TargetPoolIncludeTagKey) { $env:ANF_TargetPoolIncludeTagKey } else { "AnfQosSelfLevelingTarget" }  # Capacity pools with this tag key/value are targeted
    $targetPoolIncludeTagValue = if ($env:ANF_TargetPoolIncludeTagValue) { $env:ANF_TargetPoolIncludeTagValue } else { "true" }                 # Tag value match is case-insensitive
    $testMode = if ($env:ANF_TestMode) { $env:ANF_TestMode } else { "Yes" }                                                                  # Test Mode Selector: "Yes", "No"  Yes displays report, No makes changes and displays report
    $minimumThroughputPerVolume = if ($env:ANF_MinimumThroughputPerVolume) { [int]$env:ANF_MinimumThroughputPerVolume } else { 1 }            # Minimum throughput per volume in MiB/s (minimum allowed is 1)
    $minimumPoolThroughputMibps = if ($env:ANF_MinimumPoolThroughputMibps) { [int]$env:ANF_MinimumPoolThroughputMibps } else { 128 }          # Minimum flexible service level pool throughput in MiB/s
    $throughputLookBackHours = if ($env:ANF_ThroughputLookBackHours) { [int]$env:ANF_ThroughputLookBackHours } else { 24 }                    # Look-back period in hours for throughput metrics
    $levelingAgressionPercent = if ($env:ANF_LevelingAgressionPercent) { [int]$env:ANF_LevelingAgressionPercent } else { 10 }                 # Leveling Aggression Factor: How much throughput is re-allocated per run?
    $throughputLimitMetricAllowance = if ($env:ANF_ThroughputLimitMetricAllowance) { [double]$env:ANF_ThroughputLimitMetricAllowance } else { 6 }  # What ThroughputLimitMetric value is considered acceptable for a volume to be considered performant
    $decreaseRetrySleepSeconds = if ($env:ANF_DecreaseRetrySleepSeconds) { [int]$env:ANF_DecreaseRetrySleepSeconds } else { 300 }              # If a decrease update fails, retry at this interval (5 minutes)
    $decreaseRetryMaxWaitSeconds = if ($env:ANF_DecreaseRetryMaxWaitSeconds) { [int]$env:ANF_DecreaseRetryMaxWaitSeconds } else { 3600 }      # Maximum cumulative wait to keep retrying decreases (1 hour)
    $excludeTagKey = if ($env:ANF_ExcludeTagKey) { $env:ANF_ExcludeTagKey } else { "ExcludeFromAnfQosSelfLeveling" }                          # Volumes with this tag key/value pair are excluded from automation
    $excludeTagValue = if ($env:ANF_ExcludeTagValue) { $env:ANF_ExcludeTagValue } else { "true" }                                             # Tag value match is case-insensitive

# Optional Azure Automation variable overrides (used by Deploy-in-Azure workflow)
if (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) {
    try { $tenantId = (Get-AutomationVariable -Name "ANF_TenantId" -ErrorAction Stop) } catch {}
    try { $subscriptionId = (Get-AutomationVariable -Name "ANF_SubscriptionId" -ErrorAction Stop) } catch {}
    try { $resourceGroupName = (Get-AutomationVariable -Name "ANF_ResourceGroupName" -ErrorAction Stop) } catch {}
    try { $anfAccountName = (Get-AutomationVariable -Name "ANF_AccountName" -ErrorAction Stop) } catch {}
    try { $anfPoolName = (Get-AutomationVariable -Name "ANF_PoolName" -ErrorAction Stop) } catch {}
    try { $targetPoolIncludeTagKey = (Get-AutomationVariable -Name "ANF_TargetPoolIncludeTagKey" -ErrorAction Stop) } catch {}
    try { $targetPoolIncludeTagValue = (Get-AutomationVariable -Name "ANF_TargetPoolIncludeTagValue" -ErrorAction Stop) } catch {}
    try { $testMode = (Get-AutomationVariable -Name "ANF_TestMode" -ErrorAction Stop) } catch {}
    try { $levelingAgressionPercent = [int](Get-AutomationVariable -Name "ANF_LevelingAgressionPercent" -ErrorAction Stop) } catch {}
    try { $throughputLimitMetricAllowance = [double](Get-AutomationVariable -Name "ANF_ThroughputLimitMetricAllowance" -ErrorAction Stop) } catch {}
}

# Connect to Azure
if (-not (Get-AzContext)) {
    $isAutomationHost = [bool](Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)
    if ($isAutomationHost) {
        try {
            if ($tenantId) {
                Connect-AzAccount -Identity -TenantId $tenantId | Out-Null
            } else {
                Connect-AzAccount -Identity | Out-Null
            }
        } catch {
            if ($tenantId) {
                Connect-AzAccount -TenantId $tenantId | Out-Null
            } else {
                Connect-AzAccount | Out-Null
            }
        }
    } else {
        if ($tenantId) {
            Connect-AzAccount -TenantId $tenantId | Out-Null
        } else {
            Connect-AzAccount | Out-Null
        }
    }
    Get-AzContext
}
if ($subscriptionId) {
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
}

if ($testMode -eq "Yes") {
    Write-Host "Script is running in test mode. Changes will not be made to the volumes." -ForegroundColor Green
} elseif ($testMode -eq "No") {
    Write-Host "Script is running in ***live*** mode. Changes ***will*** be made to the volumes." -ForegroundColor Yellow
} else { 
    Write-Host "Test Mode is not set to Yes or No. Exiting Script." -ForegroundColor Red
    exit
}

# Validate required ANF cmdlets are available
$requiredAnfCmdlets = @(
    "Get-AzNetAppFilesAccount",
    "Get-AzNetAppFilesPool",
    "Get-AzNetAppFilesVolume",
    "Update-AzNetAppFilesVolume"
)

$missingAnfCmdlets = @($requiredAnfCmdlets | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingAnfCmdlets.Count -gt 0) {
    try {
        Import-Module Az.NetAppFiles -ErrorAction Stop
    } catch {
        Write-Host "Failed to import Az.NetAppFiles module: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $missingAnfCmdlets = @($requiredAnfCmdlets | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
}
if ($missingAnfCmdlets.Count -gt 0) {
    throw "Required Az.NetAppFiles cmdlets are unavailable: $($missingAnfCmdlets -join ', '). Ensure Az.NetAppFiles module import has completed successfully in this Automation Account, then re-run."
}
function Invoke-FslSelfLevelingForPool {
    param(
        [Parameter(Mandatory=$true)][string]$TargetResourceGroupName,
        [Parameter(Mandatory=$true)][string]$TargetAnfAccountName,
        [Parameter(Mandatory=$true)][string]$TargetAnfPoolName
    )

Write-Host "Processing target pool: RG=$TargetResourceGroupName, Account=$TargetAnfAccountName, Pool=$TargetAnfPoolName" -ForegroundColor Cyan
# Get the Azure NetApp Files account details
$anfAccount = Get-AzNetAppFilesAccount -ResourceGroupName $TargetResourceGroupName -Name $TargetAnfAccountName
# Get the Azure NetApp Files capacity pool details
$anfPool = Get-AzNetAppFilesPool -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -Name $TargetAnfPoolName
# Get Capacity Pool QoS Type
$capacityPoolQosType = $anfPool.QosType
# Get the maximum provisioned throughput of the capacity pool in MiB/s
$capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps

function Update-FslPoolThroughputMibps {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][double]$TargetThroughputMibps
    )

    $targetRounded = [math]::Round($TargetThroughputMibps, 3)
    $context = Get-AzContext -ErrorAction Stop
    $resourceManagerUrl = $context.Environment.ResourceManagerUrl.TrimEnd('/')
    $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate(
        $context.Account,
        $context.Environment,
        $context.Tenant.Id,
        $null,
        "Never",
        $null,
        "$resourceManagerUrl/"
    ).AccessToken
    $apiVersion = "2024-07-01-preview"
    $uri = "$resourceManagerUrl$PoolResourceId" + "?api-version=$apiVersion"
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $propertyCandidates = @("provisionedThroughputMibps", "totalThroughputMibps")
    $lastError = $null
    foreach ($propertyName in $propertyCandidates) {
        try {
            $body = @{
                properties = @{
                    $propertyName = $targetRounded
                }
            } | ConvertTo-Json -Depth 3

            $null = Invoke-RestMethod -Uri $uri -Method PATCH -Body $body -Headers $headers -ErrorAction Stop
            return
        } catch {
            $lastError = $_
        }
    }

    throw "Failed to update pool throughput to $targetRounded MiB/s via REST API. Last error: $($lastError.Exception.Message)"
}
# Flexible Service Level pools must be Manual QoS
if ($capacityPoolQosType -ne "Manual") {
    Write-Host "Exiting Script - Manual QoS is required" -ForegroundColor Red
    Write-Host "Capacity Pool QoS is currently set to '$capacityPoolQosType'" -ForegroundColor Red
    Write-Host "Flexible Service Level pools and volumes require Manual QoS for this script." -ForegroundColor Red
    return
}

# Enforce minimum throughput constraints for flexible service level
if ($minimumThroughputPerVolume -lt 1) {
    Write-Host "minimumThroughputPerVolume cannot be lower than 1 MiB/s. Exiting script." -ForegroundColor Red
    return
}
if ($capacityPoolMaxThroughput -lt $minimumPoolThroughputMibps) {
    Write-Host "Capacity pool throughput is below the flexible service level minimum of $minimumPoolThroughputMibps MiB/s. Exiting script." -ForegroundColor Red
    return
}

# Get list of Volumes within Capacity Pool
$anfVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName

# Collect Info for Each Volume and calculate values
# If there are no volumes, write host message and exit
if (-not $anfVolumes) {
    Write-Host "No volumes found in Azure NetApp Files Capacity Pool `"$TargetAnfPoolName`". Skipping this pool." -ForegroundColor Red
    return
}

# Split into managed vs excluded volumes based on tag
$excludedVolumes = @()
$managedVolumes = @()
foreach ($anfVolume in $anfVolumes) {
    $isExcludedVolume = $false
    if ($anfVolume.Tags) {
        foreach ($tag in $anfVolume.Tags.GetEnumerator()) {
            if ($tag.Key -eq $excludeTagKey -and "$($tag.Value)".ToLower() -eq $excludeTagValue.ToLower()) {
                $isExcludedVolume = $true
                break
            }
        }
    }

    if ($isExcludedVolume) {
        $excludedVolumes += $anfVolume
    } else {
        $managedVolumes += $anfVolume
    }
}

if (-not $managedVolumes) {
    Write-Host "All volumes in pool `"$TargetAnfPoolName`" are excluded by tag $excludeTagKey=$excludeTagValue. Skipping this pool." -ForegroundColor Yellow
    return
}

$excludedThroughputMibps = [math]::Round(($excludedVolumes | Measure-Object -Property ActualThroughputMibps -Sum).Sum, 3)
# Excluded volume throughput remains part of total pool throughput and is reserved; only the remaining throughput is managed by this automation.
$capacityPoolManagedThroughput = [math]::Round($capacityPoolMaxThroughput - $excludedThroughputMibps, 3)
if ($capacityPoolManagedThroughput -le 0) {
    Write-Host "No managed pool throughput remains after excluded volume allocations. Exiting script." -ForegroundColor Red
    return
}
if ($excludedVolumes.Count -gt 0) {
    $excludedVolumeNames = ($excludedVolumes | ForEach-Object { $_.Name.Split('/')[2] }) -join ", "
    Write-Host "Excluded volumes by tag ($excludeTagKey=$excludeTagValue): $excludedVolumeNames" -ForegroundColor Yellow
}
Write-Host "Pool throughput accounting: Total=$capacityPoolMaxThroughput MiB/s, ExcludedAllocated=$excludedThroughputMibps MiB/s, ManagedBudget=$capacityPoolManagedThroughput MiB/s" -ForegroundColor Cyan

# Collect data for each managed volume
$volumeData = foreach ($anfVolume in $managedVolumes) {
    [PSCustomObject]@{
        ShortName = $anfVolume.Name.split('/')[2]
        VolumeId = $anfVolume.Id
        ThroughputLimitMetric = [math]::Round($((Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'throughputLimitReached' -StartTime $(get-date).AddHours(-$throughputLookBackHours) -EndTime $(get-date) -TimeGrain 00:5:00 -WarningAction SilentlyContinue | Select-Object -ExpandProperty data | Select-Object -ExpandProperty Average) | Measure-Object -average).average, 3)
        CurrentThroughputMibps = [math]::Round($anfVolume.ActualThroughputMibps, 3)
    }
}

# Ensure per-volume throughput floor can fit within managed pool throughput
if (($managedVolumes.Count * $minimumThroughputPerVolume) -gt $capacityPoolManagedThroughput) {
    Write-Host "The total minimum throughput floor across managed volumes exceeds available managed pool throughput. Adjust 'minimumThroughputPerVolume' lower. Exiting script." -ForegroundColor Red
    return
}

# Calculate unallocated managed throughput budget
$totalCurrentThroughputMibps = [math]::Round(($volumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum, 3)
$unallocatedThroughputMibps = [math]::Round($capacityPoolManagedThroughput - $totalCurrentThroughputMibps, 3)


####Injecting Fake Test Data ###### Update the ThroughputLimitMetric value for each volume
#$volumeData[0].ThroughputLimitMetric = 0  # Vol1
#$volumeData[1].ThroughputLimitMetric = 5  # Vol2
#$volumeData[2].ThroughputLimitMetric = 15  # Vol3


# Calculate total throughput allocated to all volumes
$totalThroughput = [math]::Round(($volumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum, 3)

# Add the "unallocated" row
$unallocatedRow = [PSCustomObject]@{
    ShortName = "unallocated"
    VolumeId = ""
    CurrentThroughputMibps = $unallocatedThroughputMibps
    ThroughputLimitMetric = 0.00
}

# Combine volume data with the unallocated row
$finalData = $volumeData + $unallocatedRow

# Add the property NewThroughputValue to each object
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name NewThroughputValue -Value 0 -Force
    $_
}

# Add throughputPercentage to each object in the finalData array
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name throughputPercentage -Value 0 -Force
    $_
}

# Add the property Performant to each object
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "" -Force
    } elseif ($_.ThroughputLimitMetric -le $throughputLimitMetricAllowance) {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "Yes" -Force
    } else {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "No" -Force
    }
    $_
}

# Add the property CleanLast3FullDays to each object
# Uses the last 3 full 24-hour periods anchored to script runtime:
# [now-72h, now-48h], [now-48h, now-24h], [now-24h, now]
$windowAnchorEnd = Get-Date
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name CleanLast3FullDays -Value $true -Force
    } else {
        $isCleanLast3FullDays = $true
        for ($dayOffset = 3; $dayOffset -ge 1; $dayOffset--) {
            $windowStart = $windowAnchorEnd.AddHours(-24 * $dayOffset)
            $windowEnd = $windowAnchorEnd.AddHours(-24 * ($dayOffset - 1))
            $windowMetricValues = Get-AzMetric -ResourceId $_.VolumeId -MetricName 'throughputLimitReached' -StartTime $windowStart -EndTime $windowEnd -TimeGrain 01:00:00 -WarningAction SilentlyContinue |
                Select-Object -ExpandProperty Data |
                Select-Object -ExpandProperty Average |
                Where-Object { $null -ne $_ }

            if (-not $windowMetricValues) {
                $isCleanLast3FullDays = $false
                break
            }

            $windowMetricMax = [double](($windowMetricValues | Measure-Object -Maximum).Maximum)
            if ($windowMetricMax -gt $throughputLimitMetricAllowance) {
                $isCleanLast3FullDays = $false
                break
            }
        }
        $_ | Add-Member -MemberType NoteProperty -Name CleanLast3FullDays -Value $isCleanLast3FullDays -Force
    }
    $_
}

# Set $allVolumesNonPerformant to true if all volumes except unallocated are non-performant
$nonPerformantVolumes = $finalData | Where-Object { $_.Performant -eq "No" -and $_.ShortName -ne "unallocated" } | Measure-Object
$performantVolumes = $finalData | Where-Object { $_.Performant -eq "Yes" -and $_.ShortName -ne "unallocated" } | Measure-Object
$totalVolumeQty = $managedVolumes.Count

# For each volume calculate the amount of space it can give up, if any, and add it as a property called "SpaceToGiveUp"
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = $_.CurrentThroughputMibps
    } elseif ($_.Performant -eq "Yes" -and $_.CurrentThroughputMibps -gt 1) {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = [math]::Round(
            [math]::Min(
                ($_.CurrentThroughputMibps * $levelingAgressionPercent / 100),
                ($_.CurrentThroughputMibps - $minimumThroughputPerVolume)
            ), 
            3
        )
    } elseif ($nonPerformantVolumes.Count -eq $totalVolumeQty) {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = [math]::Round(
            [math]::Min(
                ($_.CurrentThroughputMibps * $levelingAgressionPercent / 100),
                ($_.CurrentThroughputMibps - $minimumThroughputPerVolume)
            ), 
            3
        )
    }
    $_
}

$totalVolumeQty = $managedVolumes.Count
$capacityPoolMaxThroughput = $capacityPoolManagedThroughput
$totalminimumThroughputAllocated = [math]::Round($totalVolumeQty * $minimumThroughputPerVolume, 3)
$totalAvailableSpaceToGiveUp = [math]::Round(($finalData | Measure-Object -Property SpaceToGiveUp -Sum).Sum, 3)
$capacityPoolRemainingThroughputToAllocate = [math]::Round($capacityPoolMaxThroughput - $totalAvailableSpaceToGiveUp, 3)
$totalThroughputLimitMetric = [math]::Round(($finalData | Measure-Object -Property ThroughputLimitMetric -Sum).Sum, 3)
if ($totalThroughputLimitMetric -eq 0) {
    Write-Host "No Throughput Limit Reached Metrics found for any volume. No re-allocations will be performed" -ForegroundColor Green
    return
}

# Calculate the percentage of TotalThroughput for each volume and if total throughput limits reached is less than $throughputLimitMetricAllowance
$finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_.throughputPercentage = 0.00
    } else {
        $_.throughputPercentage = [math]::Round(($_.ThroughputLimitMetric / $totalThroughputLimitMetric) * 100, 3)
    }
}

# Apply percentage to throughput for each volume
$finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated") {
        if ($_.Performant -eq "Yes" -and $_.CurrentThroughputMibps -lt 1) {
            $_.NewThroughputValue = 1
        } else {
            $_.NewThroughputValue = [math]::Round(($_.CurrentThroughputMibps - $_.SpaceToGiveUp) + ($totalAvailableSpaceToGiveUp * $_.throughputPercentage / 100), 3)
        }
    } elseif ($nonPerformantVolumes.Count -eq $totalVolumeQty) {
        $_.NewThroughputValue = [math]::Round(($_.CurrentThroughputMibps - $_.SpaceToGiveUp) + ($totalAvailableSpaceToGiveUp * $_.throughputPercentage / 100), 3)
    } else {
        $_.NewThroughputValue = 0
    }
}

# Add NetChangeInThroughputMibs to each object
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name NetChangeInThroughputMibs -Value 0 -Force
    $_
}

# Calculate NetChangeInThroughputMibs for each object as the net change from the current throughput
$finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated") {
        $_.NetChangeInThroughputMibs = [math]::Round($_.NewThroughputValue - $_.CurrentThroughputMibps, 3)
    } else {
        $_.NetChangeInThroughputMibs = 0
    }
}

# Prevent throughput decreases unless the last 3 full 24-hour periods were clean
$finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -lt 0 -and -not $_.CleanLast3FullDays) {
        $_.NewThroughputValue = $_.CurrentThroughputMibps
        $_.NetChangeInThroughputMibs = 0
    }
}

# Calculate planned managed target throughput and resulting pool target throughput
$plannedManagedTargetThroughputMibps = [math]::Round((($finalData | Where-Object { $_.ShortName -ne "unallocated" } | Measure-Object -Property NewThroughputValue -Sum).Sum), 3)
$plannedPoolTargetThroughputMibps = [math]::Round(($excludedThroughputMibps + $plannedManagedTargetThroughputMibps), 3)
if ($plannedPoolTargetThroughputMibps -lt $minimumPoolThroughputMibps) {
    $plannedPoolTargetThroughputMibps = $minimumPoolThroughputMibps
}
$poolThroughputDeltaMibps = [math]::Round(($plannedPoolTargetThroughputMibps - $capacityPoolMaxThroughput), 3)
Write-Host "Planned pool throughput target: Current=$capacityPoolMaxThroughput MiB/s, Target=$plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Cyan

# Sort the data to ensure decreases happen first
$finalData = $finalData | Sort-Object -Property NetChangeInThroughputMibs

# If all volumes aside from unallocated are not performant, issue warning
if (($finalData | Where-Object { $_.Performant -eq "No" -and $_.ShortName -ne "unallocated" } | Measure-Object).Count -eq $finalData.Count - 1) {
    Write-Host "***WARNING: All volumes are non-performant. Consider adding throughput capacity to the capacity pool.***" -ForegroundColor Red
    $finalData | Format-Table -AutoSize
    return
}

# If there are no volume or pool throughput changes needed, write a host message and exit. Otherwise, run the rest of the code below.
if ((($finalData | Where-Object { $_.NetChangeInThroughputMibs -ne 0 } | Measure-Object).Count -eq 0) -and ($poolThroughputDeltaMibps -eq 0)) {
    Write-Host "All volumes are already at the correct throughput value. Exiting script." -ForegroundColor Green
    $finalData | Format-Table -AutoSize
    return
} else {
    # If $testMode is "No", update the volume settings in Azure with the new throughput values. Otherwise, display the table.
    if ($testMode -eq "No") {
        # Update the volumes with the new throughput values.
        # Apply decreases first, then increases, to maximize available headroom during updates.
        $finalData | Format-Table -AutoSize
        $poolIncreaseNeeded = $plannedPoolTargetThroughputMibps -gt $capacityPoolMaxThroughput
        $poolDecreaseNeeded = $plannedPoolTargetThroughputMibps -lt $capacityPoolMaxThroughput

        if ($poolIncreaseNeeded) {
            Write-Host "Increasing pool throughput before volume updates: $capacityPoolMaxThroughput -> $plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Yellow
            Update-FslPoolThroughputMibps -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
            $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
            $capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps
        }

        $hadVolumeUpdateFailure = $false
        $orderedUpdates = @()
        $orderedUpdates += ($finalData | Where-Object { $_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -lt 0 })
        $orderedUpdates += ($finalData | Where-Object { $_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -gt 0 })
        $orderedUpdates | ForEach-Object {
            if ($_.ShortName -ne "unallocated") {
                Write-Host "Updating volume `"$($_.ShortName)`" with new throughput value of `"$($_.NewThroughputValue)`" MiB/s" -ForegroundColor Yellow
                $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName -Name $_.ShortName
                $isDecrease = $_.NewThroughputValue -lt $_.CurrentThroughputMibps
                if (-not $isDecrease) {
                    $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $_.NewThroughputValue -ErrorAction Stop > $null
                } else {
                    $retryElapsedSeconds = 0
                    $decreaseUpdateSucceeded = $false
                    while (-not $decreaseUpdateSucceeded) {
                        try {
                            $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $_.NewThroughputValue -ErrorAction Stop > $null
                            $decreaseUpdateSucceeded = $true
                        } catch {
                            if ($retryElapsedSeconds -ge $decreaseRetryMaxWaitSeconds) {
                                Write-Host "Decrease update still blocked for volume `"$($_.ShortName)`" after waiting $retryElapsedSeconds seconds. Skipping this decrease for now." -ForegroundColor Yellow
                                $hadVolumeUpdateFailure = $true
                                break
                            }
                            Write-Host "Decrease update blocked for volume `"$($_.ShortName)`". Retrying in $decreaseRetrySleepSeconds seconds (elapsed: $retryElapsedSeconds sec)." -ForegroundColor Yellow
                            Start-Sleep -Seconds $decreaseRetrySleepSeconds
                            $retryElapsedSeconds += $decreaseRetrySleepSeconds
                            $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName -Name $_.ShortName
                        }
                    }
                }
            }
        }

        if ($poolDecreaseNeeded) {
            if ($hadVolumeUpdateFailure) {
                Write-Host "Skipping pool throughput decrease because one or more volume updates did not complete successfully." -ForegroundColor Yellow
            } else {
                Write-Host "Decreasing pool throughput after volume updates: $capacityPoolMaxThroughput -> $plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Yellow
                Update-FslPoolThroughputMibps -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
                $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -Name $TargetAnfPoolName
                $capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps
            }
        }
    } else {
        if ($poolThroughputDeltaMibps -gt 0) {
            Write-Host "TEST MODE: Pool throughput would be increased to $plannedPoolTargetThroughputMibps MiB/s before volume updates." -ForegroundColor Yellow
        } elseif ($poolThroughputDeltaMibps -lt 0) {
            Write-Host "TEST MODE: Pool throughput would be decreased to $plannedPoolTargetThroughputMibps MiB/s after volume updates." -ForegroundColor Yellow
        }
        $finalData | Format-Table -AutoSize
    }
}
}

$targetPools = @()
$candidatePools = Get-AzResource -ResourceType "Microsoft.NetApp/netAppAccounts/capacityPools" -TagName $targetPoolIncludeTagKey -ErrorAction SilentlyContinue
foreach ($candidatePool in $candidatePools) {
    $candidateTagValue = $null
    if ($candidatePool.Tags -and $candidatePool.Tags.ContainsKey($targetPoolIncludeTagKey)) {
        $candidateTagValue = "$($candidatePool.Tags[$targetPoolIncludeTagKey])"
    }
    if ($candidateTagValue -and $candidateTagValue.ToLower() -eq $targetPoolIncludeTagValue.ToLower()) {
        $idToParse = if ($candidatePool.ResourceId) { $candidatePool.ResourceId } else { $candidatePool.Id }
        if ($idToParse -match "/resourceGroups/([^/]+)/providers/Microsoft.NetApp/netAppAccounts/([^/]+)/capacityPools/([^/]+)$") {
            $targetPools += [PSCustomObject]@{
                ResourceGroupName = $Matches[1]
                AccountName = $Matches[2]
                PoolName = $Matches[3]
            }
        }
    }
}

if ($targetPools.Count -eq 0 -and
    $resourceGroupName -and
    $anfAccountName -and
    $anfPoolName) {
    Write-Host "No tagged pools found. Falling back to configured single target: $resourceGroupName / $anfAccountName / $anfPoolName" -ForegroundColor Yellow
    $targetPools += [PSCustomObject]@{
        ResourceGroupName = $resourceGroupName
        AccountName = $anfAccountName
        PoolName = $anfPoolName
    }
}

if ($targetPools.Count -eq 0) {
    Write-Host "No target pools found. Tag capacity pools with $targetPoolIncludeTagKey=$targetPoolIncludeTagValue to include them." -ForegroundColor Yellow
    exit
}

$failedPools = @()
foreach ($targetPool in $targetPools) {
    try {
        Invoke-FslSelfLevelingForPool -TargetResourceGroupName $targetPool.ResourceGroupName -TargetAnfAccountName $targetPool.AccountName -TargetAnfPoolName $targetPool.PoolName
    } catch {
        $failedPools += "$($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName): $($_.Exception.Message)"
        Write-Host "Failed processing pool $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($failedPools.Count -gt 0) {
    throw "One or more target pools failed processing:`n$($failedPools -join "`n")"
}
