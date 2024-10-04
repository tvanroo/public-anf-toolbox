<#SUMMARY

*********************** WARNING: UNSUPPORTED AND UNTESTED SCRIPT. USE AT YOUR OWN RISK. ************************

Lat Edit Date: 10/04/2024
Latest Version found at: https://github.com/tvanroo/public-anf-toolbox/blob/main/ANF%20QoS/ANF-QoS-Autoscale-Manual.ps1
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com


Script Purpose: This script automates the allocation of Throughput MiBs/Sec to Azure NetApp Files volumes based on their historical performance metrics. Several variables allow for the behavior to be customized.

The script looks back at historical throughput usage metrics for each volume over a defined time period. Then it calculates the proportion of throughput each volume should be assigned, allocating all available throughput in the pool.
The script can reserve a percentage of the Capacity Pool's total throughput to be evenly divided among all volumes, allowing for a floor for performance. This is useful for ensuring that all volumes have a minimum level of performance, even if they have not used their full allocation in the past.
The script can be set to simply mimic the native Auto behavior of ANF, where throughput is allocated based on volume size only. This is useful so that ANF administrators can revert back to a "set it and forget it" method after switching to manual QoS allocation. This mode has another benefit in that the total throughput of the pool is allocated, meaning unallocated space won't also mean unallocated throughput.
The script can also be configured to convert Auto QoS pools to Manual with a simple variable flag.
With minor changes and the creation of a Service Principal, the script can be run as an Azure Automation Script on a recurring schedule to maintain the performance of the ANF volumes on an ongoing basis.

Prerequisites:
1. Define Azure Tenant ID, Resource Group Name, ANF Account Name, and ANF Pool Name.
2. Install the Az and Az.NetAppFiles modules.

Variables:
1. $tenantId: The Azure Tenant ID for the subscription.
2. $resourceGroupName: The resource group name where the Azure NetApp Files resources are located.
3. $anfAccountName: The Azure NetApp Files account name.
4. $anfPoolName: The Azure NetApp Files capacity pool name.
5. $convertToManualFlag: A flag to determine whether to convert the capacity pool QoS to Manual.
    Note: If Capacity Pool QoS type ($cap_pool_qos_type) = Auto and this Flag ($convertToManualFlag) is set to $False, the script will fail rather than convert the Capacity Pool to manual.
6. $mimicAuto: A flag to override throughput metrics and allocate only based on volume size (mimic Auto Behavior). E.g. Volume throughput is proportionally allocated based on Volume Size.
    Note: Unlike the "Auto" mode of ANF, the total Throughput of the ANF Capacity Pool will be allocated, meaning unallocated space won't also mean unallocated throughput. (I.e. Performance is better this way than the standard Auto mode in Azure Portal)
7. $throughputLookBackHours: The look-back period in hours for throughput metrics. The script allocates throughput based on historical performance metrics, and this variable defines how far back the metric is used for an average.
8. $qos_equality_percent: This script can be configured to reserve a percent of the Capacity Pool's total throughput to be evenly divided to all volumes, allowing for a floor for performance. On a pool with 16MiB/s of throughput and 2 volumes, setting this variable to 10 would take 1.6 MiB/s and evenly divide it between each volume, then proportionally allocate the remaining throughput as usual.
    Note:   If $mimicAuto is set to $True, this variable is ignored and the script will allocate throughput based on volume size only, not considering either the $qos_equality_percent nor the historical performance metrics.
            If $qos_equality_percent is set to 0, the script will allocate throughput based on historical performance metrics only, not considering the $qos_equality_percent. It is possible this script could try to assign 0 throughput to a volume which is an untested scenario.
            If $qos_equality_percent is set to 100, the script will allocate throughput based on volume quantity, not considering the historical performance metrics or the volume sizes. E.g. each volume gets an equal share of the total throughput regardless of historical performance metrics or volume size.
            If $qos_equality_percent is set to a value between 0 and 100, the script will allocate throughput based on historical performance metrics and the $qos_equality_percent.

Additional Notes:
If historical metrics are not available, the script will allocate throughput based on volume size only while still respecting the $qos_equality_percent. To avoid dividing by zero, the script switches to using volume Size rather than historical performance metrics for determining the percent of throughput each volume is assigned.

To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. Connect-AzAccount needs additional parameters for an Automation Account. Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".


#>
# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# Define variables if not provided as parameters
    # Tenant ID for the Azure subscription
    $tenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    # Resource group name where the Azure NetApp Files resources are located
    $resourceGroupName = "example-rg"
    # Azure NetApp Files account name
    $anfAccountName = "example-anf-account"
    # Azure NetApp Files capacity pool name
    $anfPoolName = "example-capacity-pool"
    # Flag to determine whether to convert the capacity pool QoS to Manual
    $convertToManualFlag = $False
    # Flag to override throughput metrics and allocate only based on volume size (mimic Auto Behavior)
    $mimicAuto = $False
    # Look-back period in hours for throughput metrics
    $throughputLookBackHours = 168
    # Percentage of total throughput to be allocated equally among volumes
    $qos_equality_percent = 15


# Connect to az tenant by id if not  connected
    if (-not (Get-AzContext)) {
        Connect-AzAccount -TenantId $tenantId
        Get-AzContext
    }

    
# Gather various ANF Capacity Pool and Volume data
    # Override the QoS_Equality_Percent if the minicAuto flag is set to True
    if ($mimicAuto -eq $True) {
        $qos_equality_percent = 0
    }

    # Get the Azure NetApp Files account details
    $anfAccount = Get-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName
    # Get the Azure NetApp Files capacity pool details
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
    #If ANF Pool does not exist, write host message and exit
    if (-not $anfPool) {
        Write-Host "Azure NetApp Files Capacity Pool `"$anfPoolName`" does not exist. Exiting script." -ForegroundColor Red
        exit
    } 
    #Get Capicity Pool QoS Type
    $cap_pool_qos_type = $anfPool.QosType
    #If QoS type is not "Manual, set it to Manual
    if ($convertToManualFlag -eq $True) {
        if ($cap_pool_qos_type -ne "Manual") {
            Write-Host "Converting Capacity Pool `"$anfPoolName`" QoS type to Manual" -ForegroundColor Yellow
            $anfPool | Set-AzNetAppFilesPool -QosType Manual
        }
    }
    # Get the maximum provisioned throughput of the capacity pool in MiB/s
    $cap_pool_max_throughput = $anfPool.TotalThroughputMibps
    # Get the current QoS type of the capacity pool (e.g., Auto, Manual)
    $cap_pool_current_qos_type = $anfPool.QosType
    #if QoS type is not "Manual, write host message and exit
    if ($cap_pool_current_qos_type -ne "Manual") {
        Write-Host "Capacity Pool `"$anfPoolName`" QoS type is not Manual. Exiting script." -ForegroundColor Red
        exit
    }



    # Get the currently utilized throughput of the capacity pool in MiB/s
    $cap_pool_current_throughput = $anfPool.UtilizedThroughputMibps
    # Get list of Volumes within Capacity Pool
    $anfVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
# Collect Info for Each Volume and calculate values
    # If there are no volumes, write host message and exit
    if (-not $anfVolumes) {
        Write-Host "No volumes found in Azure NetApp Files Capacity Pool `"$anfPoolName`". Exiting script." -ForegroundColor Red
        exit
    }
    # Collect data for each volume
    $volumeData = foreach ($anfVolume in $anfVolumes) {
        [PSCustomObject]@{
            ShortName = $anfVolume.Name.split('/')[2]
            SizeGiB = $anfVolume.UsageThreshold / 1024 / 1024 / 1024
            TotalThroughput = [math]::Round($((Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'TotalThroughput' -StartTime $(get-date).AddHours(-$throughputLookBackHours) -EndTime $(get-date) -TimeGrain 00:5:00 -WarningAction SilentlyContinue | Select-Object -ExpandProperty data | Select-Object -ExpandProperty Average) | Measure-Object -average).average, 2)
            ActualThroughputMibps = $anfVolume.ActualThroughputMibps
        }
    }
    # Calculate total throughput of all volumes
    $totalThroughput = ($volumeData | Measure-Object -Property TotalThroughput -Sum).Sum
    # Calculate total size and throughput of all volumes
    $totalSizeGiB = ($volumeData | Measure-Object -Property SizeGiB -Sum).Sum
    $totalActualThroughputMibps = ($volumeData | Measure-Object -Property ActualThroughputMibps -Sum).Sum
    # Calculate unallocated size and throughput
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    $unallocatedSizeGiB = $anfPool.Size / 1024 / 1024 / 1024 - $totalSizeGiB
    $unallocatedThroughputMibps = $cap_pool_max_throughput - $totalActualThroughputMibps
    # Add the "unallocated" row
    $unallocatedRow = [PSCustomObject]@{
        ShortName = "unallocated"
        SizeGiB = $unallocatedSizeGiB
        TotalThroughput = 0
        ActualThroughputMibps = $unallocatedThroughputMibps
        perfPercent = 0
    }
    # Combine volume data with the unallocated row
    $finalData = $volumeData + $unallocatedRow
    # Ensure the perfPercent property exists on each object
    $finalData = $finalData | ForEach-Object {
        $_ | Add-Member -MemberType NoteProperty -Name perfPercent -Value 0 -Force
        $_
    }
# Calculate the percentage of TotalThroughput for each volume and if total throughput is 0, use the SizeGiB to calculate the percentage
$finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_.perfPercent = 0
    } elseif ($totalThroughput -eq 0 -or $mimicAuto -eq $True) {
        $_.perfPercent = [math]::Round(($_.SizeGiB / $totalSizeGiB) * 100, 2)
    } else {
        $_.perfPercent = [math]::Round(($_.TotalThroughput / $totalThroughput) * 100, 2)
    }
}

# Format the collected data into a table
    $finalData | Format-Table -AutoSize

#Calculate New Throughput Value for each Volume
    # Calculate equality percentage
    $equality_Mibs = [math]::Round(($cap_pool_max_throughput * ($qos_equality_percent / 100)), 2)

    $qos_total_throughput_for_allocation = [math]::Round(($cap_pool_max_throughput - $equality_Mibs), 2)

# Calculate equality MiBs per volume or set to 0 if $mimicAuto is $True
if ($mimicAuto -eq $True) {
    $equality_mibs_per_vol = 0
} else {
    $equality_mibs_per_vol = [math]::Round(($equality_Mibs / ($finalData.Count - 1)), 2)  # Exclude "unallocated" row
}

# Calculate the NewThroughputValue for each volume
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated") {
        if ($mimicAuto -eq $True) {
            $newThroughputValue = [math]::Round((($_.SizeGiB / $totalSizeGiB) * $cap_pool_max_throughput), 2)
        } else {
            $newThroughputValue = [math]::Round((($equality_mibs_per_vol) + ($_.perfPercent / 100) * $qos_total_throughput_for_allocation), 2)
        }
    } else {
        $newThroughputValue = 0
    }
    $_ | Add-Member -MemberType NoteProperty -Name NewThroughputValue -Value $newThroughputValue -Force
    $_
}
# Sort the data to ensure decreases happen first
$finalData = $finalData | Sort-Object { $_.NewThroughputValue - $_.ActualThroughputMibps }

# Format the collected data into a table
$finalData | Format-Table -AutoSize

# Update the volumes with the new throughput values
foreach ($volume in $finalData) {
    if ($volume.ShortName -ne "unallocated") {
        Write-Host "Updating volume `"$($volume.ShortName)`" with new throughput value $($volume.NewThroughputValue) MiB/s" -ForegroundColor Yellow
        $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volume.ShortName
        $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $volume.NewThroughputValue
    }
}

