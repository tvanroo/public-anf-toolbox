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

2. REQUIRED RBAC PERMISSIONS for Managed Identity:
   - NetApp Contributor role on the Resource Group containing ANF resources
   - OR specific permissions: Microsoft.NetApp/netAppAccounts/capacityPools/read,write
   - AND: Microsoft.NetApp/netAppAccounts/capacityPools/volumes/read,write
   - Monitor Reader role for metrics access: Microsoft.Insights/metrics/read

3. SETTINGS
   Settings can be supplied as Azure Automation variables or as process environment variables
   with the same names for Cloud Shell/local testing. Azure Automation variables are used first
   when running in an Automation Account; otherwise environment variables are used before defaults.

   Required target settings:
   - ANF_TenantId: Azure Tenant ID (string)
   - ANF_CapacityPoolResourceId: Capacity pool Resource ID (string) - REQUIRED

   Capacity decision settings:
   - ANF_CapacityResizeThreshold: Resize threshold percent (int, default: 99)
   - ANF_MinimumVolumeGrowthPercent: Minimum growth percent (int, default: 0)
   - ANF_MaximumVolumeGrowthPercent: Maximum growth percent (int, default: 10000000)
   - ANF_MinimumFreeSpaceGiB: Minimum free space in GiB (int, default: 256)
   - ANF_CapacityLookBackHours: Metrics lookback hours (int, default: 24)
   - ANF_TestMode: "Yes" for test mode, "No" for live (string, default: "Yes")
   - ANF_LargeVolumeMaximumSizeGiB: Large volume maximum size guard (int, default: 1048576)

   Throughput decision settings:
   - ANF_VolumeMinThroughputMap: JSON string mapping volume names to minimum throughput
     Example: '{"vol1":10,"vol2":15,"vol3":5}' - sets minimum MiB/s per volume

4. VOLUME EXPANSION/CONTRACTION LOGIC:
   - Expands volume if utilization % OR absolute GiB threshold is exceeded
   - Contracts volume if both thresholds have sufficient headroom (15% buffer)
   - Pool automatically resizes in TiB increments for maximum cost efficiency
   - Pool expands when volumes won't fit, contracts when full TiB can be freed
   - Classic manual QoS throughput is allocated proportionally with per-volume minimums respected
   - Flexible service level throughput is allocated from current pool throughput and is not derived from pool capacity
   - Classic service level throughput per TiB is hard-coded: Standard=16, Premium=64, Ultra=128 MiB/s.
   - Flexible service level minimum pool throughput is hard-coded at 128 MiB/s.
   - Regular volume limits are fixed at 50 GiB minimum and 102400 GiB maximum.
   - Large volume minimum is fixed at 51200 GiB; maximum defaults to 1048576 GiB and can be overridden.
   - Regular volumes are not converted to large volumes; existing large volumes are detected from Azure properties.
   - Breakthrough large volumes are excluded from changes and produce a warning.
   - Volume contraction uses a hard-coded 15 percentage point utilization buffer and 3x minimum-free-space gate.
   - Missing capacity metric data is treated as 0 GiB consumed.

5. RECOMMENDED SCHEDULE:
   - Run every 4-6 hours for proactive management
   - Avoid peak business hours for volume resizing operations
   - Consider maintenance windows for pool expansions

6. MONITORING AND ALERTING:
   - Configure runbook failure alerts
   - Monitor capacity resize activities via Activity Log
   - Set up custom metrics for capacity utilization trending

#>

# Azure Automation Account runbook for ANF Capacity Management
# Required Azure PowerShell modules (install in Automation Account):
# - Az.Accounts

# Check if running in Azure Automation Account
$runningInAutomation = $false
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    $runningInAutomation = $true
    Write-Output "Running in Azure Automation Account: $env:AUTOMATION_ASSET_ACCOUNTID"
}

# Import required Azure PowerShell modules
Write-Output "Loading required Azure PowerShell modules..."
$requiredModules = @('Az.Accounts')

foreach ($module in $requiredModules) {
    try {
        Import-Module $module -Force -ErrorAction Stop
        $moduleInfo = Get-Module $module
        Write-Output "Successfully imported module: $module (Version: $($moduleInfo.Version))"
    } catch {
        Write-Error "Failed to import module $module. Please ensure it's installed: Install-Module $module -Force"
        throw "Required module $module is not available"
    }
}

function Get-AnfSetting {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter()][object]$Default = $null
    )

    $value = $null
    if ($runningInAutomation -and (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        try {
            $value = Get-AutomationVariable -Name $Name -ErrorAction SilentlyContinue
        } catch {
            $value = $null
        }
    }

    if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) {
        $value = [Environment]::GetEnvironmentVariable($Name)
    }

    if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) {
        return $Default
    }

    return $value
}

function Resolve-AnfCapacityPoolResourceId {
    param([Parameter(Mandatory=$true)][string]$CapacityPoolResourceId)

    $normalizedResourceId = "$CapacityPoolResourceId".Trim().TrimEnd("/")
    $pattern = '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.NetApp/netAppAccounts/([^/]+)/capacityPools/([^/]+)$'
    if ($normalizedResourceId -notmatch $pattern) {
        throw "ANF_CapacityPoolResourceId must be a capacity pool Resource ID in this format: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.NetApp/netAppAccounts/<account>/capacityPools/<pool>"
    }

    return [PSCustomObject]@{
        CapacityPoolResourceId = $normalizedResourceId
        SubscriptionId = $Matches[1]
        ResourceGroupName = $Matches[2]
        AccountName = $Matches[3]
        PoolName = $Matches[4]
    }
}

function Convert-AnfJsonObjectToHashtable {
    param([object]$InputObject)

    $hash = @{}
    if ($null -eq $InputObject) {
        return $hash
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = $InputObject[$key]
        }
        return $hash
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }

    return $hash
}

# User Editable Variables (can be set as Automation Account variables):
    # Get variables from Automation Account, Cloud Shell environment variables, or defaults
    $tenantId = Get-AnfSetting -Name "ANF_TenantId" -Default "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    $capacityPoolResourceId = Get-AnfSetting -Name "ANF_CapacityPoolResourceId"
    $subscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    $resourceGroupName = "example-rg"
    $anfAccountName = "example-anf-acct"
    $anfPoolName = "example-anf-pool"

    if ($capacityPoolResourceId) {
        $anfTarget = Resolve-AnfCapacityPoolResourceId -CapacityPoolResourceId $capacityPoolResourceId
        $subscriptionId = $anfTarget.SubscriptionId
        $resourceGroupName = $anfTarget.ResourceGroupName
        $anfAccountName = $anfTarget.AccountName
        $anfPoolName = $anfTarget.PoolName
        $capacityPoolResourceId = $anfTarget.CapacityPoolResourceId
    } else {
        # Legacy fallback for manual testing with older environment variables.
        $subscriptionId = Get-AnfSetting -Name "ANF_SubscriptionId" -Default $subscriptionId
        $resourceGroupName = Get-AnfSetting -Name "ANF_ResourceGroupName" -Default $resourceGroupName
        $anfAccountName = Get-AnfSetting -Name "ANF_AccountName" -Default $anfAccountName
        $anfPoolName = Get-AnfSetting -Name "ANF_PoolName" -Default $anfPoolName
        if ($subscriptionId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -and $resourceGroupName -ne "example-rg" -and $anfAccountName -ne "example-anf-acct" -and $anfPoolName -ne "example-anf-pool") {
            $capacityPoolResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$anfAccountName/capacityPools/$anfPoolName"
        }
    }
    
    # Capacity Management Settings (can be overridden with Automation Variables)
    $capacityResizeThreshold = Get-AnfSetting -Name "ANF_CapacityResizeThreshold"
    if (-not $capacityResizeThreshold) { $capacityResizeThreshold = 99 }            # Percentage at which to resize volumes (95%)
    
    $minimumVolumeGrowthPercent = Get-AnfSetting -Name "ANF_MinimumVolumeGrowthPercent"
    if (-not $minimumVolumeGrowthPercent) { $minimumVolumeGrowthPercent = 0 }      # Minimum percentage to grow a volume when resizing (20%)
    
    $maximumVolumeGrowthPercent = Get-AnfSetting -Name "ANF_MaximumVolumeGrowthPercent"
    if (-not $maximumVolumeGrowthPercent) { $maximumVolumeGrowthPercent = 10000000 }     # Maximum percentage to grow a volume in a single operation (100%)
    
    $minimumFreeSpaceGiB = Get-AnfSetting -Name "ANF_MinimumFreeSpaceGiB"
    if (-not $minimumFreeSpaceGiB) { $minimumFreeSpaceGiB = 256 }                   # Minimum free space threshold in GiB (10 GiB)

    # Volume size limit profiles. Regular volumes cannot be converted to large volumes by resizing.
    $regularVolumeMinimumSizeGiB = 50
    $regularVolumeMaximumSizeGiB = 102400
    $largeVolumeMinimumSizeGiB = 51200
    $largeVolumeMaximumSizeGiB = Get-AnfSetting -Name "ANF_LargeVolumeMaximumSizeGiB"
    if (-not $largeVolumeMaximumSizeGiB) { $largeVolumeMaximumSizeGiB = 1048576 }
    
    # QoS and Throughput Settings
    $volumeMinThroughputMapJson = Get-AnfSetting -Name "ANF_VolumeMinThroughputMap"
    $volumeMinThroughputMap = @{}
    if ($volumeMinThroughputMapJson) {
        try {
            $volumeMinThroughputMapObject = $volumeMinThroughputMapJson | ConvertFrom-Json
            $volumeMinThroughputMap = Convert-AnfJsonObjectToHashtable -InputObject $volumeMinThroughputMapObject
            Write-Output "Loaded volume minimum throughput map: $($volumeMinThroughputMap.Count) volumes configured"
        } catch {
            Write-Warning "Failed to parse ANF_VolumeMinThroughputMap JSON: $_"
            $volumeMinThroughputMap = @{}
        }
    }
    
    $minimumPoolThroughputMibps = 128 # Flexible service level included pool throughput floor
    
    # Monitoring Settings
    $capacityLookBackHours = Get-AnfSetting -Name "ANF_CapacityLookBackHours"
    if (-not $capacityLookBackHours) { $capacityLookBackHours = 24 }               # Hours to look back for capacity metrics (24 hours)
    
    # Test mode defaults to "Yes" for safety. Set ANF_TestMode to "No" only after reviewing the planned changes.
    $testMode = Get-AnfSetting -Name "ANF_TestMode" -Default "Yes"
    if (-not $testMode) { $testMode = "Yes" }
    
# Input validation and configuration display
Write-Output "=== ANF Capacity Autoscale Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Capacity Pool Resource ID: $capacityPoolResourceId"
Write-Output "Subscription ID: $subscriptionId"
Write-Output "Resource Group: $resourceGroupName"
Write-Output "ANF Account: $anfAccountName" 
Write-Output "ANF Pool: $anfPoolName"
Write-Output "Capacity Resize Threshold: $capacityResizeThreshold%"
Write-Output "Minimum Free Space: $minimumFreeSpaceGiB GiB"
Write-Output "Capacity Lookback Hours: $capacityLookBackHours"
Write-Output "Regular Volume Limits: $regularVolumeMinimumSizeGiB-$regularVolumeMaximumSizeGiB GiB"
Write-Output "Large Volume Limits: $largeVolumeMinimumSizeGiB-$largeVolumeMaximumSizeGiB GiB"
if ($volumeMinThroughputMap.Count -gt 0) {
    Write-Output "Volume Min Throughput Map: $($volumeMinThroughputMap.Count) volumes configured"
}
Write-Output "Classic Manual QoS Rates: Standard=16, Premium=64, Ultra=128 MiB/s per TiB"
Write-Output "Minimum FSL Pool Throughput: $minimumPoolThroughputMibps MiB/s"

if ($testMode -eq "Yes") {
    Write-Output "Running in TEST MODE - no changes will be made"
} elseif ($testMode -eq "No") {
    Write-Output "Running in LIVE MODE - changes will be applied"
} else { 
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}

# Validate required variables
if (-not $capacityPoolResourceId) {
    Write-Error "ANF_CapacityPoolResourceId must be set before running this script"
    throw "Missing required variable: ANF_CapacityPoolResourceId"
}

$anfApiVersion = "2026-04-01"

function Get-AnfObjectProperty {
    param(
        [Parameter(Mandatory=$true)][object]$InputObject,
        [Parameter(Mandatory=$true)][string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($propertyName)) {
            return $InputObject[$propertyName]
        }

        $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq $propertyName } | Select-Object -First 1
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

function Resolve-AnfThroughputMibpsFromProperties {
    param([object]$Properties)

    if ($null -eq $Properties) {
        return $null
    }

    $throughputCandidates = @(
        (Get-AnfObjectProperty -InputObject $Properties -PropertyNames @('totalThroughputMibps', 'TotalThroughputMibps')),
        (Get-AnfObjectProperty -InputObject $Properties -PropertyNames @('throughputMibps', 'ThroughputMibps')),
        (Get-AnfObjectProperty -InputObject $Properties -PropertyNames @('provisionedThroughputMibps', 'ProvisionedThroughputMibps')),
        (Get-AnfObjectProperty -InputObject $Properties -PropertyNames @('actualThroughputMibps', 'ActualThroughputMibps')),
        (Get-AnfObjectProperty -InputObject $Properties -PropertyNames @('customThroughputMibps', 'CustomThroughputMibps'))
    )

    foreach ($candidate in $throughputCandidates) {
        if ($null -ne $candidate -and "$candidate" -ne "") {
            try {
                return [double]$candidate
            } catch {}
        }
    }

    return $null
}

function Convert-ToWholeThroughputMibps {
    param(
        [Parameter(Mandatory=$true)][double]$Value,
        [Parameter()][int]$Minimum = 0
    )

    $rounded = [int][math]::Round($Value, 0, [System.MidpointRounding]::AwayFromZero)
    if ($rounded -lt $Minimum) {
        return $Minimum
    }

    return $rounded
}

function Test-AnfFlexibleServiceLevel {
    param([object]$ServiceLevel)

    if ($null -eq $ServiceLevel) {
        return $false
    }

    return "$ServiceLevel".Trim().ToLowerInvariant() -eq "flexible"
}

function Get-AnfClassicManualThroughputPerTiB {
    param([Parameter(Mandatory=$true)][object]$ServiceLevel)

    switch ("$ServiceLevel".Trim()) {
        "Standard" { return 16 }
        "Premium" { return 64 }
        "Ultra" { return 128 }
        default {
            throw "Unsupported classic service level '$ServiceLevel' for manual QoS throughput calculation. Expected Standard, Premium, or Ultra."
        }
    }
}

function Convert-AnfValueToBool {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return $Value
    }

    $normalized = "$Value".Trim().ToLowerInvariant()
    return $normalized -in @("true", "yes", "enabled", "enable", "1")
}

function Resolve-AnfVolumeSizeProfile {
    param(
        [Parameter(Mandatory=$true)][object]$VolumeObject,
        [Parameter()][double]$CurrentSizeGiB = 0
    )

    $isLargeVolume = Convert-AnfValueToBool -Value (Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('IsLargeVolume', 'isLargeVolume'))
    $largeVolumeType = Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('LargeVolumeType', 'largeVolumeType')
    $breakthroughMode = Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('BreakthroughMode', 'breakthroughMode')
    $breakthroughModeEnabled = Convert-AnfValueToBool -Value $breakthroughMode
    $coolAccess = Convert-AnfValueToBool -Value (Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('CoolAccess', 'coolAccess'))
    $profileSignal = "$largeVolumeType $breakthroughMode".Trim()
    $isBreakthroughVolume = $isLargeVolume -and ($breakthroughModeEnabled -or $profileSignal -match "(?i)breakthrough")

    $profileName = "Regular"
    $isSupported = $true
    $excludeReason = ""
    if ($isBreakthroughVolume) {
        $profileName = "Breakthrough"
        $isSupported = $false
        $excludeReason = "Breakthrough large volume is not supported by this script."
    } elseif ($isLargeVolume) {
        $profileName = "Large"
    }

    switch ($profileName) {
        "Breakthrough" {
            $minimumSizeGiB = [double]$CurrentSizeGiB
            $maximumSizeGiB = [double]$CurrentSizeGiB
        }
        "Large" {
            $minimumSizeGiB = [double]$largeVolumeMinimumSizeGiB
            $maximumSizeGiB = [double]$largeVolumeMaximumSizeGiB
        }
        default {
            $minimumSizeGiB = [double]$regularVolumeMinimumSizeGiB
            $maximumSizeGiB = [double]$regularVolumeMaximumSizeGiB
            $profileName = "Regular"
        }
    }

    if ([double]$CurrentSizeGiB -gt $maximumSizeGiB) {
        Write-Warning "Volume '$((Get-AnfVolumeShortName -VolumeObject $VolumeObject))' is already $CurrentSizeGiB GiB, above the configured $profileName maximum of $maximumSizeGiB GiB. Using current size as the effective maximum for this run."
        $maximumSizeGiB = [double]$CurrentSizeGiB
    }

    return [PSCustomObject]@{
        ProfileName = $profileName
        IsLargeVolume = $isLargeVolume
        LargeVolumeType = $largeVolumeType
        BreakthroughMode = $breakthroughMode
        CoolAccess = $coolAccess
        IsSupported = $isSupported
        ExcludeReason = $excludeReason
        MinimumSizeGiB = $minimumSizeGiB
        MaximumSizeGiB = $maximumSizeGiB
    }
}

function Get-AnfVolumeShortName {
    param([Parameter(Mandatory=$true)][object]$VolumeObject)

    $name = Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('ShortName', 'Name', 'name')
    if ($name -and "$name".Contains('/')) {
        return ("$name".Split('/')[-1])
    }

    if ($name) {
        return "$name"
    }

    $id = Get-AnfObjectProperty -InputObject $VolumeObject -PropertyNames @('Id', 'id')
    if ($id -and "$id" -match "/volumes/([^/]+)$") {
        return $Matches[1]
    }

    throw "Unable to resolve volume short name from volume object."
}

function Invoke-AnfArmJson {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter()][string]$QueryString = "",
        [Parameter()][string]$BodyJson
    )

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

    $normalizedQueryString = ""
    if ($QueryString) {
        $normalizedQueryString = "$QueryString"
        if ($normalizedQueryString.StartsWith("?")) {
            $normalizedQueryString = "&$($normalizedQueryString.Substring(1))"
        } elseif (-not $normalizedQueryString.StartsWith("&")) {
            $normalizedQueryString = "&$normalizedQueryString"
        }
    }

    $uri = "$resourceManagerUrl$ResourceId" + "?api-version=$ApiVersion$normalizedQueryString"
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    if ($BodyJson) {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $BodyJson -ErrorAction Stop
    }

    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ErrorAction Stop
}

function New-AnfResourceId {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter()][string]$PoolName,
        [Parameter()][string]$VolumeName
    )

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$AccountName"
    if ($PoolName) {
        $resourceId = "$resourceId/capacityPools/$PoolName"
    }
    if ($VolumeName) {
        $resourceId = "$resourceId/volumes/$VolumeName"
    }

    return $resourceId
}

function Get-AnfAccount {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName
    )

    $resourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName
    $account = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($account -and $account.error) {
        throw "ANF account REST API returned error for $ResourceGroupName/$AccountName. code='$($account.error.code)' message='$($account.error.message)'"
    }

    if (-not $account -or -not $account.id) {
        throw "Unable to parse ANF account REST response for $ResourceGroupName/$AccountName."
    }

    return $account
}

function Get-AnfMetricAverageValues {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$MetricName,
        [Parameter(Mandatory=$true)][double]$LookBackHours
    )

    $endTimeUtc = (Get-Date).ToUniversalTime()
    $startTimeUtc = $endTimeUtc.AddHours(-$LookBackHours)
    $timespan = "{0:o}/{1:o}" -f $startTimeUtc, $endTimeUtc
    $queryString = "&metricnames=$([uri]::EscapeDataString($MetricName))&timespan=$([uri]::EscapeDataString($timespan))&interval=PT1H&aggregation=Average"
    $metricsResourceId = "$ResourceId/providers/microsoft.insights/metrics"
    $metricsResponse = Invoke-AnfArmJson -Method "GET" -ResourceId $metricsResourceId -ApiVersion "2018-01-01" -QueryString $queryString

    $averages = @()
    foreach ($metric in @($metricsResponse.value)) {
        foreach ($timeSeries in @($metric.timeseries)) {
            foreach ($dataPoint in @($timeSeries.data)) {
                if ($null -ne $dataPoint.average) {
                    $averages += [double]$dataPoint.average
                }
            }
        }
    }

    return $averages
}

function Get-AnfRestErrorDetails {
    param(
        [Parameter(Mandatory=$true)][object]$ErrorRecord
    )

    $errorCode = $null
    $errorMessage = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseText = $reader.ReadToEnd()
                if ($responseText) {
                    try {
                        $responseJson = $responseText | ConvertFrom-Json -ErrorAction Stop
                        if ($responseJson.error) {
                            $errorCode = $responseJson.error.code
                            $errorMessage = $responseJson.error.message
                        }
                    } catch {}
                }
            }
        } catch {}
    }

    if (-not $errorMessage) {
        $errorMessage = $ErrorRecord.Exception.Message
    }

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $errorDetailsMessage = "$($ErrorRecord.ErrorDetails.Message)"
        if ($errorDetailsMessage) {
            try {
                $errorDetailsJson = $errorDetailsMessage | ConvertFrom-Json -ErrorAction Stop
                if ($errorDetailsJson.error) {
                    if (-not $errorCode -and $errorDetailsJson.error.code) {
                        $errorCode = $errorDetailsJson.error.code
                    }
                    if ($errorDetailsJson.error.message) {
                        $errorMessage = $errorDetailsJson.error.message
                    }
                }
            } catch {
                if (-not $errorMessage -or $errorMessage -match "Bad Request") {
                    $errorMessage = $errorDetailsMessage
                }
            }
        }
    }

    return [PSCustomObject]@{
        Code = $errorCode
        Message = $errorMessage
    }
}

function Convert-AnfRestPool {
    param([Parameter(Mandatory=$true)][object]$Pool)

    $poolProperties = $Pool.properties
    $resolvedSize = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('size', 'Size')
    $resolvedServiceLevel = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('serviceLevel', 'ServiceLevel')
    $resolvedQosType = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('qosType', 'QosType')
    $resolvedThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $poolProperties
    if ($null -eq $resolvedThroughputMibps) {
        $resolvedThroughputMibps = 0
    }

    return [PSCustomObject]@{
        Id = $Pool.id
        Name = $Pool.name
        Size = [double]$resolvedSize
        ServiceLevel = $resolvedServiceLevel
        QosType = $resolvedQosType
        TotalThroughputMibps = [double]$resolvedThroughputMibps
        Raw = $Pool
    }
}

function Get-AnfPool {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $resourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName
    $poolCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($poolCandidate -and $poolCandidate.error) {
        throw "Capacity pool REST API returned error for $ResourceGroupName/$AccountName/$PoolName. code='$($poolCandidate.error.code)' message='$($poolCandidate.error.message)'"
    }

    $pool = $null
    if ($poolCandidate -and $poolCandidate.properties) {
        $pool = $poolCandidate
    } elseif ($poolCandidate -and $poolCandidate.value -and $poolCandidate.value.Count -gt 0) {
        $pool = $poolCandidate.value[0]
    }

    if (-not $pool) {
        $topLevelProps = @()
        if ($poolCandidate) { $topLevelProps = @($poolCandidate.PSObject.Properties.Name) }
        throw "Unable to parse capacity pool REST response for $ResourceGroupName/$AccountName/$PoolName. Top-level properties present: $($topLevelProps -join ', ')"
    }

    return Convert-AnfRestPool -Pool $pool
}

function Convert-AnfRestVolume {
    param([Parameter(Mandatory=$true)][object]$Volume)

    $volumeProperties = $Volume.properties
    $resolvedThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $volumeProperties
    if ($null -eq $resolvedThroughputMibps) {
        $resolvedThroughputMibps = 0
    }

    $usageThreshold = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('usageThreshold', 'UsageThreshold')
    $volumeName = Get-AnfVolumeShortName -VolumeObject $Volume
    $isLargeVolume = Convert-AnfValueToBool -Value (Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('isLargeVolume', 'IsLargeVolume'))
    $largeVolumeType = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('largeVolumeType', 'LargeVolumeType')
    $breakthroughMode = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('breakthroughMode', 'BreakthroughMode')
    $coolAccess = Convert-AnfValueToBool -Value (Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('coolAccess', 'CoolAccess'))

    return [PSCustomObject]@{
        Id = $Volume.id
        Name = $volumeName
        Tags = $Volume.tags
        UsageThreshold = [double]$usageThreshold
        IsLargeVolume = $isLargeVolume
        LargeVolumeType = $largeVolumeType
        BreakthroughMode = $breakthroughMode
        CoolAccess = $coolAccess
        ActualThroughputMibps = [double]$resolvedThroughputMibps
        ThroughputMibps = [double]$resolvedThroughputMibps
        Raw = $Volume
    }
}

function Get-AnfVolumes {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $resourceId = "$(New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName)/volumes"
    $volumesCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($volumesCandidate -and $volumesCandidate.error) {
        throw "Volume list REST API returned error for $ResourceGroupName/$AccountName/$PoolName. code='$($volumesCandidate.error.code)' message='$($volumesCandidate.error.message)'"
    }

    $volumes = @()
    if ($volumesCandidate -and $volumesCandidate.value) {
        $volumes = @($volumesCandidate.value)
    } elseif ($volumesCandidate -and $volumesCandidate.id) {
        $volumes = @($volumesCandidate)
    }

    return @($volumes | ForEach-Object { Convert-AnfRestVolume -Volume $_ })
}

function Get-AnfVolume {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][string]$VolumeName
    )

    $resourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName -VolumeName $VolumeName
    $volume = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($volume -and $volume.error) {
        throw "Volume REST API returned error for $ResourceGroupName/$AccountName/$PoolName/$VolumeName. code='$($volume.error.code)' message='$($volume.error.message)'"
    }

    return Convert-AnfRestVolume -Volume $volume
}

function Update-AnfPoolSize {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][double]$TargetSizeBytes,
        [Parameter(Mandatory=$true)][bool]$IsFlexibleServiceLevel
    )

    $poolResourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName
    $poolSizeApiVersion = if ($IsFlexibleServiceLevel) { "2024-07-01-preview" } else { $anfApiVersion }
    $body = @{
        properties = @{
            size = $TargetSizeBytes
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $poolResourceId -ApiVersion $poolSizeApiVersion -BodyJson $body
    Write-Output "Pool resize completed successfully using REST API ($poolSizeApiVersion)"
}

function Update-AnfFslPoolThroughputMibps {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][double]$TargetThroughputMibps
    )

    $targetRounded = Convert-ToWholeThroughputMibps -Value $TargetThroughputMibps -Minimum 0
    $poolUpdateApiVersion = "2024-07-01-preview"
    $propertyCandidates = @("customThroughputMibps", "provisionedThroughputMibps", "totalThroughputMibps")
    $lastErrorDetails = $null
    $sawCooldownOrDeferredDecreaseSignal = $false
    $deferredDecreaseMessage = $null

    foreach ($propertyName in $propertyCandidates) {
        try {
            $body = @{
                properties = @{
                    $propertyName = $targetRounded
                }
            } | ConvertTo-Json -Depth 3
            $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $PoolResourceId -ApiVersion $poolUpdateApiVersion -BodyJson $body
            return
        } catch {
            $lastErrorDetails = Get-AnfRestErrorDetails -ErrorRecord $_
            $lastErrorMessage = "$($lastErrorDetails.Message)"
            if (
                $lastErrorDetails.Code -eq "PoolCustomThroughputCanNotBeDecreasedDuringCoolDownPeriod" -or
                $lastErrorMessage -match "cool.?down"
            ) {
                $sawCooldownOrDeferredDecreaseSignal = $true
                if (-not $deferredDecreaseMessage) {
                    $deferredDecreaseMessage = $lastErrorMessage
                }
            }
        }
    }

    if ($sawCooldownOrDeferredDecreaseSignal) {
        throw "Failed to update pool throughput to $targetRounded MiB/s via REST API. code='PoolCustomThroughputCanNotBeDecreasedDuringCoolDownPeriod' message='$deferredDecreaseMessage'"
    }

    $detailSuffix = ""
    if ($lastErrorDetails) {
        if ($lastErrorDetails.Code) {
            $detailSuffix = " code='$($lastErrorDetails.Code)'"
        }
        if ($lastErrorDetails.Message) {
            $detailSuffix = "$detailSuffix message='$($lastErrorDetails.Message)'"
        }
    }

    throw "Failed to update pool throughput to $targetRounded MiB/s via REST API.$detailSuffix"
}

function Update-AnfVolumeCapacity {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][string]$VolumeName,
        [Parameter(Mandatory=$true)][string]$VolumeResourceId,
        [Parameter(Mandatory=$true)][double]$TargetSizeBytes,
        [Parameter(Mandatory=$true)][bool]$IsFlexibleServiceLevel
    )

    $body = @{
        properties = @{
            usageThreshold = $TargetSizeBytes
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $VolumeResourceId -ApiVersion $anfApiVersion -BodyJson $body
}

function Update-AnfVolumeThroughput {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][string]$VolumeName,
        [Parameter(Mandatory=$true)][string]$VolumeResourceId,
        [Parameter(Mandatory=$true)][double]$TargetThroughputMibps,
        [Parameter(Mandatory=$true)][bool]$IsFlexibleServiceLevel
    )

    $targetWholeMibps = Convert-ToWholeThroughputMibps -Value $TargetThroughputMibps -Minimum 1

    $body = @{
        properties = @{
            throughputMibps = $targetWholeMibps
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $VolumeResourceId -ApiVersion $anfApiVersion -BodyJson $body
}

# Connect to Azure using Managed Identity (for Automation Account) or device code login
Write-Output "Authenticating to Azure..."
try {
    try {
        $null = Disable-AzContextAutosave -Scope Process -ErrorAction Stop
        Write-Output "Disabled Az context autosave for this run"
    } catch {
        Write-Warning "Unable to disable Az context autosave: $($_.Exception.Message)"
    }

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
    $anfAccount = Get-AnfAccount -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName
    Write-Output "Successfully connected to ANF Account: $anfAccountName"
} catch {
    Write-Error "Failed to connect to ANF Account: $anfAccountName. $_"
    throw "ANF Account connection failed"
}

# Get the Azure NetApp Files capacity pool details
Write-Output "Connecting to ANF Pool: $anfPoolName..."
try {
    $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    Write-Output "Successfully connected to ANF Pool: $anfPoolName"
} catch {
    Write-Error "Failed to connect to ANF Pool: $anfPoolName. $_"
    throw "ANF Pool connection failed"
}

# Display pool information
$poolSizeTiB = [math]::Round($anfPool.Size / 1024 / 1024 / 1024 / 1024, 2)
$poolServiceLevel = $anfPool.ServiceLevel
$poolQosType = $anfPool.QosType
$isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel -ServiceLevel $poolServiceLevel
Write-Output "Pool Size: $poolSizeTiB TiB ($poolServiceLevel service level, $poolQosType QoS)"

if ($isFlexibleServiceLevel -and $poolQosType -ne "Manual") {
    Write-Error "Flexible service level pools require Manual QoS. Pool '$anfPoolName' reported QoS type '$poolQosType'."
    throw "Invalid Flexible service level QoS configuration"
}

# Get pool throughput information for QoS calculations
$poolMaxThroughput = if ($poolQosType -eq "Manual") { $anfPool.TotalThroughputMibps } else { 0 }
if ($isFlexibleServiceLevel) {
    Write-Output "Flexible service level detected. Pool capacity and pool throughput will be planned independently."
    Write-Output "Current FSL pool throughput: $poolMaxThroughput MiB/s"
}

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
        
        Write-Output "Attempting to retrieve volumes using ANF REST API (timeout: 300s)..."
        $startTime = Get-Date
        $anfVolumes = Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
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
    $volumeName = Get-AnfVolumeShortName -VolumeObject $anfVolume
    Write-Output "  Processing volume: $volumeName"
    
    # Get current capacity metrics
    try {
        # Get VolumeLogicalSize metric (actual consumed space)
        $consumedSizeMetricAverages = @(Get-AnfMetricAverageValues -ResourceId $anfVolume.Id -MetricName 'VolumeLogicalSize' -LookBackHours $capacityLookBackHours)
        $avgConsumedSizeBytes = if ($consumedSizeMetricAverages.Count -gt 0) {
            ($consumedSizeMetricAverages | Measure-Object -Average).Average
        } else { 
            0 
        }
        
        # Get maximum consumed size in the lookback period
        $maxConsumedSizeBytes = if ($consumedSizeMetricAverages.Count -gt 0) {
            ($consumedSizeMetricAverages | Measure-Object -Maximum).Maximum
        } else { 
            0 
        }
        
        # Convert to GiB
        $avgConsumedSizeGiB = [math]::Round($avgConsumedSizeBytes / 1024 / 1024 / 1024, 2)
        $maxConsumedSizeGiB = [math]::Round($maxConsumedSizeBytes / 1024 / 1024 / 1024, 2)
        
    } catch {
        Write-Warning "Could not retrieve capacity metrics for volume $volumeName`: $_"
        $avgConsumedSizeGiB = 0
        $maxConsumedSizeGiB = 0
    }
    
    # Calculate current volume info
    $currentVolumeSizeGiB = [math]::Round($anfVolume.UsageThreshold / 1024 / 1024 / 1024, 2)
    $volumeSizeProfile = Resolve-AnfVolumeSizeProfile -VolumeObject $anfVolume -CurrentSizeGiB $currentVolumeSizeGiB
    $currentUtilizationPercent = if ($currentVolumeSizeGiB -gt 0) { 
        [math]::Round(($maxConsumedSizeGiB / $currentVolumeSizeGiB) * 100, 2) 
    } else { 
        0 
    }
    
    # Calculate free space
    $freeSpaceGiB = [math]::Round($currentVolumeSizeGiB - $maxConsumedSizeGiB, 2)
    
    # Get current throughput if QoS is Manual
    $resolvedCurrentThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $anfVolume
    $currentThroughputMibps = if ($poolQosType -eq "Manual" -and $null -ne $resolvedCurrentThroughputMibps) {
        $resolvedCurrentThroughputMibps
    } else {
        0
    }
    
    # Get minimum throughput for this volume
    $minThroughputMibps = if ($volumeMinThroughputMap.ContainsKey($volumeName)) { 
        $volumeMinThroughputMap[$volumeName] 
    } else { 
        1  # Default minimum throughput
    }
    
    # Create volume data object and add to array
    $volumeDataObject = [PSCustomObject]@{
        ShortName = $volumeName
        VolumeId = $anfVolume.Id
        IsLargeVolume = $volumeSizeProfile.IsLargeVolume
        LargeVolumeType = $volumeSizeProfile.LargeVolumeType
        VolumeLimitProfile = $volumeSizeProfile.ProfileName
        ExcludedFromAutoscale = (-not $volumeSizeProfile.IsSupported)
        ExcludeReason = $volumeSizeProfile.ExcludeReason
        MinimumSizeGiB = $volumeSizeProfile.MinimumSizeGiB
        MaximumSizeGiB = $volumeSizeProfile.MaximumSizeGiB
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

    if ($volumeDataObject.ExcludedFromAutoscale) {
        Write-Warning "Breakthrough large volume '$volumeName' found. Excluding it from capacity and throughput changes. Reason: $($volumeDataObject.ExcludeReason)"
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
    Write-Output "    Volume Profile: $($volume.VolumeLimitProfile) (limits: $($volume.MinimumSizeGiB)-$($volume.MaximumSizeGiB) GiB)"

    if ($volume.ExcludedFromAutoscale) {
        Write-Warning "    Excluded from autoscale changes: $($volume.ExcludeReason)"
        continue
    }
    
    # Check if volume needs expansion (either threshold exceeded)
    $needsExpansion = ($volume.CurrentUtilizationPercent -ge $capacityResizeThreshold) -or ($volume.FreeSpaceGiB -le $minimumFreeSpaceGiB)
    
    # Check if volume can be contracted (both thresholds have sufficient headroom)
    $canContract = ($volume.CurrentUtilizationPercent -le ($capacityResizeThreshold - 15)) -and ($volume.FreeSpaceGiB -ge ($minimumFreeSpaceGiB * 3)) -and ($volume.CurrentSizeGiB -gt $volume.MinimumSizeGiB)
    
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
        $calculatedNewSize = [math]::Max($calculatedNewSize, $volume.MinimumSizeGiB)
        if ($calculatedNewSize -gt $volume.MaximumSizeGiB) {
            Write-Warning "    Calculated size $calculatedNewSize GiB exceeds $($volume.VolumeLimitProfile) maximum $($volume.MaximumSizeGiB) GiB. Capping target size."
            if (-not $volume.IsLargeVolume -and $volume.MaximumSizeGiB -eq [double]$regularVolumeMaximumSizeGiB) {
                Write-Warning "    Regular volume '$($volume.ShortName)' cannot be converted to a large volume by resize. Create a large volume separately if capacity above $($volume.MaximumSizeGiB) GiB is required."
            }
        }
        $calculatedNewSize = [math]::Min($calculatedNewSize, $volume.MaximumSizeGiB)
        
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
        $newSize = [math]::Max($optimalSizeWithBuffer, $volume.MinimumSizeGiB)
        
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
$newPoolMaxThroughput = 0
$poolThroughputNeedsUpdate = $false
if ($poolQosType -eq "Manual") {
    Write-Output ""
    Write-Output "Calculating QoS throughput allocation..."
    
    $managedVolumeData = @($volumeData | Where-Object { -not $_.ExcludedFromAutoscale })
    $excludedVolumeData = @($volumeData | Where-Object { $_.ExcludedFromAutoscale })
    $excludedCurrentThroughput = ($excludedVolumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum
    if ($null -eq $excludedCurrentThroughput) { $excludedCurrentThroughput = 0 }

    # Get total minimum throughput requirements for volumes this script can safely update.
    $totalMinThroughput = ($managedVolumeData | Measure-Object -Property MinThroughputMibps -Sum).Sum
    if ($null -eq $totalMinThroughput) { $totalMinThroughput = 0 }
    $totalRequiredThroughput = $totalMinThroughput + $excludedCurrentThroughput

    if ($isFlexibleServiceLevel) {
        Write-Output "  Flexible service level: capacity and throughput are managed independently"
        Write-Output "  Current FSL pool throughput: $poolMaxThroughput MiB/s"
        Write-Output "  Minimum FSL pool throughput floor: $minimumPoolThroughputMibps MiB/s"

        $newPoolMaxThroughput = Convert-ToWholeThroughputMibps -Value ([math]::Max([double]$poolMaxThroughput, [double]$minimumPoolThroughputMibps)) -Minimum $minimumPoolThroughputMibps
        if ($totalRequiredThroughput -gt $newPoolMaxThroughput) {
            Write-Warning "Total required throughput ($totalRequiredThroughput MiB/s, including excluded volumes) exceeds current FSL pool throughput ($newPoolMaxThroughput MiB/s). The script will plan an FSL pool throughput increase before volume updates."
            $newPoolMaxThroughput = Convert-ToWholeThroughputMibps -Value $totalRequiredThroughput -Minimum $minimumPoolThroughputMibps
        }

        $poolThroughputNeedsUpdate = $newPoolMaxThroughput -ne (Convert-ToWholeThroughputMibps -Value $poolMaxThroughput -Minimum 0)
        Write-Output "  Target FSL pool throughput: $newPoolMaxThroughput MiB/s"
    } else {
        # Classic manual QoS pool throughput tracks pool size. Flexible service level pools skip this calculation.
        $classicThroughputPerTiB = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $poolServiceLevel
        $newPoolMaxThroughput = [math]::Round($classicThroughputPerTiB * $optimalPoolSizeTiB, 0)

        Write-Output "  Current pool throughput: $poolMaxThroughput MiB/s ($currentPoolSizeTiB TiB)"
        Write-Output "  Service level throughput per TiB: $classicThroughputPerTiB MiB/s ($poolServiceLevel)"
        Write-Output "  New pool throughput: $newPoolMaxThroughput MiB/s ($optimalPoolSizeTiB TiB)"
    }

    $availableThroughput = $newPoolMaxThroughput - $totalMinThroughput - $excludedCurrentThroughput
    
    if ($availableThroughput -lt 0) {
        Write-Warning "Total managed minimum throughput plus excluded volume throughput ($totalRequiredThroughput MiB/s) exceeds new pool capacity ($newPoolMaxThroughput MiB/s)"
        foreach ($volume in $managedVolumeData) {
            $volume.NewThroughputMibps = $volume.MinThroughputMibps
        }
    } else {
        # Allocate throughput proportionally based on volume size, respecting minimums
        $managedNewTotalVolumeSize = ($managedVolumeData | Measure-Object -Property NewSizeGiB -Sum).Sum
        if ($null -eq $managedNewTotalVolumeSize) { $managedNewTotalVolumeSize = 0 }
        foreach ($volume in $managedVolumeData) {
            if ($managedNewTotalVolumeSize -gt 0) {
                $proportionalThroughput = ($availableThroughput * ($volume.NewSizeGiB / $managedNewTotalVolumeSize))
                $volume.NewThroughputMibps = [math]::Round($volume.MinThroughputMibps + $proportionalThroughput, 0)
                Write-Output "    Volume '$($volume.ShortName)': Size=$($volume.NewSizeGiB)GiB, Proportion=$([math]::Round($volume.NewSizeGiB / $managedNewTotalVolumeSize, 3)), ProportionalTput=$([math]::Round($proportionalThroughput, 1))MiB/s, Total=$($volume.NewThroughputMibps)MiB/s"
            } else {
                $volume.NewThroughputMibps = $volume.MinThroughputMibps
            }
        }
    }
    
    Write-Output "  Total managed minimum throughput: $totalMinThroughput MiB/s"
    Write-Output "  Reserved excluded volume throughput: $excludedCurrentThroughput MiB/s"
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
        if (-not $volume.ExcludedFromAutoscale -and $volume.NewThroughputMibps -ne $volume.CurrentThroughputMibps -and -not $volume.NeedsResize) {
            $volumesNeedingQoSOnly += $volume
        }
    }
}

# Show change summary
Write-Output ""
Write-Output "Change summary:"
Write-Output "  Volumes needing resize: $($volumesNeedingResize.Count)"
Write-Output "  Pool resize needed: $($poolNeedsResize)"
Write-Output "  Pool service level: $poolServiceLevel"
if ($poolQosType -eq "Manual") {
    Write-Output "  Volumes needing QoS-only changes: $($volumesNeedingQoSOnly.Count)"
    if ($isFlexibleServiceLevel) {
        Write-Output "  FSL pool throughput update needed: $poolThroughputNeedsUpdate"
        if ($poolThroughputNeedsUpdate) {
            Write-Output "    -> Pool throughput: $poolMaxThroughput -> $newPoolMaxThroughput MiB/s"
        }
    }
    if ($volumesNeedingQoSOnly.Count -gt 0) {
        foreach ($volume in $volumesNeedingQoSOnly) {
            Write-Output "    → $($volume.ShortName): $($volume.CurrentThroughputMibps) → $($volume.NewThroughputMibps) MiB/s"
        }
    }
}

# Execute changes if not in test mode
if ($testMode -eq "No" -and ($volumesNeedingResize.Count -gt 0 -or $poolNeedsResize -or $volumesNeedingQoSOnly.Count -gt 0 -or $poolThroughputNeedsUpdate)) {
    Write-Output ""
    Write-Output "Executing capacity and QoS changes..."
    
    # Determine execution order based on operation type
    $isPoolExpansion = $poolAction -eq "Expand"
    $isPoolContraction = $poolAction -eq "Contract"
    $isPoolThroughputIncrease = $poolThroughputNeedsUpdate -and $newPoolMaxThroughput -gt $poolMaxThroughput
    $isPoolThroughputDecrease = $poolThroughputNeedsUpdate -and $newPoolMaxThroughput -lt $poolMaxThroughput

    if ($isFlexibleServiceLevel -and $isPoolThroughputIncrease) {
        Write-Output "FSL pool throughput increase needed - updating pool throughput before volume throughput changes..."
        Write-Output "Updating FSL pool throughput from $poolMaxThroughput MiB/s to $newPoolMaxThroughput MiB/s..."
        try {
            Update-AnfFslPoolThroughputMibps -PoolResourceId $anfPool.Id -TargetThroughputMibps $newPoolMaxThroughput
            $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
            $poolMaxThroughput = $anfPool.TotalThroughputMibps
            Write-Output "FSL pool throughput updated successfully. Current pool throughput: $poolMaxThroughput MiB/s"
        } catch {
            Write-Error "Failed to update FSL pool throughput: $_"
            Write-Output "Continuing with capacity operations; volume throughput increases that exceed current pool throughput may fail."
        }
    }
    
    # EXPANSION: Pool first, then volumes (volumes need space to grow)
    if ($isPoolExpansion -and $poolNeedsResize) {
        Write-Output "Pool expansion needed - resizing pool first..."
        Write-Output "Resizing pool from $currentPoolSizeGiB GiB to $optimalPoolSizeGiB GiB ($poolAction)..."
        try {
            $newPoolSizeBytes = $optimalPoolSizeGiB * 1024 * 1024 * 1024
            Update-AnfPoolSize -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -TargetSizeBytes $newPoolSizeBytes -IsFlexibleServiceLevel $isFlexibleServiceLevel
            
            # Refresh pool information for throughput calculations
            if ($poolQosType -eq "Manual") {
                $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
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
        if ($volume.ExcludedFromAutoscale) {
            Write-Warning "Skipping excluded volume '$($volume.ShortName)': $($volume.ExcludeReason)"
            continue
        }
        
        # Resize volume if needed
        if ($volume.NeedsResize) {
            Write-Output "Resizing volume '$($volume.ShortName)' from $($volume.CurrentSizeGiB) GiB to $($volume.NewSizeGiB) GiB ($($volume.ResizeAction))..."
            try {
                $newVolumeSizeBytes = $volume.NewSizeGiB * 1024 * 1024 * 1024
                Update-AnfVolumeCapacity -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -VolumeName $volume.ShortName -VolumeResourceId $volume.VolumeId -TargetSizeBytes $newVolumeSizeBytes -IsFlexibleServiceLevel $isFlexibleServiceLevel
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
                Update-AnfVolumeThroughput -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -VolumeName $volume.ShortName -VolumeResourceId $volume.VolumeId -TargetThroughputMibps $volume.NewThroughputMibps -IsFlexibleServiceLevel $isFlexibleServiceLevel
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
            Update-AnfPoolSize -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -TargetSizeBytes $newPoolSizeBytes -IsFlexibleServiceLevel $isFlexibleServiceLevel
            
            # Refresh pool information for throughput calculations
            if ($poolQosType -eq "Manual") {
                $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
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
        $anfPoolVerify = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
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

        if ($isFlexibleServiceLevel -and $poolThroughputNeedsUpdate) {
            $verifyPoolThroughput = Convert-ToWholeThroughputMibps -Value $anfPoolVerify.TotalThroughputMibps -Minimum 0
            if ($verifyPoolThroughput -eq $newPoolMaxThroughput) {
                Write-Output "✓ FSL pool throughput verified: $verifyPoolThroughput MiB/s (matches expected $newPoolMaxThroughput MiB/s)"
            } else {
                Write-Warning "✗ FSL pool throughput mismatch: Current=$verifyPoolThroughput MiB/s, Expected=$newPoolMaxThroughput MiB/s"
            }
        }
        
        # Verify volumes
        $anfVolumesVerify = Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
        $volumesNeedingVerification = @($volumeData | Where-Object { $_.NeedsResize -or ($poolQosType -eq "Manual" -and $_.NewThroughputMibps -ne $_.CurrentThroughputMibps) })
        
        foreach ($volume in $volumesNeedingVerification) {
            $verifyVolume = $anfVolumesVerify | Where-Object { (Get-AnfVolumeShortName -VolumeObject $_) -eq $volume.ShortName }
            if ($verifyVolume) {
                $verifyVolumeSizeGiB = [math]::Round($verifyVolume.UsageThreshold / 1024 / 1024 / 1024, 0)
                
                if ($volume.NeedsResize) {
                    if ($verifyVolumeSizeGiB -eq $volume.NewSizeGiB) {
                        Write-Output "✓ Volume '$($volume.ShortName)' size verified: $verifyVolumeSizeGiB GiB (matches expected $($volume.NewSizeGiB) GiB)"
                    } else {
                        Write-Warning "✗ Volume '$($volume.ShortName)' size mismatch: Current=$verifyVolumeSizeGiB GiB, Expected=$($volume.NewSizeGiB) GiB"
                    }
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
} elseif ($testMode -eq "Yes" -and ($volumesNeedingResize.Count -gt 0 -or $poolNeedsResize -or $volumesNeedingQoSOnly.Count -gt 0 -or $poolThroughputNeedsUpdate)) {
    Write-Output ""
    Write-Output "Test mode enabled - no changes were made"
    Write-Output "To execute these changes, set testMode to 'No' or ANF_TestMode automation variable to 'No'"
} else {
    Write-Output ""
    Write-Output "No capacity or QoS changes needed at this time"
}

Write-Output ""
Write-Output "Script execution completed successfully"
