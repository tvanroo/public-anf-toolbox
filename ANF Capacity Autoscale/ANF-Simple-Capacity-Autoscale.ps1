#!/usr/bin/env pwsh
<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 07/31/2025
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
SIMPLIFIED single volume per pool capacity management for Azure NetApp Files.
REQUIREMENTS: Pool must contain exactly ONE volume and must use Manual QoS.
Volume fills the entire pool capacity since you pay for the full TiB anyway.
Pool size is automatically adjusted to minimum required TiB increments.

Required Automation Variables:
   - ANF_ResourceGroupName: Resource Group name (string) - REQUIRED
   - ANF_AccountName: ANF Account name (string) - REQUIRED  
   - ANF_PoolName: ANF Pool name (string) - REQUIRED
   - ANF_VolumeName: Volume name (string) - REQUIRED
   - ANF_MinimumFreeSpacePercent: Min free space % (int, default: 20)
   - ANF_MinimumFreeSpaceGiB: Min free space in GiB (int, default: 100)
   - ANF_MaxThroughputPerTiB: Max throughput per TiB (int, default: 1000)
   - ANF_TestMode: "Yes" for test mode, "No" for live (string, default: "No")

#>

param()

Write-Output "Starting ANF Simple Capacity Autoscale Script..."
Write-Output "Script start time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"

# Check if running in Azure Automation Account
$runningInAutomation = $env:AUTOMATION_WORKER_ID -ne $null

# Load configuration from Automation Variables or use defaults
try {
    # Required variables
    $tenantId = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_TenantId" -ErrorAction SilentlyContinue } else { "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" }
    $subscriptionId = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_SubscriptionId" -ErrorAction SilentlyContinue } else { "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" }
    $resourceGroupName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_ResourceGroupName" -ErrorAction SilentlyContinue } else { "vanRoojen-nerdio-anf" }
    $anfAccountName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_AccountName" -ErrorAction SilentlyContinue } else { "vanRoojen-nerdio-anf-account" }
    $anfPoolName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_PoolName" -ErrorAction SilentlyContinue } else { "ultra-pool" }
    $volumeName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_VolumeName" -ErrorAction SilentlyContinue } else { "standard" }
    
    # Capacity Management Settings
    $minimumFreeSpacePercent = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MinimumFreeSpacePercent" -ErrorAction SilentlyContinue } else { $null }
    if (-not $minimumFreeSpacePercent) { $minimumFreeSpacePercent = 20 }
    
    $minimumFreeSpaceGiB = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MinimumFreeSpaceGiB" -ErrorAction SilentlyContinue } else { $null }
    if (-not $minimumFreeSpaceGiB) { $minimumFreeSpaceGiB = 100 }
    
    $minimumVolumeSize = 50                                 # ANF minimum
    $maximumVolumeSize = 102400                             # 100 TiB limit
    
    # QoS and Throughput Settings
    $maxThroughputPerTiB = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MaxThroughputPerTiB" -ErrorAction SilentlyContinue } else { $null }
    if (-not $maxThroughputPerTiB) { $maxThroughputPerTiB = 1000 }
    
    # Test mode
    $testMode = if ($runningInAutomation) { 
        Get-AutomationVariable -Name "ANF_TestMode" -ErrorAction SilentlyContinue 
    } else { 
        "Yes"  # Default to test mode for local execution
    }
    if (-not $testMode) { $testMode = if ($runningInAutomation) { "No" } else { "Yes" } }
    
} catch {
    Write-Error "Failed to load configuration: $_"
    exit 1
}

Write-Output ""
Write-Output "=== ANF Simple Capacity Autoscale Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Subscription ID: $subscriptionId"
Write-Output "Resource Group: $resourceGroupName"
Write-Output "ANF Account: $anfAccountName" 
Write-Output "ANF Pool: $anfPoolName"
Write-Output "Volume: $volumeName"
Write-Output "Minimum Free Space: $minimumFreeSpacePercent% / $minimumFreeSpaceGiB GiB"
Write-Output "Max Throughput per TiB: $maxThroughputPerTiB MiB/s"
Write-Output "Test Mode: $testMode"

# Authentication
Write-Output ""
Write-Output "Authenticating..."
try {
    if ($runningInAutomation) {
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Output "Connected using Managed Identity"
    } else {
        # Try existing session first
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if ($context) {
            Write-Output "Using existing Azure session for: $($context.Account.Id)"
        } else {
            # Use device code authentication for local testing
            $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
            Write-Output "Connected using device code authentication"
        }
    }
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

# Get ANF resources
Write-Output ""
Write-Output "Getting ANF resources..."
try {
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
    $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volumeName -ErrorAction Stop
    
    Write-Output "Found pool: $($anfPool.Name) - Size: $([math]::Round($anfPool.Size / 1024 / 1024 / 1024, 0)) GiB"
    Write-Output "Found volume: $($anfVolume.Name) - Size: $([math]::Round($anfVolume.UsageThreshold / 1024 / 1024 / 1024, 0)) GiB"
} catch {
    Write-Error "Failed to get ANF resources: $_"
    exit 1
}

# Validate single volume and Manual QoS requirements
Write-Output ""
Write-Output "Validating pool configuration..."
try {
    # Check for single volume in pool
    $allVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction Stop
    if ($allVolumes.Count -gt 1) {
        Write-Error "This script is designed for single volume pools only. Found $($allVolumes.Count) volumes in pool '$anfPoolName'."
        Write-Error "Volumes found: $($allVolumes.Name -join ', ')"
        Write-Error "Please use this script only with pools containing exactly one volume."
        exit 1
    }
    
    # Check for Manual QoS requirement
    if ($anfPool.QosType -ne "Manual") {
        Write-Error "This script requires Manual QoS pools. Pool '$anfPoolName' is configured with '$($anfPool.QosType)' QoS."
        Write-Error "Please change the pool to Manual QoS or use a different pool."
        exit 1
    }
    
    Write-Output "✓ Single volume configuration confirmed"
    Write-Output "✓ Manual QoS configuration confirmed"
} catch {
    Write-Error "Failed to validate pool configuration: $_"
    exit 1
}

# Get current volume consumption
Write-Output ""
Write-Output "Getting current volume consumption..."
try {
    $metrics = Get-AzMetric -ResourceId $anfVolume.Id -MetricName "VolumeLogicalSize" -TimeGrain "00:05:00" -ErrorAction Stop
    
    if ($metrics.Data.Count -eq 0) {
        Write-Warning "No current consumption data available - assuming 50% of volume size"
        $currentConsumedBytes = $anfVolume.UsageThreshold * 0.5
    } else {
        $currentConsumedBytes = $metrics.Data[-1].Average
        if (-not $currentConsumedBytes) {
            Write-Warning "No valid consumption data - assuming 50% of volume size"
            $currentConsumedBytes = $anfVolume.UsageThreshold * 0.5
        }
    }
    
    Write-Output "Current consumed size: $([math]::Round($currentConsumedBytes / 1024 / 1024 / 1024, 2)) GiB"
} catch {
    Write-Warning "Failed to get current consumption: $_ - Assuming 50% of volume size"
    $currentConsumedBytes = $anfVolume.UsageThreshold * 0.5
}

# Calculate current state
$currentVolumeSizeGiB = [math]::Round($anfVolume.UsageThreshold / 1024 / 1024 / 1024, 0)
$currentConsumedSizeGiB = [math]::Round($currentConsumedBytes / 1024 / 1024 / 1024, 2)
$freeSpaceGiB = $currentVolumeSizeGiB - $currentConsumedSizeGiB
$utilizationPercent = if ($currentVolumeSizeGiB -gt 0) { [math]::Round(($currentConsumedSizeGiB / $currentVolumeSizeGiB) * 100, 1) } else { 0 }

$currentPoolSizeGiB = [math]::Round($anfPool.Size / 1024 / 1024 / 1024, 0)
$currentPoolSizeTiB = [math]::Round($currentPoolSizeGiB / 1024, 0)

Write-Output ""
Write-Output "Current state:"
Write-Output "  Volume size: $currentVolumeSizeGiB GiB"
Write-Output "  Current consumed: $currentConsumedSizeGiB GiB"
Write-Output "  Free space: $freeSpaceGiB GiB"
Write-Output "  Utilization: $utilizationPercent%"
Write-Output "  Pool size: $currentPoolSizeGiB GiB ($currentPoolSizeTiB TiB)"

# Calculate minimum volume size needed based on current consumption and free space requirements
$freeSpacePercentRequired = $currentConsumedSizeGiB * ($minimumFreeSpacePercent / 100)
$freeSpaceRequired = [math]::Max($freeSpacePercentRequired, $minimumFreeSpaceGiB)
$minimumVolumeNeeded = [math]::Ceiling($currentConsumedSizeGiB + $freeSpaceRequired)

# Calculate required pool size (round up to next TiB)
$requiredPoolSizeTiB = [math]::Ceiling($minimumVolumeNeeded / 1024)
$requiredPoolSizeTiB = [math]::Max($requiredPoolSizeTiB, 1)  # Minimum 1 TiB
$requiredPoolSizeGiB = $requiredPoolSizeTiB * 1024

# Volume fills the entire pool capacity (why pay for space you don't use?)
$newVolumeSizeGiB = $requiredPoolSizeGiB - 50  # Leave small buffer for pool overhead
$newVolumeSizeGiB = [math]::Max($newVolumeSizeGiB, $minimumVolumeSize)  # ANF minimum
$newVolumeSizeGiB = [math]::Min($newVolumeSizeGiB, $maximumVolumeSize)  # ANF maximum

# Determine action needed
$volumeAction = if ($newVolumeSizeGiB -gt $currentVolumeSizeGiB) { "Expand" } elseif ($newVolumeSizeGiB -lt $currentVolumeSizeGiB) { "Contract" } else { "None" }

Write-Output ""
Write-Output "Capacity analysis:"
Write-Output "  Current consumed: $currentConsumedSizeGiB GiB"
Write-Output "  Free space required: $([math]::Round($freeSpaceRequired, 1)) GiB ($minimumFreeSpacePercent% or $minimumFreeSpaceGiB GiB minimum)"
Write-Output "  Minimum volume needed: $minimumVolumeNeeded GiB"
Write-Output "  Required pool size: $requiredPoolSizeGiB GiB ($requiredPoolSizeTiB TiB)"
Write-Output "  New volume size: $newVolumeSizeGiB GiB (fills pool capacity)"
Write-Output "  Volume action: $volumeAction"

$poolNeedsResize = $requiredPoolSizeTiB -ne $currentPoolSizeTiB
$poolAction = if ($requiredPoolSizeTiB -gt $currentPoolSizeTiB) { "Expand" } elseif ($requiredPoolSizeTiB -lt $currentPoolSizeTiB) { "Contract" } else { "None" }

Write-Output ""
Write-Output "Pool sizing:"
Write-Output "  Current pool: $currentPoolSizeGiB GiB ($currentPoolSizeTiB TiB)"
Write-Output "  Required pool: $requiredPoolSizeGiB GiB ($requiredPoolSizeTiB TiB)"
Write-Output "  Pool action: $poolAction"

# Calculate QoS throughput (always Manual QoS)
Write-Output ""
Write-Output "Calculating QoS throughput..."

# Calculate pool throughput based on max per TiB setting
$poolMaxThroughput = $maxThroughputPerTiB * $requiredPoolSizeTiB

# Volume gets all available throughput
$newThroughputMibps = $poolMaxThroughput

Write-Output "  Pool throughput capacity: $poolMaxThroughput MiB/s ($requiredPoolSizeTiB TiB × $maxThroughputPerTiB MiB/s per TiB)"
Write-Output "  Volume throughput: $newThroughputMibps MiB/s"

# Summary
Write-Output ""
Write-Output "=" * 80
Write-Output "CHANGE SUMMARY"
Write-Output "=" * 80
Write-Output "Volume: $volumeName"
Write-Output "  Current size: $currentVolumeSizeGiB GiB"
Write-Output "  New size: $newVolumeSizeGiB GiB"
Write-Output "  Action: $volumeAction"
Write-Output "  Current throughput: $($anfVolume.ThroughputMibps) MiB/s"
Write-Output "  New throughput: $newThroughputMibps MiB/s"
Write-Output ""
Write-Output "Pool: $anfPoolName"
Write-Output "  Current size: $currentPoolSizeGiB GiB ($currentPoolSizeTiB TiB)"
Write-Output "  New size: $requiredPoolSizeGiB GiB ($requiredPoolSizeTiB TiB)"
Write-Output "  Action: $poolAction"

# Execute changes
$volumeNeedsChange = ($volumeAction -ne "None")
$poolNeedsChange = ($poolAction -ne "None")
$qosNeedsChange = ($newThroughputMibps -ne $anfVolume.ThroughputMibps)

if ($testMode -eq "No" -and ($volumeNeedsChange -or $poolNeedsChange -or $qosNeedsChange)) {
    Write-Output ""
    Write-Output "Executing changes..."
    
    # Order: Pool expansion first, then volume, then pool contraction
    if ($poolAction -eq "Expand") {
        Write-Output "Expanding pool to $requiredPoolSizeGiB GiB..."
        try {
            $newPoolSizeBytes = $requiredPoolSizeGiB * 1024 * 1024 * 1024
            $null = $anfPool | Update-AzNetAppFilesPool -Size $newPoolSizeBytes -ErrorAction Stop
            Write-Output "Pool expanded successfully"
        } catch {
            Write-Error "Failed to expand pool: $_"
            exit 1
        }
    }
    
    # Volume resize
    if ($volumeNeedsChange) {
        Write-Output "Resizing volume to $newVolumeSizeGiB GiB..."
        try {
            $newVolumeSizeBytes = $newVolumeSizeGiB * 1024 * 1024 * 1024
            $null = $anfVolume | Update-AzNetAppFilesVolume -UsageThreshold $newVolumeSizeBytes -ErrorAction Stop
            Write-Output "Volume resized successfully"
        } catch {
            Write-Error "Failed to resize volume: $_"
            exit 1
        }
    }
    
    # QoS update
    if ($qosNeedsChange) {
        Write-Output "Updating volume throughput to $newThroughputMibps MiB/s..."
        try {
            $null = $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $newThroughputMibps -ErrorAction Stop
            Write-Output "Throughput updated successfully"
        } catch {
            Write-Error "Failed to update throughput: $_"
            exit 1
        }
    }
    
    # Pool contraction
    if ($poolAction -eq "Contract") {
        Write-Output "Contracting pool to $requiredPoolSizeGiB GiB..."
        try {
            $newPoolSizeBytes = $requiredPoolSizeGiB * 1024 * 1024 * 1024
            $null = $anfPool | Update-AzNetAppFilesPool -Size $newPoolSizeBytes -ErrorAction Stop
            Write-Output "Pool contracted successfully"
        } catch {
            Write-Error "Failed to contract pool: $_"
            exit 1
        }
    }
    
    Write-Output ""
    Write-Output "All changes completed successfully"
    
} elseif ($testMode -eq "Yes" -and ($volumeNeedsChange -or $poolNeedsChange -or $qosNeedsChange)) {
    Write-Output ""
    Write-Output "Test mode enabled - no changes were made"
    Write-Output "To execute these changes, set ANF_TestMode to 'No'"
} else {
    Write-Output ""
    Write-Output "No changes needed at this time"
}

Write-Output ""
Write-Output "Script execution completed successfully"
