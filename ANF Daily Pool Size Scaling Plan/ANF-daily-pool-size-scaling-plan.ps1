<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************

Last Edit Date: 11/15/2024
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose: Scale the size of a capacity pool and the allocated throughput for volumes based on the time of day. This script is designed to be run as an Azure Automation Runbook.
Assigns QoS throughput to volumes evenly, based on the number of volumes in the pool.

WARNING: This script is only designed to work with Manual QoS Pools. It will convert Auto QoS to Manual if needed.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# User Editable Variables:
$tenantId =                 "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"                  # Tenant ID for the Azure subscription
$weekDays =                 "Monday", "Tuesday", "Wednesday", "Thursday", "Friday"  # Days of the week that are considered weekdays
$weekendDays =              "Saturday", "Sunday"                                    # Days of the week that are considered weekend days
$dayStartTime =             "08:30"
$dayEndTime =               "18:30"
$timeZone =                 "Central Standard Time"                                 # Time zone for the script
$resourceGroupName =        "example-rg"                                            # Resource group name where the Azure NetApp Files resources are located
$anfAccountName =           "example-anfAcct"                                       # Azure NetApp Files account name
$anfPoolName =              "example-anfPool"                                       # Name of the currently used pool for the initial run of this script, if the current pool name is NOT either the $weekendPoolName or $weekdayPoolName
$offHoursTiBs =             1                                                       # TiB for off hours
$onHoursTiBs =              2                                                       # TiB for on hours
$MiBsperTiB =               128                                                     # MiB/s per TiB (*set to 16 for Standard, 64 for Premium, 128 for Ultra)


#variable conversions
    $offHoursMiBs = $offHoursTiBs * $MiBsperTiB
    $onHoursMiBs = $onHoursTiBs * $MiBsperTiB
    $offHoursKiBs = $offHoursTiBs  * 1024 * 1024 * 1024 * 1024 
    $onHoursKiBs = $onHoursTiBs  * 1024 * 1024 * 1024 * 1024


# Get the current date and time
    $currentDateTime = Get-Date
    $timeZoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($timeZone)
    $timeZoneDateTime = [System.TimeZoneInfo]::ConvertTime($currentDateTime, $timeZoneInfo)
    $currentDay = $timeZoneDateTime.ToString("dddd")
    $currentTime = $timeZoneDateTime.ToString("HH:mm")

    if (-not (Get-AzContext)) {
        Connect-AzAccount -TenantId $tenantId
        Get-AzContext
    }

# Clear variables
    $volumeList = $null

# Get all volumes in the account
    $volumeList = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction SilentlyContinue

# Calculate throughput allocation for each volume
    $offHoursMiBsperVolume = $offHoursMiBs / $volumeList.Count
    $onHoursMiBsperVolume = $onHoursMiBs / $volumeList.Count

# Get Capacity Pool QoS Type
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
    $capacityPoolQosType = $anfPool.QosType
# If QoS is Auto, convert the Capacity Pool to Manual
    if ($capacityPoolQosType -eq "Auto") {
        Write-Host "Converting Capacity Pool QoS to Manual" -ForegroundColor Yellow
        $anfPool | Update-AzNetAppFilesPool -QosType Manual > $null
        $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
        Write-Host "Capacity Pool QoS converted to Manual" -ForegroundColor Green
    }   

# If after hours or weekend
    if ($weekendDays -contains $currentDay -or $weekDays -notcontains $currentDay -or $currentTime -lt $dayStartTime -or $currentTime -ge $dayEndTime) {
        Write-Host "After hours or weekend"
            #Set volume throughput allocation
            foreach ($volume in $volumeList) {
            Update-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -Location $volume.Location -AccountName $anfAccountName -PoolName $anfPoolName -Name $volume.CreationToken -ServiceLevel $volume.ServiceLevel -ThroughputMibps $offHoursMiBsperVolume > $null
        }
        # Set Pool Size
        Update-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -PoolSize $offHoursKiBs > $null

    } else {
        Write-Host "During business hours"
            #Set Pool Size
            Update-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -Location $anfPool.Location -AccountName $anfAccountName -Name $anfPoolName -PoolSize $onHoursKiBs > $null
            #Set volume throughput allocation
            foreach ($volume in $volumeList) {
                Update-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -Location $volume.Location -AccountName $anfAccountName -PoolName $anfPoolName -Name $volume.CreationToken -ServiceLevel $volume.ServiceLevel -ThroughputMibps $onHoursMiBsperVolume > $null
            }
    }
