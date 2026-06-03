<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 10/25/2024
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script automates weekend scaling to save costs on Azure NetApp Files volumes. 
It moves volumes between pools based on the day of the week and time of day.

Note: Lowering the service level of a volume cannot happen within 24 hours of a previous increase in service level.

WARNING: THis script is only designed to work with Auto QoS Pools. It will not work with manual QoS pools.

Even with Cool Access already enabled, further savings are achieved with this script. 
Setting a weekend range from 6 PM Friday to 6 AM Monday will reduce the cost of your active data to the lower tier for 35% of the week.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# User Editable Variables:
$tenantId =                 "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Tenant ID for the Azure subscription
$weekendStartDay =          "Friday"                                # Day of the week the weekend starts, must not exist in $weekendfullDays
$weekendStartTime =         "18:00"
$weekendfullDays =          "Saturday", "Sunday"                    # Days of the week that are considered full weekend days, must be sequential and in between $weekendStartDay and $weekendEndDay
$weekendEndDay =            "Monday"                                # Day of the week the weekend ends, must not exist in $weekendfullDays. Must be 24+ hours after $weekendStartDay and time
$weekendEndTime =           "06:00"
$weekdayServiceLevel =      "Ultra"                                 # "Standard" or "Premium" or "Ultra"
$weekendServiceLevel =      "Standard"                              # "Standard" or "Premium" or "Ultra"
$resourceGroupName =        "example-rg"                            # Resource group name where the Azure NetApp Files resources are located
$anfAccountName =           "example-anf-acct"                      # Azure NetApp Files account name
$initialanfPoolName =       "example-anf-pool"                      # Name of the currently used pool for the initial run of this script, if the current pool name is NOT either the $weekendPoolName or $weekdayPoolName
$weekendPoolName =          "example-anf-pool-weekend"              # Azure NetApp Files capacity pool name
$weekdayPoolName =          "example-anf-pool-weekday"              # Azure NetApp Files capacity pool name
$testMode =                 "Yes"                                   # Test Mode Selector: "Yes", "No"  Yes lists actions, No makes changes

# Begin Script
$currentDay =               Get-Date -Format "dddd"
$currentTime =              Get-Date -Format "HH:mm"

# Used for manually setting date/time for easier testing operations
# $currentDay = "Friday"
# $currentTime = "05:00"
# $currentDay
# $currentTime

if (-not (Get-AzContext)) {
    Connect-AzAccount -TenantId $tenantId
    Get-AzContext
}

if ($testMode -eq "Yes") {
    Write-Host "Script is running in test mode. Pool create, volume move, and pool delete actions will not be performed." -ForegroundColor Green
} elseif ($testMode -eq "No") {
    Write-Host "Script is running in ***live*** mode. Pool create, volume move, and pool delete actions ***will*** be performed." -ForegroundColor Yellow
} else {
    Write-Host "Test Mode is not set to Yes or No. Exiting Script." -ForegroundColor Red
    exit
}

function New-ScalingPool {
    param(
        [Parameter(Mandatory = $true)]$PoolSpec,
        [Parameter(Mandatory = $true)][string]$TargetPoolName
    )

    if ($testMode -eq "Yes") {
        Write-Host "TEST MODE: Would create pool $TargetPoolName with service level $($PoolSpec.ServiceLevel) and size $($PoolSpec.Size)" -ForegroundColor Yellow
        return [PSCustomObject]@{
            Id = "test-mode:$TargetPoolName"
            PoolId = "test-mode:$TargetPoolName"
            Name = $TargetPoolName
        }
    }

    if ($PoolSpec.CoolAccess -eq $True) {
        Write-Host "Creating a new pool with Cool Access"
        $null = New-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -Location $PoolSpec.Location -AccountName $anfAccountName -Name $TargetPoolName -PoolSize $PoolSpec.Size -ServiceLevel $PoolSpec.ServiceLevel -QosType $PoolSpec.QosType -CoolAccess -EncryptionType $PoolSpec.EncryptionType -Tag $PoolSpec.Tags
    } else {
        Write-Host "Creating a new pool without Cool Access"
        $null = New-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -Location $PoolSpec.Location -AccountName $anfAccountName -Name $TargetPoolName -PoolSize $PoolSpec.Size -ServiceLevel $PoolSpec.ServiceLevel -QosType $PoolSpec.QosType -EncryptionType $PoolSpec.EncryptionType -Tag $PoolSpec.Tags
    }

    return Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $TargetPoolName
}

function Move-ScalingVolumes {
    param(
        [Parameter(Mandatory = $true)]$Volumes,
        [Parameter(Mandatory = $true)][string]$CurrentPoolName,
        [Parameter(Mandatory = $true)]$TargetPool,
        [Parameter(Mandatory = $true)][string]$TargetPoolLabel
    )

    foreach ($volume in $Volumes) {
        Write-Host "Moving volume $($volume.CreationToken) to the $TargetPoolLabel."
        if ($testMode -eq "Yes") {
            Write-Host "TEST MODE: Would move volume $($volume.CreationToken) from $CurrentPoolName to $($TargetPool.Name)" -ForegroundColor Yellow
        } else {
            Set-AzNetAppFilesVolumePool -ResourceGroupName $volume.ResourceGroupName -AccountName $anfAccountName -PoolName $CurrentPoolName -Name $volume.CreationToken -NewPoolResourceId $TargetPool.Id
        }
    }
}

function Remove-ScalingPool {
    param(
        [Parameter(Mandatory = $true)][string]$PoolName
    )

    if ($testMode -eq "Yes") {
        Write-Host "TEST MODE: Would remove pool $PoolName" -ForegroundColor Yellow
    } else {
        Remove-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $PoolName
    }
}

# Clear variables
$InitialVolumeList = $null
$weekendVolumeList = $null
$weekdayVolumeList = $null

# Get all volumes in the account
$InitialVolumeList = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialanfPoolName -ErrorAction SilentlyContinue
$weekendVolumeList = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekendPoolName -ErrorAction SilentlyContinue
$weekdayVolumeList = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekdayPoolName -ErrorAction SilentlyContinue

# Count the number of valid volume lists
$validVolumeLists = 0
if ($InitialVolumeList) { $validVolumeLists++ }
if ($weekendVolumeList) { $validVolumeLists++ }
if ($weekdayVolumeList) { $validVolumeLists++ }

# Check each variable for valid results
if ($validVolumeLists -eq 1) {
    Write-Host "Only one volume list is valid."
    if ($InitialVolumeList) {
        Write-Host "Importing your initial volume list."
        if (($currentDay -eq $weekendStartDay -and $currentTime -ge $weekendStartTime) -or ($weekendfullDays -contains $currentDay) -or ($currentDay -eq $weekendEndDay -and $currentTime -le $weekendEndTime)) {
            Write-Host "It is the weekend!"
            # Get $initialanfPoolName settings
            $initialPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialanfPoolName
            
            # Update $initialPool to the $weekendServiceLevel
            $weekendPool = $initialPool
            $weekendPool.ServiceLevel = $weekendServiceLevel
            $weekendPool.Name = $weekendPoolName

            # Create the new weekend pool replicating settings in the $initialPool
            $weekendPool = New-ScalingPool -PoolSpec $weekendPool -TargetPoolName $weekendPoolName
            $weekendPool.PoolId

            # Get the volumes in the initial pool
            $initialVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialanfPoolName

            # Move the volumes to the weekend pool
            Move-ScalingVolumes -Volumes $initialVolumes -CurrentPoolName $initialanfPoolName -TargetPool $weekendPool -TargetPoolLabel "weekend pool"

            Remove-ScalingPool -PoolName $initialanfPoolName

        } else {
            Write-Host "It is not the weekend."
            # Get volumes in the weekday pool
            $initialPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialanfPoolName

            # Update $initialPool to the $weekdayServiceLevel
            $weekdayPool = $initialPool
            $weekdayPool.ServiceLevel = $weekdayServiceLevel
            $weekdayPool.Name = $weekdayPoolName

            # Create the new weekday pool replicating settings in the $initialPool
            $weekdayPool = New-ScalingPool -PoolSpec $weekdayPool -TargetPoolName $weekdayPoolName
            $weekdayPool.PoolId

            # Get the volumes in the initial pool
            $initialVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialanfPoolName

            # Move the volumes to the weekday pool
            Move-ScalingVolumes -Volumes $initialVolumes -CurrentPoolName $initialanfPoolName -TargetPool $weekdayPool -TargetPoolLabel "weekday pool"

            Remove-ScalingPool -PoolName $initialanfPoolName
        }
    } elseif ($weekendVolumeList) {
        Write-Host "Weekend volume list is valid."
        if (($currentDay -eq $weekendStartDay -and $currentTime -ge $weekendStartTime) -or ($weekendfullDays -contains $currentDay) -or ($currentDay -eq $weekendEndDay -and $currentTime -le $weekendEndTime)) {
            Write-Host "It is the weekend! and the weekend volume(s) are in place." -ForegroundColor Green
        } else {
            Write-Host "It is not the weekend but the weekend volume(s) are in place." -ForegroundColor Red
            # Get $initialanfPoolName settings
            $initialPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekendPoolName
            
            # Update $initialPool to the $weekendServiceLevel
            $weekdayPool = $initialPool
            $weekdayPool.ServiceLevel = $weekdayServiceLevel
            $weekdayPool.Name = $weekdayPoolName

            # Create the new weekend pool replicating settings in the $initialPool
            $weekdayPool = New-ScalingPool -PoolSpec $weekdayPool -TargetPoolName $weekdayPoolName
            $weekdayPool.PoolId

            # Get the volumes in the initial pool
            $initialVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekendPoolName

            # Move the volumes to the weekend pool
            Move-ScalingVolumes -Volumes $initialVolumes -CurrentPoolName $weekendPoolName -TargetPool $weekdayPool -TargetPoolLabel "weekday pool"

            Remove-ScalingPool -PoolName $weekendPoolName
        }
    } elseif ($weekdayVolumeList) {
        Write-Host "Weekday volume list is valid."
        if (($currentDay -eq $weekendStartDay -and $currentTime -ge $weekendStartTime) -or ($weekendfullDays -contains $currentDay) -or ($currentDay -eq $weekendEndDay -and $currentTime -le $weekendEndTime)) {
            Write-Host "It is the weekend but the weekday volume(s) are in place." -ForegroundColor Red
            $initialPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekdayPoolName
            
            # Update $initialPool to the $weekendServiceLevel
            $weekendPool = $initialPool
            $weekendPool.ServiceLevel = $weekendServiceLevel
            $weekendPool.Name = $weekendPoolName

            # Create the new weekend pool replicating settings in the $initialPool
            $weekendPool = New-ScalingPool -PoolSpec $weekendPool -TargetPoolName $weekendPoolName
            $weekendPool.PoolId

            # Get the volumes in the initial pool
            $initialVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekdayPoolName

            # Move the volumes to the weekend pool
            Move-ScalingVolumes -Volumes $initialVolumes -CurrentPoolName $weekdayPoolName -TargetPool $weekendPool -TargetPoolLabel "weekend pool"
            Remove-ScalingPool -PoolName $weekdayPoolName

        } else {
            Write-Host "It is a weekday and the weekday volume(s) are in place." -ForegroundColor Green
        }
    }
} elseif ($validVolumeLists -gt 1) {
    Write-Host "More than one volume list is valid." -ForegroundColor Red
    exit
} else {
    Write-Host "No valid volume lists found." -ForegroundColor Red
    exit
}
