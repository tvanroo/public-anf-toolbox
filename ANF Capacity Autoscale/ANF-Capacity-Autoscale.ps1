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
This script automates capacity management for Azure NetApp Files volumes within a capacity pool. 
It monitors volume capacity utilization and automatically adjusts volume sizes to prevent running out of space
while keeping the pool size as small as possible for cost optimization.

The script will:
1. Gather capacity pool and volume information
2. Check capacity utilization metrics for all volumes
3. Calculate optimal volume sizes based on utilization trends
4. Resize volumes that are approaching capacity limits
5. Adjust pool size if needed to accommodate volume changes
6. Maintain safety margins to prevent out-of-space conditions

Azure Automation Account Design:
This script is designed to run as an Azure Automation Account runbook with the following requirements:
- Managed Identity authentication (Connect-AzAccount -Identity)
- Required Azure PowerShell modules pre-installed in Automation Account
- Proper RBAC permissions on ANF resources
- Scheduled execution for proactive capacity management
- Integration with Azure Monitor for alerting and logging

Azure Automation Account Setup Requirements:
1. REQUIRED MODULES (install in Automation Account):
   - Az.Accounts (4.0.0 or later)
   - Az.NetAppFiles (0.15.0 or later)
   - Az.Monitor (4.0.0 or later)

2. REQUIRED RBAC PERMISSIONS for Managed Identity:
   - NetApp Contributor role on the Resource Group containing ANF resources
   - OR specific permissions: Microsoft.NetApp/netAppAccounts/capacityPools/read,write
   - AND: Microsoft.NetApp/netAppAccounts/capacityPools/volumes/read,write
   - Monitor Reader role for metrics access: Microsoft.Insights/metrics/read

3. RECOMMENDED AUTOMATION VARIABLES (optional, will use defaults if not set):
   - ANF_TenantId: Azure Tenant ID (string)
   - ANF_ResourceGroupName: Resource Group name (string) - REQUIRED
   - ANF_AccountName: ANF Account name (string) - REQUIRED  
   - ANF_PoolName: ANF Pool name (string) - REQUIRED
   - ANF_CapacityResizeThreshold: Resize threshold % (int, default: 95)
   - ANF_MinimumVolumeGrowthPercent: Min growth % (int, default: 20)
   - ANF_MaximumVolumeGrowthPercent: Max growth % (int, default: 100)
   - ANF_MinimumFreeSpaceGiB: Min free space in GiB (int, default: 10)
   - ANF_CapacityLookBackHours: Metrics lookback hours (int, default: 24)
   - ANF_TestMode: "Yes" for test mode, "No" for live (string, default: "No")
   - ANF_VolumeMinThroughputMap: JSON string mapping volume names to minimum throughput
     Example: '{"vol1":10,"vol2":15,"vol3":5}' - sets minimum MiB/s per volume
   - ANF_MaxThroughputPerTiB: Maximum throughput per TiB override (int, default: 1000)
     Overrides the calculated pool MiB/s per TiB ratio for total pool throughput calculation

6. VOLUME EXPANSION/CONTRACTION LOGIC:
   - Expands volume if utilization % OR absolute GiB threshold is exceeded
   - Contracts volume if both thresholds have sufficient headroom (15% buffer)
   - Pool automatically resizes in TiB increments for maximum cost efficiency
   - Pool expands when volumes won't fit, contracts when full TiB can be freed
   - QoS throughput allocated proportionally with per-volume minimums respected

4. RECOMMENDED SCHEDULE:
   - Run every 4-6 hours for proactive management
   - Avoid peak business hours for volume resizing operations
   - Consider maintenance windows for pool expansions

5. MONITORING AND ALERTING:
   - Configure runbook failure alerts
   - Monitor capacity resize activities via Activity Log
   - Set up custom metrics for capacity utilization trending

#>

# Azure Automation Account runbook for ANF Capacity Management
# Required Azure PowerShell modules (install in Automation Account):
# - Az.Accounts
# - Az.NetAppFiles  
# - Az.Monitor

# Check if running in Azure Automation Account
$runningInAutomation = $false
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    $runningInAutomation = $true
    Write-Output "Running in Azure Automation Account: $env:AUTOMATION_ASSET_ACCOUNTID"
}

# Import required Azure PowerShell modules
Write-Output "Loading required Azure PowerShell modules..."
$requiredModules = @('Az.Accounts', 'Az.NetAppFiles', 'Az.Monitor')

foreach ($module in $requiredModules) {
    try {
        Import-Module $module -Force -ErrorAction Stop
        $moduleInfo = Get-Module $module
        Write-Output "Successfully imported module: $module (Version: $($moduleInfo.Version))"
        
        # Check for minimum required version for ANF Flexible service level
        if ($module -eq 'Az.NetAppFiles') {
            $minimumVersion = [Version]"0.15.0"  # Version that supports 2024-07-01-preview API
            if ($moduleInfo.Version -lt $minimumVersion) {
                Write-Warning "Az.NetAppFiles version $($moduleInfo.Version) may not support Flexible service level pools."
                Write-Warning "Consider updating: Update-Module Az.NetAppFiles -Force"
            }
        }
    } catch {
        Write-Error "Failed to import module $module. Please ensure it's installed: Install-Module $module -Force"
        throw "Required module $module is not available"
    }
}

# User Editable Variables (can be set as Automation Account variables):
    # Get variables from Automation Account if available, otherwise use defaults
    $tenantId = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_TenantId" -ErrorAction SilentlyContinue } else { "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" }
    $subscriptionId = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_SubscriptionId" -ErrorAction SilentlyContinue } else { "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" }
    $resourceGroupName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_ResourceGroupName" -ErrorAction SilentlyContinue } else { "vanRoojen-nerdio-anf" }
    $anfAccountName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_AccountName" -ErrorAction SilentlyContinue } else { "vanRoojen-nerdio-anf-account" }
    
    $anfPoolName = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_PoolName" -ErrorAction SilentlyContinue } else { "ultra-pool" }
    
    # Capacity Management Settings (can be overridden with Automation Variables)
    $capacityResizeThreshold = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_CapacityResizeThreshold" -ErrorAction SilentlyContinue } else { $null }
    if (-not $capacityResizeThreshold) { $capacityResizeThreshold = 99 }            # Percentage at which to resize volumes (95%)
    
    $minimumVolumeGrowthPercent = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MinimumVolumeGrowthPercent" -ErrorAction SilentlyContinue } else { $null }
    if (-not $minimumVolumeGrowthPercent) { $minimumVolumeGrowthPercent = 0 }      # Minimum percentage to grow a volume when resizing (20%)
    
    $maximumVolumeGrowthPercent = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MaximumVolumeGrowthPercent" -ErrorAction SilentlyContinue } else { $null }
    if (-not $maximumVolumeGrowthPercent) { $maximumVolumeGrowthPercent = 10000000 }     # Maximum percentage to grow a volume in a single operation (100%)
    
    $minimumFreeSpaceGiB = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MinimumFreeSpaceGiB" -ErrorAction SilentlyContinue } else { $null }
    if (-not $minimumFreeSpaceGiB) { $minimumFreeSpaceGiB = 256 }                   # Minimum free space threshold in GiB (10 GiB)
    
    $minimumVolumeSize = 50                                 # Minimum volume size in GiB (ANF minimum is 50 GiB)
    $maximumVolumeSize = 102400                             # Maximum volume size in GiB (100 TiB limit)
    
    # QoS and Throughput Settings
    $volumeMinThroughputMapJson = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_VolumeMinThroughputMap" -ErrorAction SilentlyContinue } else { $null }
    $volumeMinThroughputMap = @{}
    if ($volumeMinThroughputMapJson) {
        try {
            $volumeMinThroughputMap = $volumeMinThroughputMapJson | ConvertFrom-Json -AsHashtable
            Write-Output "Loaded volume minimum throughput map: $($volumeMinThroughputMap.Count) volumes configured"
        } catch {
            Write-Warning "Failed to parse ANF_VolumeMinThroughputMap JSON: $_"
            $volumeMinThroughputMap = @{}
        }
    }
    
    # Maximum throughput per TiB setting (used to cap volume throughput allocation)
    $maxThroughputPerTiB = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_MaxThroughputPerTiB" -ErrorAction SilentlyContinue } else { $null }
    if (-not $maxThroughputPerTiB) { $maxThroughputPerTiB = 68 }               # Default: 1000 MiB/s per TiB (no effective limit for most cases)
    
    # Monitoring Settings
    $capacityLookBackHours = if ($runningInAutomation) { Get-AutomationVariable -Name "ANF_CapacityLookBackHours" -ErrorAction SilentlyContinue } else { $null }
    if (-not $capacityLookBackHours) { $capacityLookBackHours = 24 }               # Hours to look back for capacity metrics (24 hours)
    
    # Test mode - for Automation Account, this should typically be "No" (live mode)
    # For local testing, default to "Yes" (test mode) for safety
    $testMode = if ($runningInAutomation) { 
        Get-AutomationVariable -Name "ANF_TestMode" -ErrorAction SilentlyContinue 
    } else { 
        "Yes"  # Default to test mode for local execution
    }
    if (-not $testMode) { $testMode = if ($runningInAutomation) { "No" } else { "Yes" } }
    
# Input validation and configuration display
Write-Output "=== ANF Capacity Autoscale Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Subscription ID: $subscriptionId"
Write-Output "Resource Group: $resourceGroupName"
Write-Output "ANF Account: $anfAccountName" 
Write-Output "ANF Pool: $anfPoolName"
Write-Output "Capacity Resize Threshold: $capacityResizeThreshold%"
Write-Output "Minimum Free Space: $minimumFreeSpaceGiB GiB"
Write-Output "Capacity Lookback Hours: $capacityLookBackHours"
if ($volumeMinThroughputMap.Count -gt 0) {
    Write-Output "Volume Min Throughput Map: $($volumeMinThroughputMap.Count) volumes configured"
}
Write-Output "Max Throughput per TiB: $maxThroughputPerTiB MiB/s"
# Force test mode for CLI testing
$testMode = "No"


if ($testMode -eq "Yes") {
    Write-Output "Running in TEST MODE - no changes will be made"
} elseif ($testMode -eq "No") {
    Write-Output "Running in LIVE MODE - changes will be applied"
} else { 
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}

# Validate required variables for Automation Account
if ($runningInAutomation) {
    if (-not $resourceGroupName -or $resourceGroupName -eq "example-rg") {
        Write-Error "ANF_ResourceGroupName automation variable must be set"
        throw "Missing required automation variable: ANF_ResourceGroupName"
    }
    if (-not $anfAccountName -or $anfAccountName -eq "example-anf-acct") {
        Write-Error "ANF_AccountName automation variable must be set"
        throw "Missing required automation variable: ANF_AccountName"
    }
    if (-not $anfPoolName -or $anfPoolName -eq "example-anf-pool") {
        Write-Error "ANF_PoolName automation variable must be set"
        throw "Missing required automation variable: ANF_PoolName"
    }
}

# Connect to Azure using Managed Identity (for Automation Account) or device code login
Write-Output "Authenticating to Azure..."
try {
    if ($runningInAutomation) {
        # Use Managed Identity for Azure Automation Account
        Write-Output "Connecting using Managed Identity..."
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Output "Successfully authenticated using Managed Identity"
    } else {
        # Check if already authenticated to Azure
        Write-Output "Checking for existing Azure authentication..."
        try {
            $currentContext = Get-AzContext -ErrorAction Stop
            Write-Output "Found existing context: $($currentContext -ne $null)"
            
            if ($currentContext -and $currentContext.Account -and $currentContext.Account.Id) {
                Write-Output "Already authenticated to Azure as: $($currentContext.Account.Id)"
                Write-Output "Current subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))"
                Write-Output "Current tenant: $($currentContext.Tenant.Id)"
                
                # Check if we need to switch to a specific tenant
                if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -and $currentContext.Tenant.Id -ne $tenantId) {
                    Write-Output "Switching to specified tenant: $tenantId"
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                } else {
                    Write-Output "Using existing authentication - no device code needed"
                }
            } else {
                Write-Output "No valid authentication context found - proceeding with device code authentication"
                # Use device code authentication for manual/local execution
                Write-Output "Connecting using device code authentication..."
                Write-Output "This will open a browser for authentication or provide a device code to enter at https://microsoft.com/devicelogin"
                
                if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                } else {
                    $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
                }
                Write-Output "Successfully authenticated to Azure using device code"
            }
        } catch {
            Write-Output "Error checking existing context or no context found: $($_.Exception.Message)"
            Write-Output "Proceeding with device code authentication..."
            # Use device code authentication for manual/local execution
            Write-Output "Connecting using device code authentication..."
            Write-Output "This will open a browser for authentication or provide a device code to enter at https://microsoft.com/devicelogin"
            
            if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
                $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
            } else {
                $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
            }
            Write-Output "Successfully authenticated to Azure using device code"
        }
    }
    
    # Display current context
    $context = Get-AzContext
    Write-Output "Azure Context: $($context.Account.Id) in subscription $($context.Subscription.Name)"
    
    # Set the subscription context if specified
    if ($subscriptionId -and $subscriptionId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
        Write-Output "Setting subscription context to: $subscriptionId"
        try {
            $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
            $updatedContext = Get-AzContext
            Write-Output "Successfully set subscription context: $($updatedContext.Subscription.Name) ($($updatedContext.Subscription.Id))"
        } catch {
            Write-Error "Failed to set subscription context to $subscriptionId. $_"
            throw "Subscription context failed"
        }
    }
    
} catch {
    Write-Error "Failed to authenticate to Azure: $_"
    throw "Authentication failed"
}

# Get the Azure NetApp Files account details
Write-Output "Connecting to ANF Account: $anfAccountName..."
try {
    $anfAccount = Get-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName -ErrorAction Stop
    Write-Output "Successfully connected to ANF Account: $anfAccountName"
} catch {
    Write-Error "Failed to connect to ANF Account: $anfAccountName. $_"
    throw "ANF Account connection failed"
}

# Get the Azure NetApp Files capacity pool details
Write-Output "Connecting to ANF Pool: $anfPoolName..."
try {
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
    Write-Output "Successfully connected to ANF Pool: $anfPoolName"
} catch {
    Write-Error "Failed to connect to ANF Pool: $anfPoolName. $_"
    throw "ANF Pool connection failed"
}

# Display pool information
$poolSizeTiB = [math]::Round($anfPool.Size / 1024 / 1024 / 1024 / 1024, 2)
$poolQosType = $anfPool.QosType
Write-Output "Pool Size: $poolSizeTiB TiB ($($anfPool.ServiceLevel) service level, $poolQosType QoS)"

# Get pool throughput information for QoS calculations
$poolMaxThroughput = if ($poolQosType -eq "Manual") { $anfPool.TotalThroughputMibps } else { 0 }

# Get list of Volumes within Capacity Pool
Write-Output "Getting volumes in pool..."
Write-Output "Pool details: ResourceGroup=$resourceGroupName, Account=$anfAccountName, Pool=$anfPoolName"

$anfVolumes = $null
$maxRetries = 3
$retryCount = 0

while ($retryCount -lt $maxRetries -and -not $anfVolumes) {
    try {
        if ($retryCount -gt 0) {
            Write-Output "Retry attempt $retryCount of $($maxRetries - 1)..."
            Start-Sleep -Seconds (5 * $retryCount)  # Progressive delay
        }
        
        # Increase timeout for volume retrieval
        $PSDefaultParameterValues['*-Az*:HttpPipelineTimeout'] = 300  # 5 minutes
        
        Write-Output "Attempting to retrieve volumes using PowerShell cmdlet (timeout: 300s)..."
        $startTime = Get-Date
        $anfVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction Stop
        $elapsed = (Get-Date) - $startTime
        
        if ($anfVolumes) {
            Write-Output "Successfully retrieved $($anfVolumes.Count) volume(s) in $($elapsed.TotalSeconds) seconds"
            break
        }
    } catch {
        $retryCount++
        $errorMessage = $_.Exception.Message
        
        if ($errorMessage -like "*timeout*" -or $errorMessage -like "*canceled*") {
            Write-Warning "Volume retrieval timed out (attempt $retryCount of $maxRetries): $errorMessage"
            
            # Try REST API as fallback on last retry
            if ($retryCount -eq $maxRetries) {
                Write-Output "Attempting REST API fallback for volume retrieval..."
                try {
                    # Get access token
                    $context = Get-AzContext
                    $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
                    
                    # Construct REST API URL
                    $subscriptionId = $context.Subscription.Id
                    $apiVersion = "2024-07-01-preview"
                    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$anfAccountName/capacityPools/$anfPoolName/volumes?api-version=$apiVersion"
                    
                    $headers = @{
                        'Authorization' = "Bearer $token"
                        'Content-Type' = 'application/json'
                    }
                    
                    # Make REST API call with custom timeout
                    $restResponse = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -TimeoutSec 180 -ErrorAction Stop
                    
                    if ($restResponse.value) {
                        Write-Output "Successfully retrieved $($restResponse.value.Count) volume(s) using REST API"
                        # Convert REST response to compatible object format
                        $anfVolumes = $restResponse.value
                        break
                    }
                } catch {
                    Write-Warning "REST API fallback also failed: $($_.Exception.Message)"
                }
            }
            
            if ($retryCount -lt $maxRetries) {
                Write-Output "Retrying with longer timeout..."
                continue
            }
        }
        
        Write-Error "Failed to retrieve volumes from pool: $errorMessage"
        if ($retryCount -ge $maxRetries) {
            throw "Volume retrieval failed after $maxRetries attempts"
        }
    }
}

# Check if volumes exist
if (-not $anfVolumes) {
    Write-Warning "No volumes found in Azure NetApp Files Capacity Pool '$anfPoolName'"
    Write-Output "Script completed - no volumes to process"
    return
}

Write-Output "Found $($anfVolumes.Count) volume(s) in pool"

# Collect capacity data for each volume
Write-Output "Collecting capacity metrics for volumes..."
$volumeData = @()
foreach ($anfVolume in $anfVolumes) {
    Write-Output "  Processing volume: $($anfVolume.Name.Split('/')[2])"
    
    # Get current capacity metrics
    try {
        # Get VolumeLogicalSize metric (actual consumed space)
        $consumedSizeMetric = Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'VolumeLogicalSize' -StartTime $(Get-Date).AddHours(-$capacityLookBackHours) -EndTime $(Get-Date) -TimeGrain 01:00:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $avgConsumedSizeBytes = if ($consumedSizeMetric.Data) { 
            ($consumedSizeMetric.Data | Where-Object { $_.Average -ne $null } | Measure-Object -Property Average -Average).Average 
        } else { 
            0 
        }
        
        # Get maximum consumed size in the lookback period
        $maxConsumedSizeBytes = if ($consumedSizeMetric.Data) { 
            ($consumedSizeMetric.Data | Where-Object { $_.Average -ne $null } | Measure-Object -Property Average -Maximum).Maximum 
        } else { 
            0 
        }
        
        # Convert to GiB
        $avgConsumedSizeGiB = [math]::Round($avgConsumedSizeBytes / 1024 / 1024 / 1024, 2)
        $maxConsumedSizeGiB = [math]::Round($maxConsumedSizeBytes / 1024 / 1024 / 1024, 2)
        
    } catch {
        Write-Warning "Could not retrieve capacity metrics for volume $($anfVolume.Name.Split('/')[2]): $_"
        $avgConsumedSizeGiB = 0
        $maxConsumedSizeGiB = 0
    }
    
    # Calculate current volume info
    $currentVolumeSizeGiB = [math]::Round($anfVolume.UsageThreshold / 1024 / 1024 / 1024, 2)
    $currentUtilizationPercent = if ($currentVolumeSizeGiB -gt 0) { 
        [math]::Round(($maxConsumedSizeGiB / $currentVolumeSizeGiB) * 100, 2) 
    } else { 
        0 
    }
    
    # Calculate free space
    $freeSpaceGiB = [math]::Round($currentVolumeSizeGiB - $maxConsumedSizeGiB, 2)
    
    # Get current throughput if QoS is Manual
    $currentThroughputMibps = if ($poolQosType -eq "Manual" -and $anfVolume.ActualThroughputMibps) { 
        $anfVolume.ActualThroughputMibps 
    } else { 
        0 
    }
    
    # Get minimum throughput for this volume
    $volumeName = $anfVolume.Name.Split('/')[2]
    $minThroughputMibps = if ($volumeMinThroughputMap.ContainsKey($volumeName)) { 
        $volumeMinThroughputMap[$volumeName] 
    } else { 
        1  # Default minimum throughput
    }
    
    # Create volume data object and add to array
    $volumeDataObject = [PSCustomObject]@{
        ShortName = $volumeName
        VolumeId = $anfVolume.Id
        CurrentSizeGiB = $currentVolumeSizeGiB
        AvgConsumedSizeGiB = $avgConsumedSizeGiB
        MaxConsumedSizeGiB = $maxConsumedSizeGiB
        FreeSpaceGiB = $freeSpaceGiB
        CurrentUtilizationPercent = $currentUtilizationPercent
        CurrentThroughputMibps = $currentThroughputMibps
        MinThroughputMibps = $minThroughputMibps
        NeedsResize = $false
        ResizeAction = "None"
        NewSizeGiB = $currentVolumeSizeGiB
        NewThroughputMibps = $currentThroughputMibps
        ResizeReason = ""
    }
    
    $volumeData += $volumeDataObject
}

# Calculate pool utilization
$totalVolumeSize = ($volumeData | Measure-Object -Property CurrentSizeGiB -Sum).Sum
$poolSizeGiB = [math]::Round($anfPool.Size / 1024 / 1024 / 1024, 2)
$poolUtilizationPercent = [math]::Round(($totalVolumeSize / $poolSizeGiB) * 100, 2)

Write-Output ""
Write-Output "Current Pool Utilization: $poolUtilizationPercent% ($totalVolumeSize GiB / $poolSizeGiB GiB)"

# Analyze each volume and determine if resize is needed
Write-Output ""
Write-Output "Analyzing volume capacity requirements..."
$volumesNeedingResize = @()

foreach ($volume in $volumeData) {
    Write-Output "  Analyzing volume: $($volume.ShortName)"
    Write-Output "    Current Size: $($volume.CurrentSizeGiB) GiB"
    Write-Output "    Max Consumed: $($volume.MaxConsumedSizeGiB) GiB" 
    Write-Output "    Free Space: $($volume.FreeSpaceGiB) GiB"
    Write-Output "    Utilization: $($volume.CurrentUtilizationPercent)%"
    
    # Check if volume needs expansion (either threshold exceeded)
    $needsExpansion = ($volume.CurrentUtilizationPercent -ge $capacityResizeThreshold) -or ($volume.FreeSpaceGiB -le $minimumFreeSpaceGiB)
    
    # Check if volume can be contracted (both thresholds have sufficient headroom)
    $canContract = ($volume.CurrentUtilizationPercent -le ($capacityResizeThreshold - 15)) -and ($volume.FreeSpaceGiB -ge ($minimumFreeSpaceGiB * 3)) -and ($volume.CurrentSizeGiB -gt $minimumVolumeSize)
    
    if ($needsExpansion) {
        Write-Output "    → Expansion needed: Utilization=$($volume.CurrentUtilizationPercent)% (threshold=$capacityResizeThreshold%), Free=$($volume.FreeSpaceGiB)GiB (min=$minimumFreeSpaceGiB GiB)"
        
        # Calculate new size for expansion - ensure adequate free space
        $requiredSizeForFreeSpace = $volume.MaxConsumedSizeGiB + $minimumFreeSpaceGiB
        
        # Apply minimum growth percentage
        $minimumNewSize = [math]::Ceiling($volume.CurrentSizeGiB * (1 + ($minimumVolumeGrowthPercent / 100)))
        
        # Apply maximum growth percentage limit
        $maximumNewSize = [math]::Ceiling($volume.CurrentSizeGiB * (1 + ($maximumVolumeGrowthPercent / 100)))
        
        Write-Output "    → Calculation: RequiredForFreeSpace=$requiredSizeForFreeSpace GiB, MinNewSize=$minimumNewSize GiB, MaxNewSize=$maximumNewSize GiB"
        
        # Choose the appropriate new size (largest of requirements, but within growth limits)
        $calculatedNewSize = [math]::Max($requiredSizeForFreeSpace, $minimumNewSize)
        $calculatedNewSize = [math]::Min($calculatedNewSize, $maximumNewSize)
        
        # Ensure within ANF limits
        $calculatedNewSize = [math]::Max($calculatedNewSize, $minimumVolumeSize)
        $calculatedNewSize = [math]::Min($calculatedNewSize, $maximumVolumeSize)
        
        Write-Output "    → Final calculated size: $calculatedNewSize GiB"
        
        if ($calculatedNewSize -gt $volume.CurrentSizeGiB) {
            $volume.NeedsResize = $true
            $volume.ResizeAction = "Expand"
            $volume.NewSizeGiB = $calculatedNewSize
            
            # Determine primary reason for expansion
            if ($volume.CurrentUtilizationPercent -ge $capacityResizeThreshold) {
                $volume.ResizeReason = "High utilization ($($volume.CurrentUtilizationPercent)% >= $capacityResizeThreshold%)"
            } else {
                $volume.ResizeReason = "Low free space ($($volume.FreeSpaceGiB) GiB <= $minimumFreeSpaceGiB GiB)"
            }
            
            $volumesNeedingResize += $volume
            Write-Output "    → EXPAND: $($volume.CurrentSizeGiB) GiB → $($volume.NewSizeGiB) GiB"
        }
    } elseif ($canContract) {
        # Calculate new size for contraction - keep adequate free space but minimize over-provisioning
        $optimalSizeWithBuffer = $volume.MaxConsumedSizeGiB + $minimumFreeSpaceGiB
        $newSize = [math]::Max($optimalSizeWithBuffer, $minimumVolumeSize)
        
        # Ensure we're actually reducing
        if ($newSize -lt $volume.CurrentSizeGiB) {
            $volume.NeedsResize = $true
            $volume.ResizeAction = "Contract"
            $volume.NewSizeGiB = $newSize
            $volume.ResizeReason = "Over-provisioned (utilization: $($volume.CurrentUtilizationPercent)%, free: $($volume.FreeSpaceGiB) GiB)"
            $volumesNeedingResize += $volume
            Write-Output "    → CONTRACT: $($volume.CurrentSizeGiB) GiB → $($volume.NewSizeGiB) GiB"
        } else {
            Write-Output "    → OK: Capacity within optimal range"
        }
    } else {
        Write-Output "    → OK: Capacity within optimal range"
    }
}

# Calculate pool size requirements and QoS throughput allocation
$currentTotalVolumeSize = ($volumeData | Measure-Object -Property CurrentSizeGiB -Sum).Sum
$newTotalVolumeSize = ($volumeData | Measure-Object -Property NewSizeGiB -Sum).Sum
$currentPoolSizeGiB = [math]::Round($anfPool.Size / 1024 / 1024 / 1024, 2)
$currentPoolSizeTiB = [math]::Round($currentPoolSizeGiB / 1024, 0)

# Calculate optimal pool size in TiB increments - target maximum utilization
# Pool should be just large enough to fit all volumes (rounded up to next TiB)
$requiredPoolSizeTiB = [math]::Ceiling($newTotalVolumeSize / 1024)

# Check if we can shrink the pool by a full TiB (1024 GiB buffer for safety)
$canShrinkToTiB = [math]::Floor(($currentPoolSizeGiB - $newTotalVolumeSize - 1024) / 1024)
if ($canShrinkToTiB -gt 0) {
    # We can shrink - use the minimum required size for maximum cost efficiency
    $optimalPoolSizeTiB = $requiredPoolSizeTiB
} else {
    # Use the minimum required size
    $optimalPoolSizeTiB = $requiredPoolSizeTiB
}

# Ensure minimum pool size of 1 TiB
$optimalPoolSizeTiB = [math]::Max($optimalPoolSizeTiB, 1)
$optimalPoolSizeGiB = $optimalPoolSizeTiB * 1024

$poolNeedsResize = $optimalPoolSizeTiB -ne $currentPoolSizeTiB
$poolAction = if ($optimalPoolSizeTiB -gt $currentPoolSizeTiB) { "Expand" } elseif ($optimalPoolSizeTiB -lt $currentPoolSizeTiB) { "Contract" } else { "None" }

Write-Output ""
Write-Output "Pool sizing analysis (TiB-based):"
Write-Output "  Current pool size: $currentPoolSizeGiB GiB ($currentPoolSizeTiB TiB)"
Write-Output "  Current total volume size: $currentTotalVolumeSize GiB"
Write-Output "  New total volume size: $newTotalVolumeSize GiB"
Write-Output "  Required pool size: $requiredPoolSizeTiB TiB (minimum)"
Write-Output "  Optimal pool size: $optimalPoolSizeGiB GiB ($optimalPoolSizeTiB TiB)"
Write-Output "  Pool action required: $poolAction"
if ($canShrinkToTiB -gt 0) {
    Write-Output "  Can shrink by: $canShrinkToTiB TiB"
}

# Calculate QoS throughput allocation if pool is Manual QoS
if ($poolQosType -eq "Manual") {
    Write-Output ""
    Write-Output "Calculating QoS throughput allocation..."
    
    # Calculate the new pool throughput based on the ratio of new to current pool size
    # This accounts for pool expansion/contraction affecting available throughput
    $currentPoolSizeTiBForCalc = [math]::Max($currentPoolSizeTiB, 0.1)  # Avoid division by zero
    $calculatedThroughputPerTiB = $poolMaxThroughput / $currentPoolSizeTiBForCalc
    
    # Apply max throughput per TiB limit (allows overriding the calculated ratio)
    $effectiveThroughputPerTiB = [math]::Min($calculatedThroughputPerTiB, $maxThroughputPerTiB)
    $newPoolMaxThroughput = [math]::Round($effectiveThroughputPerTiB * $optimalPoolSizeTiB, 0)
    
    Write-Output "  Current pool throughput: $poolMaxThroughput MiB/s ($currentPoolSizeTiB TiB)"
    Write-Output "  Calculated throughput per TiB: $([math]::Round($calculatedThroughputPerTiB, 1)) MiB/s"
    Write-Output "  Max throughput per TiB limit: $maxThroughputPerTiB MiB/s"
    Write-Output "  Effective throughput per TiB: $([math]::Round($effectiveThroughputPerTiB, 1)) MiB/s"
    Write-Output "  New pool throughput: $newPoolMaxThroughput MiB/s ($optimalPoolSizeTiB TiB)"
    
    # Get total minimum throughput requirements
    $totalMinThroughput = ($volumeData | Measure-Object -Property MinThroughputMibps -Sum).Sum
    $availableThroughput = $newPoolMaxThroughput - $totalMinThroughput
    
    if ($availableThroughput -lt 0) {
        Write-Warning "Total minimum throughput ($totalMinThroughput MiB/s) exceeds new pool capacity ($newPoolMaxThroughput MiB/s)"
        # Set all volumes to minimum throughput
        foreach ($volume in $volumeData) {
            $volume.NewThroughputMibps = $volume.MinThroughputMibps
        }
    } else {
        # Allocate throughput proportionally based on volume size, respecting minimums
        foreach ($volume in $volumeData) {
            if ($newTotalVolumeSize -gt 0) {
                $proportionalThroughput = ($availableThroughput * ($volume.NewSizeGiB / $newTotalVolumeSize))
                $volume.NewThroughputMibps = [math]::Round($volume.MinThroughputMibps + $proportionalThroughput, 0)
                Write-Output "    Volume '$($volume.ShortName)': Size=$($volume.NewSizeGiB)GiB, Proportion=$([math]::Round($volume.NewSizeGiB / $newTotalVolumeSize, 3)), ProportionalTput=$([math]::Round($proportionalThroughput, 1))MiB/s, Total=$($volume.NewThroughputMibps)MiB/s"
            } else {
                $volume.NewThroughputMibps = $volume.MinThroughputMibps
            }
        }
    }
    
    Write-Output "  Total minimum throughput: $totalMinThroughput MiB/s"
    Write-Output "  Available for allocation: $availableThroughput MiB/s"
}

# Display summary table
Write-Output ""
Write-Output ("=" * 100)
Write-Output "CAPACITY AND QOS ANALYSIS SUMMARY"
Write-Output ("=" * 100)

if ($poolQosType -eq "Manual") {
    $volumeData | Format-Table -Property ShortName, 
        @{Name="Current Size (GiB)"; Expression={$_.CurrentSizeGiB}; Align="Right"},
        @{Name="Max Consumed (GiB)"; Expression={$_.MaxConsumedSizeGiB}; Align="Right"},
        @{Name="Free Space (GiB)"; Expression={$_.FreeSpaceGiB}; Align="Right"},
        @{Name="Util %"; Expression={$_.CurrentUtilizationPercent}; Align="Right"},
        @{Name="Action"; Expression={$_.ResizeAction}},
        @{Name="New Size (GiB)"; Expression={if($_.NeedsResize){$_.NewSizeGiB}else{"-"}}; Align="Right"},
        @{Name="Curr Tput"; Expression={$_.CurrentThroughputMibps}; Align="Right"},
        @{Name="New Tput"; Expression={$_.NewThroughputMibps}; Align="Right"} -AutoSize
} else {
    $volumeData | Format-Table -Property ShortName, 
        @{Name="Current Size (GiB)"; Expression={$_.CurrentSizeGiB}; Align="Right"},
        @{Name="Max Consumed (GiB)"; Expression={$_.MaxConsumedSizeGiB}; Align="Right"},
        @{Name="Free Space (GiB)"; Expression={$_.FreeSpaceGiB}; Align="Right"},
        @{Name="Util %"; Expression={$_.CurrentUtilizationPercent}; Align="Right"},
        @{Name="Action"; Expression={$_.ResizeAction}},
        @{Name="New Size (GiB)"; Expression={if($_.NeedsResize){$_.NewSizeGiB}else{"-"}}; Align="Right"},
        @{Name="Reason"; Expression={if($_.ResizeReason){$_.ResizeReason}else{"-"}}} -AutoSize
}

# Check for QoS-only changes (throughput updates without resizing)
$volumesNeedingQoSOnly = @()
if ($poolQosType -eq "Manual") {
    foreach ($volume in $volumeData) {
        if ($volume.NewThroughputMibps -ne $volume.CurrentThroughputMibps -and -not $volume.NeedsResize) {
            $volumesNeedingQoSOnly += $volume
        }
    }
}

# Show change summary
Write-Output ""
Write-Output "Change summary:"
Write-Output "  Volumes needing resize: $($volumesNeedingResize.Count)"
Write-Output "  Pool resize needed: $($poolNeedsResize)"
if ($poolQosType -eq "Manual") {
    Write-Output "  Volumes needing QoS-only changes: $($volumesNeedingQoSOnly.Count)"
    if ($volumesNeedingQoSOnly.Count -gt 0) {
        foreach ($volume in $volumesNeedingQoSOnly) {
            Write-Output "    → $($volume.ShortName): $($volume.CurrentThroughputMibps) → $($volume.NewThroughputMibps) MiB/s"
        }
    }
}

# Execute changes if not in test mode
if ($testMode -eq "No" -and ($volumesNeedingResize.Count -gt 0 -or $poolNeedsResize -or $volumesNeedingQoSOnly.Count -gt 0)) {
    Write-Output ""
    Write-Output "Executing capacity and QoS changes..."
    
    # Determine execution order based on operation type
    $isPoolExpansion = $poolAction -eq "Expand"
    $isPoolContraction = $poolAction -eq "Contract"
    
    # EXPANSION: Pool first, then volumes (volumes need space to grow)
    if ($isPoolExpansion -and $poolNeedsResize) {
        Write-Output "Pool expansion needed - resizing pool first..."
        Write-Output "Resizing pool from $currentPoolSizeGiB GiB to $optimalPoolSizeGiB GiB ($poolAction)..."
        try {
            $newPoolSizeBytes = $optimalPoolSizeGiB * 1024 * 1024 * 1024
            
            # Try PowerShell cmdlet first
            try {
                $null = Update-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -PoolSize $newPoolSizeBytes -ErrorAction Stop
                Write-Output "Pool resize completed successfully using PowerShell cmdlet"
            } catch {
                # If PowerShell cmdlet fails with API version error, try REST API
                if ($_.Exception.Message -like "*api-version*" -and $_.Exception.Message -like "*Flexible service level*") {
                    Write-Output "PowerShell cmdlet failed with API version error, attempting REST API call..."
                    
                    # Get access token
                    $context = Get-AzContext
                    $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
                    
                    # Construct REST API URL and body
                    $subscriptionId = $context.Subscription.Id
                    $apiVersion = "2024-07-01-preview"
                    $poolResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$anfAccountName/capacityPools/$anfPoolName"
                    $uri = "https://management.azure.com$poolResourceId" + "?api-version=$apiVersion"
                    
                    $body = @{
                        properties = @{
                            size = $newPoolSizeBytes
                        }
                    } | ConvertTo-Json -Depth 3
                    
                    $headers = @{
                        'Authorization' = "Bearer $token"
                        'Content-Type' = 'application/json'
                    }
                    
                    # Make REST API call
                    $response = Invoke-RestMethod -Uri $uri -Method PATCH -Body $body -Headers $headers -ErrorAction Stop
                    Write-Output "Pool resize completed successfully using REST API (2024-07-01-preview)"
                } else {
                    # Re-throw if it's not an API version issue
                    throw
                }
            }
            
            # Refresh pool information for throughput calculations
            if ($poolQosType -eq "Manual") {
                $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
                $poolMaxThroughput = $anfPool.TotalThroughputMibps
                Write-Output "Updated pool max throughput: $poolMaxThroughput MiB/s"
            }
        } catch {
            Write-Error "Failed to resize pool: $_"
            Write-Output "Continuing with volume operations..."
        }
    }
    
    # Resize volumes and update QoS
    foreach ($volume in $volumeData) {
        $volumeChanged = $false
        
        # Resize volume if needed
        if ($volume.NeedsResize) {
            Write-Output "Resizing volume '$($volume.ShortName)' from $($volume.CurrentSizeGiB) GiB to $($volume.NewSizeGiB) GiB ($($volume.ResizeAction))..."
            try {
                $newVolumeSizeBytes = $volume.NewSizeGiB * 1024 * 1024 * 1024
                $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volume.ShortName -ErrorAction Stop
                $null = $anfVolume | Update-AzNetAppFilesVolume -UsageThreshold $newVolumeSizeBytes -ErrorAction Stop
                Write-Output "Volume '$($volume.ShortName)' resized successfully"
                $volumeChanged = $true
            } catch {
                Write-Error "Failed to resize volume '$($volume.ShortName)': $_"
            }
        }
        
        # Update QoS throughput if Manual QoS and throughput changed
        if ($poolQosType -eq "Manual" -and $volume.NewThroughputMibps -ne $volume.CurrentThroughputMibps) {
            Write-Output "Updating volume '$($volume.ShortName)' throughput from $($volume.CurrentThroughputMibps) to $($volume.NewThroughputMibps) MiB/s..."
            try {
                if (-not $volumeChanged) {
                    $anfVolume = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volume.ShortName -ErrorAction Stop
                }
                $null = $anfVolume | Update-AzNetAppFilesVolume -ThroughputMibps $volume.NewThroughputMibps -ErrorAction Stop
                Write-Output "Volume '$($volume.ShortName)' throughput updated successfully"
            } catch {
                Write-Error "Failed to update throughput for volume '$($volume.ShortName)': $_"
            }
        }
    }
    
    # CONTRACTION: Volumes first, then pool (volumes must shrink to free pool space)
    if ($isPoolContraction -and $poolNeedsResize) {
        Write-Output "Pool contraction needed - resizing pool after volumes..."
        Write-Output "Resizing pool from $currentPoolSizeGiB GiB to $optimalPoolSizeGiB GiB ($poolAction)..."
        try {
            $newPoolSizeBytes = $optimalPoolSizeGiB * 1024 * 1024 * 1024
            
            # Try PowerShell cmdlet first
            try {
                $null = Update-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -PoolSize $newPoolSizeBytes -ErrorAction Stop
                Write-Output "Pool resize completed successfully using PowerShell cmdlet"
            } catch {
                # If PowerShell cmdlet fails with API version error, try REST API
                if ($_.Exception.Message -like "*api-version*" -and $_.Exception.Message -like "*Flexible service level*") {
                    Write-Output "PowerShell cmdlet failed with API version error, attempting REST API call..."
                    
                    # Get access token
                    $context = Get-AzContext
                    $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id, $null, "Never", $null, "https://management.azure.com/").AccessToken
                    
                    # Construct REST API URL and body
                    $subscriptionId = $context.Subscription.Id
                    $apiVersion = "2024-07-01-preview"
                    $poolResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$anfAccountName/capacityPools/$anfPoolName"
                    $uri = "https://management.azure.com$poolResourceId" + "?api-version=$apiVersion"
                    
                    $body = @{
                        properties = @{
                            size = $newPoolSizeBytes
                        }
                    } | ConvertTo-Json -Depth 3
                    
                    $headers = @{
                        'Authorization' = "Bearer $token"
                        'Content-Type' = 'application/json'
                    }
                    
                    # Make REST API call
                    $response = Invoke-RestMethod -Uri $uri -Method PATCH -Body $body -Headers $headers -ErrorAction Stop
                    Write-Output "Pool resize completed successfully using REST API (2024-07-01-preview)"
                } else {
                    # Re-throw if it's not an API version issue
                    throw
                }
            }
            
            # Refresh pool information for throughput calculations
            if ($poolQosType -eq "Manual") {
                $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
                $poolMaxThroughput = $anfPool.TotalThroughputMibps
                Write-Output "Updated pool max throughput: $poolMaxThroughput MiB/s"
            }
        } catch {
            Write-Error "Failed to resize pool: $_"
            Write-Warning "Pool contraction failed - this may be due to insufficient free space after volume operations"
        }
    }
    
    # POST-CHANGE VERIFICATION - Confirm all operations completed successfully
    Write-Output ""
    Write-Output "=== Post-Change Verification ==="
    
    try {
        # Verify pool size
        $anfPoolVerify = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
        $verifyPoolSizeGiB = [math]::Round($anfPoolVerify.Size / 1024 / 1024 / 1024, 0)
        
        if ($poolNeedsResize) {
            if ($verifyPoolSizeGiB -eq $optimalPoolSizeGiB) {
                Write-Output "✓ Pool size verified: $verifyPoolSizeGiB GiB (matches expected $optimalPoolSizeGiB GiB)"
            } else {
                Write-Warning "✗ Pool size mismatch: Current=$verifyPoolSizeGiB GiB, Expected=$optimalPoolSizeGiB GiB"
                Write-Output "Note: Pool changes may take a few minutes to reflect in Azure Portal"
            }
        } else {
            Write-Output "✓ Pool size unchanged: $verifyPoolSizeGiB GiB (as expected)"
        }
        
        # Verify volumes
        $anfVolumesVerify = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction Stop
        
        foreach ($volume in $volumesNeedingResize) {
            $verifyVolume = $anfVolumesVerify | Where-Object { $_.Name.Split('/')[2] -eq $volume.ShortName }
            if ($verifyVolume) {
                $verifyVolumeSizeGiB = [math]::Round($verifyVolume.UsageThreshold / 1024 / 1024 / 1024, 0)
                
                if ($verifyVolumeSizeGiB -eq $volume.NewSizeGiB) {
                    Write-Output "✓ Volume '$($volume.ShortName)' size verified: $verifyVolumeSizeGiB GiB (matches expected $($volume.NewSizeGiB) GiB)"
                } else {
                    Write-Warning "✗ Volume '$($volume.ShortName)' size mismatch: Current=$verifyVolumeSizeGiB GiB, Expected=$($volume.NewSizeGiB) GiB"
                }
                
                # Verify QoS throughput if Manual QoS
                if ($poolQosType -eq "Manual" -and $volume.NewThroughputMibps -ne $volume.CurrentThroughputMibps) {
                    $verifyThroughput = $verifyVolume.ThroughputMibps
                    if ($verifyThroughput -eq $volume.NewThroughputMibps) {
                        Write-Output "✓ Volume '$($volume.ShortName)' throughput verified: $verifyThroughput MiB/s (matches expected $($volume.NewThroughputMibps) MiB/s)"
                    } else {
                        Write-Warning "✗ Volume '$($volume.ShortName)' throughput mismatch: Current=$verifyThroughput MiB/s, Expected=$($volume.NewThroughputMibps) MiB/s"
                    }
                }
            } else {
                Write-Warning "✗ Could not find volume '$($volume.ShortName)' for verification"
            }
        }
        
        # Summary of verification
        Write-Output ""
        if ($poolNeedsResize -or $volumesNeedingResize.Count -gt 0) {
            Write-Output "Verification completed. Any mismatches above may indicate:"
            Write-Output "- Azure portal sync delay (changes can take 2-5 minutes to appear)"
            Write-Output "- Partial operation failure (check error messages above)"
            Write-Output "- Azure API consistency delays"
            Write-Output ""
            Write-Output "If mismatches persist after 5 minutes, re-run the script to check status"
        }
        
    } catch {
        Write-Warning "Post-change verification failed: $($_.Exception.Message)"
        Write-Output "This may be a temporary issue - the operations may have completed successfully"
    }
    
    Write-Output ""
    Write-Output "Capacity and QoS management operations completed"
} elseif ($testMode -eq "Yes" -and ($volumesNeedingResize.Count -gt 0 -or $poolNeedsResize -or $volumesNeedingQoSOnly.Count -gt 0)) {
    Write-Output ""
    Write-Output "Test mode enabled - no changes were made"
    Write-Output "To execute these changes, set testMode to 'No' or ANF_TestMode automation variable to 'No'"
} else {
    Write-Output ""
    Write-Output "No capacity or QoS changes needed at this time"
}

Write-Output ""
Write-Output "Script execution completed successfully"
