<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 10/24/2024
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script automates the allocation of Throughput MiBs/Sec to Azure NetApp Files volumes equally for all volumes.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber


# User Editable Variables:
    $tenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"      # Tenant ID for the Azure subscription
    $resourceGroupName = "example-rg"                       # Resource group name where the Azure NetApp Files resources are located
    $anfAccountName = "example-anf-acct"                    # Azure NetApp Files account name
    $anfPoolName = "example-anf-pool"                       # Azure NetApp Files capacity pool name
    $testMode = "No"                                        # Test Mode Selector: "Yes", "No"  Yes displays report, No makes changes and displays report
    $ConvertToManualMode = "Yes"                            # Convert to manual mode: "Yes", "No" Yes converts to manual QoS, No does not convert to manual QoS and exist script if QoS is not manual


# Connect to Azure
if (-not (Get-AzContext)) {
    Connect-AzAccount -TenantId $tenantId
    Get-AzContext
}

if ($testMode -eq "Yes") {
    Write-Host "Script is running in test mode.  Changes will not be made to the volumes." -ForegroundColor Green
} elseif ($testMode -eq "No") {
    Write-Host "Script is running in ***live*** mode.  Changes ***will*** be made to the volumes." -ForegroundColor Yellow
} else { 
    Write-Host "Test Mode is not set to Yes or No. Exiting Script." -ForegroundColor Red
    exit
    }

# Get the Azure NetApp Files account details
$anfAccount = Get-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName
# Get the Azure NetApp Files capacity pool details
$anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
# Get Capacity Pool QoS Type
$cap_pool_qos_type = $anfPool.QosType
# Get the maximum provisioned throughput of the capacity pool in MiB/s
$cap_pool_max_throughput = $anfPool.TotalThroughputMibps
#if QoS type is manual, continue script, if not prompt user to convert to manual or exit with numbered list
if ($cap_pool_qos_type -eq "Manual" -or $ConvertToManualMode -eq "Yes" -or $testMode -eq "Yes") {
    #continue script 
} else {
    Write-Host "Exiting Script - Manual QoS is required" -ForegroundColor Red
    Write-Host "Capacity Pool QoS is currently set to '$cap_pool_qos_type'" -ForegroundColor Red
    Write-Host "Script is set to run with 'Convert to Manual' set to '$ConvertToManualMode'" -ForegroundColor Red
    Write-Host "Script is set to run with 'Test Mode' set to '$testMode'" -ForegroundColor Red
    exit
    } 

# If QoS is Auto and ConvertToManualMode is set to "Yes", convert the Capacity Pool to Manual
if ($capacityPoolQosType -eq "Auto" -and $ConvertToManualMode -eq "Yes") {
    Write-Host "Converting Capacity Pool QoS to Manual" -ForegroundColor Yellow
    $anfPool | Update-AzNetAppFilesPool -QosType Manual  > $null
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
    $finalData | ForEach-Object {
        if ($_.ShortName -ne "unallocated") {
            $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $_.ShortName
            $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps 1 > $null
        }
    }
    Write-Host "Capacity Pool QoS converted to Manual" -ForegroundColor Green
}   


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
            ThroughputMetric = [math]::Round($((Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'TotalThroughput' -StartTime $(get-date).AddHours(-$throughputLookBackHours) -EndTime $(get-date) -TimeGrain 00:5:00 -WarningAction SilentlyContinue | Select-Object -ExpandProperty data | Select-Object -ExpandProperty Average) | Measure-Object -average).average, 3)
            CurrentThroughputMibps = $anfVolume.ActualThroughputMibps
        }
    }

    # Ensure the total number of volumes is less than the whole number of MiB/s in the pool, write host for both possible outcomes
    if ($anfVolumes.Count -gt $cap_pool_max_throughput) {
        Write-Host "The total number of volumes in the pool exceeds the total throughput of the pool. Exiting script." -ForegroundColor Red
        exit
    } else {
    }

# Calculate unallocated size and throughput
$totalSizeGiB = ($volumeData | Measure-Object -Property SizeGiB -Sum).Sum
$unallocatedSizeGiB = $anfPool.Size / 1024 / 1024 / 1024 - $totalSizeGiB
$totalCurrentThroughputMibps = ($volumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum
$unallocatedThroughputMibps = $cap_pool_max_throughput - $totalCurrentThroughputMibps

# Add the "unallocated" row
$unallocatedRow = [PSCustomObject]@{
    ShortName = "unallocated"
    CurrentThroughputMibps = $unallocatedThroughputMibps
    SizeGiB = $unallocatedSizeGiB
    ThroughputMetric = 0
}

# Combine volume data with the unallocated row
$finalData = $volumeData + $unallocatedRow

        # Add the property NewThroughputValue to each object
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name NewThroughputValue -Value 0 -Force
    $_
}
        
# Calculate the NewThroughputValue for each volume
$finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated") {
        $_.NewThroughputValue = $cap_pool_max_throughput / $anfVolumes.Count
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
                $_.NetChangeInThroughputMibs = $_.NewThroughputValue - $_.CurrentThroughputMibps
            } else {
                $_.NetChangeInThroughputMibs = 0
            }
        }
        
        # Sort the data to ensure decreases happen first
        $finalData = $finalData | Sort-Object -Property NetChangeInThroughputMibs
        
# If the NetChangeInThroughputMibs property is equal to 0 for every volume object, write a host message and exit. Otherwise, run the rest of the code below.
if (($finalData | Where-Object { $_.NetChangeInThroughputMibs -ne 0 } | Measure-Object).Count -eq 0) {
    Write-Host "All volumes are already at the correct throughput value. Exiting script." -ForegroundColor Green
    $finalData | Format-Table -AutoSize
    exit
} else {
    # If $testMode is "No", update the volume settings in Azure with the new throughput values. Otherwise, display the table.
    if ($testMode -eq "No") {
        # Update the volumes with the new throughput values
        $finalData | Format-Table -AutoSize
        $finalData | ForEach-Object {
            if ($_.ShortName -ne "unallocated") {
                Write-Host "Updating volume `"$($_.ShortName)`" with new throughput value of `"$($_.NewThroughputValue)`" MiB/s" -ForegroundColor Yellow
                $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $_.ShortName
                $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $_.NewThroughputValue > $null
            }
        }
    } else {
        $finalData | Format-Table -AutoSize
    }
}