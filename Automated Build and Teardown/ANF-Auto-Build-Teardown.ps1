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
This script automates the creation and destruction of an Azure NetApp Files account, capacity pool, and volumes. 
This is primarily used in testing to quickly destroy and recreate resources.

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber


# User Editable Variables:
$tenantId =             "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Tenant ID for the Azure subscription
$resourceGroupName =    "example-rg"                            # Resource group name where the Azure NetApp Files resources are located
$anfAccountName =       "example-anf-account"                   # Azure NetApp Files account name
$anfPoolName =          "example-anf-pool"                      # Azure NetApp Files capacity pool name
$location =             "westus2"                               # Azure Region in "Name" format. Full list can be found by running "az account list-locations -o table"
$anfPoolSizeInTiB =     1                                       # Desired Pool Size in TiBs (minimum 1)
$vol_prefix =           "Vol"                                   # Volumes will be sequentially named Vol1, Vol2, etc. The CreationToken paramater re-uses vol# as well. Existing Volumes with matching Vol# name will be skipped, so if Vol1 already exxists and 2 total Volumes are requested, then only Vol2 would be created, and Vol1 would remain unchanged.
$vol_qty =              3                                       # Total number of volumes to be created
$volSizeInGiB =         60                                      # Size in GiB for each Volume. Volumes with Variable sizes are not currently supported. (minimum 50)
$serviceLevel =         "Standard"                              # "Standard" or "Premium" or "Ultra"
$delegatedSubnetId =    "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/example-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/example-sub" # Set delegated subnet id (must exist)

# Calculations based on User Editable Variables:
    $volSize = $volSizeInGiB * 1073741824                   # in bytes, 1 GiB = 1073741824 bytes
    $anfPoolSizeInGiB = $anfPoolSizeInTiB * 1024            # in GiB, 1 TiB = 1024 GiB  
    $anfPoolSize = $anfPoolSizeInTiB * 1099511627776        # in bytes, 1 TiB = 1099511627776 bytes


# Connect to az tenant by id if not  connected
if (-not (Get-AzContext)) {
    Connect-AzAccount -TenantId $tenantId
    Get-AzContext
}

# Ask user to choose the "Create ANF Resources" or "Delete ANF Resources" option.
Write-Host "Tenant ID: " $tenantId
Write-Host "Resource Group Name: " $resourceGroupName
Write-Host "ANF Account Name: " $anfAccountName
Write-Host "ANF Pool Name: " $anfPoolName
Write-Host " "
Write-Host "Choose an option:"
Write-Host "1. Create ANF Resources"
Write-Host "2. Delete ANF Resources"
$option = Read-Host "Enter the option number"

# If user selects 1, run the following script to create the ANF resources
if ($option -eq 1) {
    Write-Host "You have selected to create ANF Resources"
    $expectedTime = [math]::Round(($vol_qty * 0.5) + 6.5)
    Write-Host "This creation process should take approximately $expectedTime minutes to complete" -ForegroundColor Yellow

    # Identify total size of any existing volumes within the pool
    $existingVolSize = 0
    # If existing ANF Volume(s) exist, get them and add their size to $existingVolSize, if not, add 0 to $existingVolSize
    if (Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction SilentlyContinue) {
        $existingVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
        foreach ($vol in $existingVolumes) {
            $existingVolSize += $vol.UsageThreshold
        }
    } else {
        $existingVolSize = 0
    }
    # Convert total volume(s) size to GiB for display
        $existingVolSizeGiB = $existingVolSize / 1073741824
        $additionaVolumeTotalSize = ($vol_qty * $volSize) / 1073741824  
        $totalVolumeSize = $existingVolSizeGiB + $additionaVolumeTotalSize

    # If existing volume size + new volumes total size exceeds total pool size, notify and exit. If not, notify on total proposed volume size
    if ($totalVolumeSize -gt $anfPoolSizeInGiB) {
        Write-Host "Total volume size exceeds pool size of ${anfPoolSizeInGiB} GiB: $existingVolSizeGiB GiB Existing + $additionaVolumeTotalSize GiB New = $totalVolumeSize GiB, exiting..." -ForegroundColor Red
        exit
    } else {
        $totalVolSize = $existingVolSizeGiB + ($vol_qty * $volSizeInGiB)
        Write-Host "New Total Volume Size: $existingVolSizeGiB GiB Existing + $additionaVolumeTotalSize GiB New = $totalVolumeSize GiB (assuming no existing volume names overlap with new volume names, with overlap the total will be lower.)" -ForegroundColor Green
    }

    # Check for RG and create if not present, with output for debugging
    if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue)) {
        Write-Host "Resource Group $resourceGroupName not found, exiting."  -ForegroundColor Red
        exit
    } 

    # Check for ANF account and create if not present, with output for debugging
    if (-not (Get-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating ANF Account $anfAccountName in $resourceGroupName" -ForegroundColor Yellow
        New-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName -Location $location > $null
        Write-Host "Account $anfAccountName created" -ForegroundColor Green
    } else {
        Write-Host "ANF Account $anfAccountName already exists in $resourceGroupName" -ForegroundColor Green
    }

    # Check for ANF Capacity Pool and create if not present, with output for debugging
    if (-not (Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating ANF Capacity Pool $anfPoolName in $anfAccountName" -ForegroundColor Yellow
        New-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -Location $location -ServiceLevel "Standard" -PoolSize $anfPoolSize > $null
        Write-Host "Capacity Pool $anfPoolName created" -ForegroundColor Green
    } else {
        Write-Host "ANF Capacity Pool $anfPoolName already exists in $anfAccountName" -ForegroundColor Green
    }

    # Create volume(s) in the capacity pool based on $vol_qty, with output for debugging
    for ($i = 1; $i -le $vol_qty; $i++) {
        $volName = $vol_prefix + $i
        if (-not (Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volName -ErrorAction SilentlyContinue)) {
            Write-Host "Creating ANF Volume $volName in $anfPoolName" -ForegroundColor Yellow
            New-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volName -Location $location -ServiceLevel $serviceLevel -UsageThreshold $volSize -SubnetId $delegatedSubnetId -CreationToken $volName -NetworkFeature Standard > $null
            Write-Host "Volume $volName created" -ForegroundColor Green
        } else {
            Write-Host "ANF Volume $volName already exists in $anfPoolName" -ForegroundColor Green
        }
    }

} elseif ($option -eq 2) {
    Write-Host "You have selected to delete ANF Resources"
    
    # List all volumes within the capacity pool
    $volumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    $expectedTime = [math]::Round(($volumes.count * 0.5) + 2.5)
    Write-Host "This delete process should take approximately $expectedTime minutes to complete" -ForegroundColor Yellow
    
    # For each volume in volumes, write volume name to Write-Host
    foreach ($vol in $volumes) {
        Write-Host $vol.CreationToken "to be deleted" -ForegroundColor Red
    }

    # Delete all volumes in the capacity pool
    foreach ($vol in $volumes) {
        Remove-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $vol.CreationToken
        Write-Host $vol.CreationToken "deleted" -ForegroundColor Green
    }
    Write-Host "All volumes in the Capacity Pool $anfPoolName have been deleted" -ForegroundColor Yellow

    # Delete the Capacity Pool
    Write-Host "Deleting Capacity Pool" $anfPoolName -ForegroundColor Red
    Remove-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName
    Write-Host $anfPoolName "deleted" -ForegroundColor Green

    # Delete the ANF Account
    Write-Host "Deleting ANF Account" $anfAccountName -ForegroundColor Red
    Remove-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName
    Write-Host $anfAccountName "deleted" -ForegroundColor Green 

} else {
    Write-Host "You have selected an invalid option"
    exit
}

