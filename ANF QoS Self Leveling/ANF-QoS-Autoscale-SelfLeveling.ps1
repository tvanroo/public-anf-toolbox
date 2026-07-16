#!/usr/bin/env pwsh
<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. Unofficial Content: Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. No Endorsement: While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. Use at Your Own Risk: Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************

Last Edit Date: 07/02/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
Reallocate Azure NetApp Files Manual QoS volume throughput based on throughputLimitReached metric pressure.
This script is designed for Azure Automation and can also be run manually from Cloud Shell or a local PowerShell session.

Important behavior:
- Supports Standard, Premium, Ultra, and Flexible Service Level capacity pools.
- Auto QoS classic pools are converted to Manual QoS when ANF_ConvertToManualMode is Yes. In test mode, this conversion is only reported.
- Classic service level throughput per TiB is hard-coded: Standard=16, Premium=64, Ultra=128 MiB/s.
- Managed volumes consume the available managed pool throughput budget; unused budget is redistributed proportionally instead of being left idle.
- If planned volume throughput exceeds current pool throughput, classic pools are expanded by capacity and FSL pools are expanded by purchased throughput before volume increases.
- FSL pool throughput decreases can be limited by a 24-hour cooldown after an increase.
- Excluded volumes keep their existing throughput allocations, and that throughput is reserved before managed-volume allocation.
- Decreases require clean throughputLimitReached windows before they are applied.
- Every configured capacity pool is processed independently; no throughput, service-level, metric, or volume math crosses pool boundaries.

Azure Automation Account Setup Requirements:
1. REQUIRED MODULES:
   - Az.Accounts

2. REQUIRED RBAC PERMISSIONS for Managed Identity:
   - Azure NetApp Files Administrator and Monitoring Reader on the target ANF account scope.

3. SETTINGS:
   Settings can be supplied as Azure Automation variables or as process environment variables with the same names.
   Azure Automation variables are used first when running in an Automation Account; otherwise environment variables are used before defaults.

   Required target settings:
   - ANF_TenantId: Azure Tenant ID (string)
   - ANF_CapacityPoolResourceId: One or more capacity pool Resource IDs separated by new lines, semicolons, or commas (string)

   QoS settings:
   - ANF_TestMode: "Yes" for preview, "No" for live changes (string, default: "Yes")
   - ANF_ConvertToManualMode: "Yes" to convert classic Auto QoS pools to Manual QoS before assigning volume throughput (string, default: "Yes")
   - ANF_MinimumThroughputPerVolume: Per-volume throughput floor in MiB/s (int, default: 1)
   - ANF_ThroughputLookBackHours: Lookback window in hours for throughputLimitReached pressure (int, default: 24)
   - ANF_DecreaseRequiredCleanDays: Count of clean trailing 24-hour windows required before decreases (int, default: 3)
   - ANF_LevelingAgressionPercent: Percent of movable throughput shifted per run (int, default: 10)
   - ANF_ThroughputLimitMetricAllowance: Maximum acceptable throughputLimitReached average (double, default: 0)
   - ANF_ExcludeTagKey / ANF_ExcludeTagValue: Volumes with this tag key/value are ignored (defaults: ExcludeFromAnfQosSelfLeveling=true)
#>

$runningInAutomation = $false
if ($env:AUTOMATION_ASSET_ACCOUNTID) {
    $runningInAutomation = $true
    Write-Output "Running in Azure Automation Account: $env:AUTOMATION_ASSET_ACCOUNTID"
}

Write-Output "Loading required Azure PowerShell modules..."
$requiredModules = @('Az.Accounts')

foreach ($module in $requiredModules) {
    try {
        Import-Module $module -Force -ErrorAction Stop
        $moduleInfo = Get-Module $module
        Write-Output "Successfully imported module: $module (Version: $($moduleInfo.Version))"
    } catch {
        Write-Error "Failed to import module $module. Please ensure it is installed."
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

function Convert-AnfSettingToInt {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][object]$Value,
        [Parameter()][int]$Minimum = 0
    )

    try {
        $converted = [int]$Value
    } catch {
        throw "$Name must be an integer. Current value: '$Value'"
    }

    if ($converted -lt $Minimum) {
        throw "$Name must be greater than or equal to $Minimum. Current value: '$Value'"
    }

    return $converted
}

function Convert-AnfSettingToDouble {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][object]$Value,
        [Parameter()][double]$Minimum = 0
    )

    try {
        $converted = [double]$Value
    } catch {
        throw "$Name must be numeric. Current value: '$Value'"
    }

    if ($converted -lt $Minimum) {
        throw "$Name must be greater than or equal to $Minimum. Current value: '$Value'"
    }

    return $converted
}

function Test-AnfYes {
    param([object]$Value)
    return "$Value".Trim().Equals("Yes", [System.StringComparison]::OrdinalIgnoreCase)
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

function Resolve-AnfCapacityPoolResourceIds {
    param([Parameter(Mandatory=$true)][string]$CapacityPoolResourceIds)

    $tokens = @("$CapacityPoolResourceIds" -split '[\r\n;,]+' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($tokens.Count -eq 0) {
        throw "ANF_CapacityPoolResourceId must contain at least one capacity pool Resource ID."
    }

    $targets = @()
    $seenResourceIds = @{}
    foreach ($token in $tokens) {
        $target = Resolve-AnfCapacityPoolResourceId -CapacityPoolResourceId $token
        $dedupeKey = $target.CapacityPoolResourceId.ToLowerInvariant()
        if ($seenResourceIds.ContainsKey($dedupeKey)) {
            Write-Warning "Duplicate capacity pool Resource ID ignored: $($target.CapacityPoolResourceId)"
            continue
        }

        $seenResourceIds[$dedupeKey] = $true
        $targets += $target
    }

    return @($targets)
}

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
            throw "Unsupported service level '$ServiceLevel'. Expected Standard, Premium, Ultra, or Flexible."
        }
    }
}

function Test-AnfTagMatch {
    param(
        [Parameter()][object]$Tags,
        [Parameter(Mandatory=$true)][string]$TagKey,
        [Parameter(Mandatory=$true)][string]$TagValue
    )

    if (-not $Tags) {
        return $false
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        if ($Tags.Contains($TagKey)) {
            return "$($Tags[$TagKey])".Equals($TagValue, [System.StringComparison]::OrdinalIgnoreCase)
        }
        return $false
    }

    $tagProperty = $Tags.PSObject.Properties | Where-Object { $_.Name -eq $TagKey } | Select-Object -First 1
    if ($tagProperty) {
        return "$($tagProperty.Value)".Equals($TagValue, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $false
}

$tenantId = Get-AnfSetting -Name "ANF_TenantId" -Default "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
$capacityPoolResourceIdSetting = Get-AnfSetting -Name "ANF_CapacityPoolResourceId"
$anfTargets = @()
if ($capacityPoolResourceIdSetting) {
    $anfTargets = @(Resolve-AnfCapacityPoolResourceIds -CapacityPoolResourceIds $capacityPoolResourceIdSetting)
}

if ($anfTargets.Count -eq 0) {
    Write-Error "ANF_CapacityPoolResourceId must be set before running this script"
    throw "Missing required variable: ANF_CapacityPoolResourceId"
}

$testMode = "$((Get-AnfSetting -Name "ANF_TestMode" -Default "Yes"))"
$convertToManualMode = "$((Get-AnfSetting -Name "ANF_ConvertToManualMode" -Default "Yes"))"
$minimumThroughputPerVolume = Convert-AnfSettingToInt -Name "ANF_MinimumThroughputPerVolume" -Value (Get-AnfSetting -Name "ANF_MinimumThroughputPerVolume" -Default 1) -Minimum 1
$throughputLookBackHours = Convert-AnfSettingToInt -Name "ANF_ThroughputLookBackHours" -Value (Get-AnfSetting -Name "ANF_ThroughputLookBackHours" -Default 24) -Minimum 1
$decreaseRequiredCleanDays = Convert-AnfSettingToInt -Name "ANF_DecreaseRequiredCleanDays" -Value (Get-AnfSetting -Name "ANF_DecreaseRequiredCleanDays" -Default 3) -Minimum 1
$levelingAgressionPercent = Convert-AnfSettingToInt -Name "ANF_LevelingAgressionPercent" -Value (Get-AnfSetting -Name "ANF_LevelingAgressionPercent" -Default 10) -Minimum 1
$throughputLimitMetricAllowance = Convert-AnfSettingToDouble -Name "ANF_ThroughputLimitMetricAllowance" -Value (Get-AnfSetting -Name "ANF_ThroughputLimitMetricAllowance" -Default 0) -Minimum 0
$excludeTagKey = "$((Get-AnfSetting -Name "ANF_ExcludeTagKey" -Default "ExcludeFromAnfQosSelfLeveling"))"
$excludeTagValue = "$((Get-AnfSetting -Name "ANF_ExcludeTagValue" -Default "true"))"
$minimumFslPoolThroughputMibps = 128

if (-not (Test-AnfYes -Value $testMode) -and -not "$testMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}
if (-not (Test-AnfYes -Value $convertToManualMode) -and -not "$convertToManualMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Convert to Manual Mode is not set to Yes or No. Exiting Script."
    throw "Invalid conversion mode configuration"
}

Write-Output "=== ANF QoS Self Leveling Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}
Write-Output "Minimum Throughput Per Volume: $minimumThroughputPerVolume MiB/s"
Write-Output "Throughput Lookback: $throughputLookBackHours hour(s)"
Write-Output "Decrease Clean Windows: $decreaseRequiredCleanDays day(s)"
Write-Output "Leveling Aggression: $levelingAgressionPercent percent"
Write-Output "Throughput Limit Metric Allowance: $throughputLimitMetricAllowance"
Write-Output "Exclude Tag: $excludeTagKey=$excludeTagValue"
Write-Output "Convert Auto QoS to Manual: $convertToManualMode"

if (Test-AnfYes -Value $testMode) {
    Write-Output "Running in TEST MODE - no changes will be made"
} else {
    Write-Output "Running in LIVE MODE - changes will be applied"
}

$anfApiVersion = "2026-04-01"
$bytesPerGiB = [math]::Pow(1024, 3)
$bytesPerTiB = [math]::Pow(1024, 4)
$poolUpdateWaitMaxSeconds = 1800
$poolUpdateWaitSleepSeconds = 20

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

function Get-AnfMetricAverageValues {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$MetricName,
        [Parameter(Mandatory=$true)][double]$LookBackHours,
        [Parameter()][datetime]$StartTimeUtc,
        [Parameter()][datetime]$EndTimeUtc,
        [Parameter()][string]$Interval = "PT5M"
    )

    if (-not $EndTimeUtc) {
        $EndTimeUtc = (Get-Date).ToUniversalTime()
    }
    if (-not $StartTimeUtc) {
        $StartTimeUtc = $EndTimeUtc.AddHours(-$LookBackHours)
    }

    $timespan = "{0:o}/{1:o}" -f $StartTimeUtc, $EndTimeUtc
    $queryString = "&metricnames=$([uri]::EscapeDataString($MetricName))&timespan=$([uri]::EscapeDataString($timespan))&interval=$Interval&aggregation=Average"
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

function Convert-AnfRestPool {
    param([Parameter(Mandatory=$true)][object]$Pool)

    $poolProperties = $Pool.properties
    $resolvedSize = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('size', 'Size')
    $resolvedServiceLevel = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('serviceLevel', 'ServiceLevel')
    $resolvedQosType = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('qosType', 'QosType')
    $resolvedProvisioningState = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('provisioningState', 'ProvisioningState')
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
        ProvisioningState = $resolvedProvisioningState
        TotalThroughputMibps = [double]$resolvedThroughputMibps
        Raw = $Pool
    }
}

function Convert-AnfRestVolume {
    param([Parameter(Mandatory=$true)][object]$Volume)

    $volumeProperties = $Volume.properties
    $usageThreshold = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('usageThreshold', 'UsageThreshold')
    $throughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $volumeProperties
    if ($null -eq $throughputMibps) {
        $throughputMibps = 0
    }

    return [PSCustomObject]@{
        Id = $Volume.id
        Name = Get-AnfVolumeShortName -VolumeObject $Volume
        UsageThreshold = [double]$usageThreshold
        ThroughputMibps = [double]$throughputMibps
        Tags = $Volume.tags
        Raw = $Volume
    }
}

function Get-AnfAccount {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName
    )

    $resourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName
    $account = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if (-not $account -or -not $account.id) {
        throw "Unable to parse ANF account REST response for $ResourceGroupName/$AccountName."
    }

    return $account
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
    if (-not $poolCandidate -or -not $poolCandidate.properties) {
        throw "Unable to parse capacity pool REST response for $ResourceGroupName/$AccountName/$PoolName."
    }

    return Convert-AnfRestPool -Pool $poolCandidate
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
    $volumes = @()
    if ($volumesCandidate -and $volumesCandidate.value) {
        $volumes = @($volumesCandidate.value)
    } elseif ($volumesCandidate -and $volumesCandidate.id) {
        $volumes = @($volumesCandidate)
    }

    return @($volumes | ForEach-Object { Convert-AnfRestVolume -Volume $_ })
}

function Update-AnfPoolQosTypeManual {
    param([Parameter(Mandatory=$true)][string]$PoolResourceId)

    $body = @{
        properties = @{
            qosType = "Manual"
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $PoolResourceId -ApiVersion $anfApiVersion -BodyJson $body
}

function Update-AnfPoolSize {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][double]$TargetSizeBytes
    )

    $body = @{
        properties = @{
            size = $TargetSizeBytes
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $PoolResourceId -ApiVersion $anfApiVersion -BodyJson $body
}

function Update-AnfVolumeThroughput {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeResourceId,
        [Parameter(Mandatory=$true)][int]$TargetThroughputMibps
    )

    $body = @{
        properties = @{
            throughputMibps = $TargetThroughputMibps
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $VolumeResourceId -ApiVersion $anfApiVersion -BodyJson $body
}

function Update-AnfFslPoolThroughput {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][int]$TargetThroughputMibps
    )

    $propertyCandidates = @("customThroughputMibps", "provisionedThroughputMibps", "totalThroughputMibps")
    $lastError = $null
    foreach ($propertyName in $propertyCandidates) {
        try {
            $body = @{
                properties = @{
                    $propertyName = $TargetThroughputMibps
                }
            } | ConvertTo-Json -Depth 3
            $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $PoolResourceId -ApiVersion "2024-07-01-preview" -BodyJson $body
            return
        } catch {
            $lastError = $_
            if ("$($_.Exception.Message)" -match "cool.?down") {
                throw "FSL pool throughput decrease is blocked by the 24-hour cooldown after a previous increase. $($_.Exception.Message)"
            }
        }
    }

    throw "Failed to update FSL pool throughput to $TargetThroughputMibps MiB/s. Last error: $($lastError.Exception.Message)"
}

function Get-AnfPoolThroughputBudgetMibps {
    param([Parameter(Mandatory=$true)][object]$Pool)

    if (Test-AnfFlexibleServiceLevel -ServiceLevel $Pool.ServiceLevel) {
        if ($Pool.QosType -ne "Manual") {
            throw "Flexible Service Level pools require Manual QoS. Pool '$($Pool.Name)' has QoS type '$($Pool.QosType)'."
        }

        if ($Pool.TotalThroughputMibps -le 0) {
            throw "Unable to determine current FSL pool throughput for '$($Pool.Name)'."
        }

        return (Convert-ToWholeThroughputMibps -Value $Pool.TotalThroughputMibps -Minimum $minimumFslPoolThroughputMibps)
    }

    $throughputPerTiB = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $Pool.ServiceLevel
    $poolTiB = [double]$Pool.Size / $bytesPerTiB
    return (Convert-ToWholeThroughputMibps -Value ($poolTiB * $throughputPerTiB) -Minimum 1)
}

function Get-AnfClassicPoolSizingForThroughput {
    param(
        [Parameter(Mandatory=$true)][object]$Pool,
        [Parameter(Mandatory=$true)][int]$TargetPoolThroughputMibps
    )

    $throughputPerTiB = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $Pool.ServiceLevel
    $requiredTiB = [int][math]::Ceiling([double]$TargetPoolThroughputMibps / [double]$throughputPerTiB)
    $currentTiB = [int][math]::Ceiling([double]$Pool.Size / $bytesPerTiB)
    $targetTiB = [math]::Max(1, [math]::Max($requiredTiB, $currentTiB))

    return [PSCustomObject]@{
        SizeTiB = [int]$targetTiB
        SizeBytes = [double]($targetTiB * $bytesPerTiB)
        ThroughputMibps = [int]($targetTiB * $throughputPerTiB)
        ThroughputPerTiB = [int]$throughputPerTiB
    }
}

function Wait-AnfPoolThroughputBudget {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][int]$TargetPoolThroughputMibps
    )

    $deadline = (Get-Date).AddSeconds($poolUpdateWaitMaxSeconds)
    do {
        $pool = Get-AnfPool -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName
        $budget = Get-AnfPoolThroughputBudgetMibps -Pool $pool
        $provisioningState = "$($pool.ProvisioningState)"
        $poolReady = [string]::IsNullOrWhiteSpace($provisioningState) -or $provisioningState.Equals("Succeeded", [System.StringComparison]::OrdinalIgnoreCase)
        if ($budget -ge $TargetPoolThroughputMibps -and $poolReady) {
            Write-Output "Confirmed pool throughput budget is $budget MiB/s."
            return $pool
        }

        if ((Get-Date) -gt $deadline) {
            throw "Timed out waiting for pool throughput budget to reach $TargetPoolThroughputMibps MiB/s and provisioning to complete. Current budget: $budget MiB/s. Current provisioning state: $provisioningState."
        }

        Write-Output "Waiting for pool throughput budget to reach $TargetPoolThroughputMibps MiB/s and provisioning to complete. Current budget: $budget MiB/s. Current provisioning state: $provisioningState."
        Start-Sleep -Seconds $poolUpdateWaitSleepSeconds
    } while ($true)
}

function Test-AnfMetricCleanForWindows {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeResourceId,
        [Parameter(Mandatory=$true)][int]$CleanWindowDays,
        [Parameter(Mandatory=$true)][double]$Allowance
    )

    $windowAnchorEnd = (Get-Date).ToUniversalTime()
    for ($dayOffset = $CleanWindowDays; $dayOffset -ge 1; $dayOffset--) {
        $windowStart = $windowAnchorEnd.AddHours(-24 * $dayOffset)
        $windowEnd = $windowAnchorEnd.AddHours(-24 * ($dayOffset - 1))
        $windowValues = @(Get-AnfMetricAverageValues -ResourceId $VolumeResourceId -MetricName 'throughputLimitReached' -LookBackHours 24 -StartTimeUtc $windowStart -EndTimeUtc $windowEnd -Interval "PT1H")
        if ($windowValues.Count -eq 0) {
            return $false
        }

        $windowMax = [double](($windowValues | Measure-Object -Maximum).Maximum)
        if ($windowMax -gt $Allowance) {
            return $false
        }
    }

    return $true
}

function Get-AnfSelfLevelingPlan {
    param(
        [Parameter(Mandatory=$true)][object[]]$Volumes,
        [Parameter(Mandatory=$true)][int]$ManagedThroughputBudgetMibps,
        [Parameter(Mandatory=$true)][int]$MinimumThroughputPerVolume,
        [Parameter(Mandatory=$true)][int]$LevelingAgressionPercent,
        [Parameter(Mandatory=$true)][double]$ThroughputLimitMetricAllowance
    )

    if ($Volumes.Count -eq 0) {
        return @()
    }

    $minimumTotal = $Volumes.Count * $MinimumThroughputPerVolume
    if ($minimumTotal -gt $ManagedThroughputBudgetMibps) {
        throw "Minimum throughput requirement exceeds available managed pool throughput. Volumes=$($Volumes.Count), MinimumPerVolume=$MinimumThroughputPerVolume MiB/s, Required=$minimumTotal MiB/s, Available=$ManagedThroughputBudgetMibps MiB/s."
    }

    $totalCurrentThroughput = [double](($Volumes | Measure-Object -Property CurrentThroughputMibps -Sum).Sum)
    $unallocatedThroughput = [math]::Max(0, $ManagedThroughputBudgetMibps - $totalCurrentThroughput)
    $volumeRows = foreach ($volume in $Volumes) {
        [PSCustomObject]@{
            ShortName = $volume.ShortName
            VolumeId = $volume.VolumeId
            ThroughputLimitMetric = [double]$volume.ThroughputLimitMetric
            CurrentThroughputMibps = [double]$volume.CurrentThroughputMibps
            CleanLastNFullDays = [bool]$volume.CleanLastNFullDays
            Performant = if ([double]$volume.ThroughputLimitMetric -le $ThroughputLimitMetricAllowance) { "Yes" } else { "No" }
            ThroughputToGiveUpMibps = 0.0
            MetricWeightPercentage = 0.0
            NewThroughputMibps = 0
            UnusedThroughputShareMibps = 0
            NetChangeInThroughputMibps = 0
        }
    }

    $nonPerformantCount = @($volumeRows | Where-Object { $_.Performant -eq "No" }).Count
    $allVolumesNonPerformant = $nonPerformantCount -eq $volumeRows.Count

    foreach ($row in $volumeRows) {
        if (($row.Performant -eq "Yes" -or $allVolumesNonPerformant) -and $row.CurrentThroughputMibps -gt $MinimumThroughputPerVolume) {
            $row.ThroughputToGiveUpMibps = [math]::Round([math]::Min(
                ($row.CurrentThroughputMibps * $LevelingAgressionPercent / 100),
                ($row.CurrentThroughputMibps - $MinimumThroughputPerVolume)
            ), 3)
        }
    }

    $totalMetric = [double](($volumeRows | Measure-Object -Property ThroughputLimitMetric -Sum).Sum)
    $totalAvailableThroughputToGiveUp = [double](($volumeRows | Measure-Object -Property ThroughputToGiveUpMibps -Sum).Sum) + $unallocatedThroughput
    if ($totalMetric -gt 0) {
        foreach ($row in $volumeRows) {
            $row.MetricWeightPercentage = [math]::Round(($row.ThroughputLimitMetric / $totalMetric) * 100, 3)
            $rawTarget = ($row.CurrentThroughputMibps - $row.ThroughputToGiveUpMibps) + ($totalAvailableThroughputToGiveUp * $row.MetricWeightPercentage / 100)
            $row.NewThroughputMibps = Convert-ToWholeThroughputMibps -Value $rawTarget -Minimum $MinimumThroughputPerVolume
        }
    } else {
        foreach ($row in $volumeRows) {
            if ($row.CleanLastNFullDays -and $row.CurrentThroughputMibps -gt $MinimumThroughputPerVolume) {
                $rawTarget = $row.CurrentThroughputMibps - $row.ThroughputToGiveUpMibps
                $row.NewThroughputMibps = Convert-ToWholeThroughputMibps -Value $rawTarget -Minimum $MinimumThroughputPerVolume
            } else {
                $row.NewThroughputMibps = Convert-ToWholeThroughputMibps -Value $row.CurrentThroughputMibps -Minimum $MinimumThroughputPerVolume
            }
        }
    }

    foreach ($row in $volumeRows) {
        if ($row.NewThroughputMibps -lt $row.CurrentThroughputMibps -and -not $row.CleanLastNFullDays) {
            $row.NewThroughputMibps = Convert-ToWholeThroughputMibps -Value $row.CurrentThroughputMibps -Minimum $MinimumThroughputPerVolume
        }
    }

    $plannedTargetTotal = [int](($volumeRows | Measure-Object -Property NewThroughputMibps -Sum).Sum)
    $targetManagedThroughputBudget = [int][math]::Max($ManagedThroughputBudgetMibps, $plannedTargetTotal)
    $remainingThroughput = [int]($targetManagedThroughputBudget - $plannedTargetTotal)
    if ($remainingThroughput -gt 0) {
        $totalTargetThroughput = [double](($volumeRows | Measure-Object -Property NewThroughputMibps -Sum).Sum)
        $totalCurrentThroughputForWeights = [double](($volumeRows | Measure-Object -Property CurrentThroughputMibps -Sum).Sum)
        $weightedRows = foreach ($row in $volumeRows) {
            $weight = if ($totalMetric -gt 0) {
                [double]$row.ThroughputLimitMetric
            } elseif ($totalTargetThroughput -gt 0) {
                [double]$row.NewThroughputMibps
            } elseif ($totalCurrentThroughputForWeights -gt 0) {
                [double]$row.CurrentThroughputMibps
            } else {
                1.0
            }

            [PSCustomObject]@{
                ShortName = $row.ShortName
                Row = $row
                Weight = $weight
                FractionalRemainder = 0.0
            }
        }

        $totalWeight = [double](($weightedRows | Measure-Object -Property Weight -Sum).Sum)
        if ($totalWeight -le 0) {
            foreach ($weightedRow in $weightedRows) {
                $weightedRow.Weight = 1.0
            }
            $totalWeight = [double]$weightedRows.Count
        }

        $extraAllocatedThroughput = 0
        foreach ($weightedRow in $weightedRows) {
            $rawExtra = ([double]$remainingThroughput * [double]$weightedRow.Weight) / $totalWeight
            $extraThroughput = [int][math]::Floor($rawExtra)
            $weightedRow.FractionalRemainder = [double]($rawExtra - $extraThroughput)
            if ($extraThroughput -gt 0) {
                $weightedRow.Row.NewThroughputMibps += $extraThroughput
                $weightedRow.Row.UnusedThroughputShareMibps += $extraThroughput
                $extraAllocatedThroughput += $extraThroughput
            }
        }

        $roundingRemainder = [int]($remainingThroughput - $extraAllocatedThroughput)
        if ($roundingRemainder -gt 0) {
            foreach ($weightedRow in @($weightedRows | Sort-Object -Property FractionalRemainder, ShortName -Descending | Select-Object -First $roundingRemainder)) {
                $weightedRow.Row.NewThroughputMibps += 1
                $weightedRow.Row.UnusedThroughputShareMibps += 1
            }
        }
    }

    foreach ($row in $volumeRows) {
        $row.NetChangeInThroughputMibps = [int]($row.NewThroughputMibps - (Convert-ToWholeThroughputMibps -Value $row.CurrentThroughputMibps -Minimum 0))
    }

    return @($volumeRows | Sort-Object -Property NetChangeInThroughputMibps, ShortName)
}

Write-Output "Authenticating to Azure..."
try {
    try {
        $null = Disable-AzContextAutosave -Scope Process -ErrorAction Stop
        Write-Output "Disabled Az context autosave for this run"
    } catch {
        Write-Warning "Unable to disable Az context autosave: $($_.Exception.Message)"
    }

    if ($runningInAutomation) {
        Write-Output "Connecting using Managed Identity..."
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Output "Successfully authenticated using Managed Identity"
    } else {
        try {
            $currentContext = Get-AzContext -ErrorAction Stop
            if ($currentContext -and $currentContext.Account -and $currentContext.Account.Id) {
                Write-Output "Already authenticated to Azure as: $($currentContext.Account.Id)"
                if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -and $currentContext.Tenant.Id -ne $tenantId) {
                    Write-Output "Switching to specified tenant: $tenantId"
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                }
            } else {
                if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                } else {
                    $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
                }
            }
        } catch {
            Write-Output "No valid existing Azure context found; starting device authentication."
            if ($tenantId -and $tenantId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") {
                $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
            } else {
                $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
            }
        }
    }

    $context = Get-AzContext
    Write-Output "Azure Context: $($context.Account.Id) in subscription $($context.Subscription.Name)"
} catch {
    Write-Error "Failed to authenticate to Azure: $_"
    throw "Authentication failed"
}

$failedCapacityPools = @()
foreach ($anfTarget in $anfTargets) {
try {
    $subscriptionId = $anfTarget.SubscriptionId
    $resourceGroupName = $anfTarget.ResourceGroupName
    $anfAccountName = $anfTarget.AccountName
    $anfPoolName = $anfTarget.PoolName

    Write-Output ""
    Write-Output ("=" * 100)
    Write-Output "Processing capacity pool: $($anfTarget.CapacityPoolResourceId)"

    try {
        $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    } catch {
        throw "Failed to set Azure context to target subscription '$subscriptionId': $($_.Exception.Message)"
    }

    $null = Get-AnfAccount -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName
    $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    $isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel -ServiceLevel $anfPool.ServiceLevel

    Write-Output "Pool details: ServiceLevel=$($anfPool.ServiceLevel); QoS=$($anfPool.QosType); SizeGiB=$([math]::Round($anfPool.Size / $bytesPerGiB, 0)); TotalThroughputMibps=$($anfPool.TotalThroughputMibps)"

    if ($anfPool.QosType -ne "Manual") {
        if ($isFlexibleServiceLevel) {
            throw "Flexible Service Level pools require Manual QoS. Pool '$anfPoolName' has QoS type '$($anfPool.QosType)'."
        }
        if (-not (Test-AnfYes -Value $convertToManualMode)) {
            throw "Manual QoS is required. Pool '$anfPoolName' is '$($anfPool.QosType)' and ANF_ConvertToManualMode is '$convertToManualMode'."
        }
        if (Test-AnfYes -Value $testMode) {
            Write-Output "TEST MODE: Capacity pool QoS would be converted from '$($anfPool.QosType)' to Manual before volume throughput updates."
        } else {
            Write-Output "Converting capacity pool QoS from '$($anfPool.QosType)' to Manual..."
            Update-AnfPoolQosTypeManual -PoolResourceId $anfPool.Id
            $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
        }
    }

    $poolThroughputBudgetMibps = Get-AnfPoolThroughputBudgetMibps -Pool $anfPool
    if ($isFlexibleServiceLevel) {
        Write-Output "FSL uses the current manual pool throughput as the self-leveling budget: $poolThroughputBudgetMibps MiB/s"
    } else {
        $classicRate = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $anfPool.ServiceLevel
        Write-Output "Classic service level throughput budget: $classicRate MiB/s per TiB x $([math]::Round($anfPool.Size / $bytesPerTiB, 3)) TiB = $poolThroughputBudgetMibps MiB/s"
    }

    $anfVolumes = @(Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName)
    if ($anfVolumes.Count -eq 0) {
        Write-Warning "No volumes found in Azure NetApp Files capacity pool '$anfPoolName'. Skipping pool."
        continue
    }

    $excludedVolumes = @()
    $managedVolumes = @()
    foreach ($anfVolume in $anfVolumes) {
        if (Test-AnfTagMatch -Tags $anfVolume.Tags -TagKey $excludeTagKey -TagValue $excludeTagValue) {
            $excludedVolumes += $anfVolume
        } else {
            $managedVolumes += $anfVolume
        }
    }
    if ($managedVolumes.Count -eq 0) {
        Write-Warning "All volumes in '$anfPoolName' are excluded by tag $excludeTagKey=$excludeTagValue. Skipping pool."
        continue
    }

    $excludedThroughputMibps = [int][math]::Round([double](($excludedVolumes | Measure-Object -Property ThroughputMibps -Sum).Sum), 0, [System.MidpointRounding]::AwayFromZero)
    $managedThroughputBudgetMibps = [int]($poolThroughputBudgetMibps - $excludedThroughputMibps)
    $minimumManagedThroughputMibps = [int]($managedVolumes.Count * $minimumThroughputPerVolume)
    $planningManagedThroughputBudgetMibps = [int][math]::Max($managedThroughputBudgetMibps, $minimumManagedThroughputMibps)
    Write-Output "Excluded volume throughput reserved: $excludedThroughputMibps MiB/s across $($excludedVolumes.Count) volume(s)"
    Write-Output "Current managed throughput budget: $managedThroughputBudgetMibps MiB/s"
    if ($managedThroughputBudgetMibps -lt $minimumManagedThroughputMibps) {
        Write-Warning "Current pool throughput cannot satisfy excluded volume reservations and managed volume minimums. The run will plan a pool throughput increase before managed volume updates."
    }

    $volumeInputs = foreach ($anfVolume in $managedVolumes) {
        $metricValues = @(Get-AnfMetricAverageValues -ResourceId $anfVolume.Id -MetricName 'throughputLimitReached' -LookBackHours $throughputLookBackHours)
        $throughputLimitMetric = 0
        if ($metricValues.Count -gt 0) {
            $throughputLimitMetric = [math]::Round([double](($metricValues | Measure-Object -Average).Average), 3)
        }
        $cleanLastNFullDays = Test-AnfMetricCleanForWindows -VolumeResourceId $anfVolume.Id -CleanWindowDays $decreaseRequiredCleanDays -Allowance $throughputLimitMetricAllowance
        [PSCustomObject]@{
            ShortName = $anfVolume.Name
            VolumeId = $anfVolume.Id
            ThroughputLimitMetric = $throughputLimitMetric
            CurrentThroughputMibps = $anfVolume.ThroughputMibps
            CleanLastNFullDays = $cleanLastNFullDays
        }
    }

    $finalData = @(Get-AnfSelfLevelingPlan -Volumes $volumeInputs -ManagedThroughputBudgetMibps $planningManagedThroughputBudgetMibps -MinimumThroughputPerVolume $minimumThroughputPerVolume -LevelingAgressionPercent $levelingAgressionPercent -ThroughputLimitMetricAllowance $throughputLimitMetricAllowance)
    $plannedManagedTargetThroughputMibps = [int](($finalData | Measure-Object -Property NewThroughputMibps -Sum).Sum)
    $plannedPoolTargetThroughputMibps = [int]($plannedManagedTargetThroughputMibps + $excludedThroughputMibps)
    $classicPoolTargetSizing = $null

    if ($isFlexibleServiceLevel) {
        if ($plannedPoolTargetThroughputMibps -lt $minimumFslPoolThroughputMibps) {
            $plannedPoolTargetThroughputMibps = $minimumFslPoolThroughputMibps
        }
        $expandedManagedThroughputBudgetMibps = [int]($plannedPoolTargetThroughputMibps - $excludedThroughputMibps)
        if ($expandedManagedThroughputBudgetMibps -gt $plannedManagedTargetThroughputMibps) {
            $finalData = @(Get-AnfSelfLevelingPlan -Volumes $volumeInputs -ManagedThroughputBudgetMibps $expandedManagedThroughputBudgetMibps -MinimumThroughputPerVolume $minimumThroughputPerVolume -LevelingAgressionPercent $levelingAgressionPercent -ThroughputLimitMetricAllowance $throughputLimitMetricAllowance)
            $plannedManagedTargetThroughputMibps = [int](($finalData | Measure-Object -Property NewThroughputMibps -Sum).Sum)
            $plannedPoolTargetThroughputMibps = [int]($plannedManagedTargetThroughputMibps + $excludedThroughputMibps)
        }
    } else {
        if ($plannedPoolTargetThroughputMibps -gt $poolThroughputBudgetMibps) {
            $classicPoolTargetSizing = Get-AnfClassicPoolSizingForThroughput -Pool $anfPool -TargetPoolThroughputMibps $plannedPoolTargetThroughputMibps
            $expandedManagedThroughputBudgetMibps = [int]($classicPoolTargetSizing.ThroughputMibps - $excludedThroughputMibps)
            $finalData = @(Get-AnfSelfLevelingPlan -Volumes $volumeInputs -ManagedThroughputBudgetMibps $expandedManagedThroughputBudgetMibps -MinimumThroughputPerVolume $minimumThroughputPerVolume -LevelingAgressionPercent $levelingAgressionPercent -ThroughputLimitMetricAllowance $throughputLimitMetricAllowance)
            $plannedManagedTargetThroughputMibps = [int](($finalData | Measure-Object -Property NewThroughputMibps -Sum).Sum)
            $plannedPoolTargetThroughputMibps = [int]($plannedManagedTargetThroughputMibps + $excludedThroughputMibps)
        }
    }

    $currentManagedAllocatedThroughputMibps = [int][math]::Round([double](($finalData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum), 0, [System.MidpointRounding]::AwayFromZero)
    $unallocatedThroughputMibps = [int]($managedThroughputBudgetMibps - $currentManagedAllocatedThroughputMibps)
    $unallocatedRow = [PSCustomObject]@{
        ShortName = if ($unallocatedThroughputMibps -lt 0) { "overallocated" } else { "unallocated" }
        VolumeId = ""
        ThroughputLimitMetric = 0
        CurrentThroughputMibps = $unallocatedThroughputMibps
        CleanLastNFullDays = $true
        Performant = ""
        ThroughputToGiveUpMibps = [math]::Max(0, $unallocatedThroughputMibps)
        MetricWeightPercentage = 0
        NewThroughputMibps = 0
        NetChangeInThroughputMibps = 0
    }

    $displayData = @($finalData + $unallocatedRow)
    $displayData | Select-Object ShortName, ThroughputLimitMetric, Performant, CleanLastNFullDays, CurrentThroughputMibps, ThroughputToGiveUpMibps, MetricWeightPercentage, NewThroughputMibps, NetChangeInThroughputMibps | Format-Table -AutoSize

    $poolThroughputDeltaMibps = $plannedPoolTargetThroughputMibps - $poolThroughputBudgetMibps
    Write-Output "Planned managed target throughput: $plannedManagedTargetThroughputMibps MiB/s"
    Write-Output "Planned pool throughput target including excluded reservations: $plannedPoolTargetThroughputMibps MiB/s (delta $poolThroughputDeltaMibps MiB/s)"
    if ($isFlexibleServiceLevel) {
        Write-Output "Planned FSL pool throughput target: $plannedPoolTargetThroughputMibps MiB/s (delta $poolThroughputDeltaMibps MiB/s)"
    } elseif ($classicPoolTargetSizing) {
        Write-Output "Planned classic pool capacity target: $($classicPoolTargetSizing.SizeTiB) TiB for $($classicPoolTargetSizing.ThroughputMibps) MiB/s at $($classicPoolTargetSizing.ThroughputPerTiB) MiB/s per TiB"
    }

    $updates = @($finalData | Where-Object { $_.NetChangeInThroughputMibps -ne 0 })
    if ($updates.Count -eq 0 -and $poolThroughputDeltaMibps -eq 0) {
        Write-Output "All managed volumes in pool '$anfPoolName' are already at the self-leveling throughput values."
        continue
    }

    if (Test-AnfYes -Value $testMode) {
        if ((-not $isFlexibleServiceLevel) -and $poolThroughputDeltaMibps -gt 0 -and $classicPoolTargetSizing) {
            Write-Output "TEST MODE: Classic pool capacity would be increased to $($classicPoolTargetSizing.SizeTiB) TiB before volume throughput increases, raising available throughput to $($classicPoolTargetSizing.ThroughputMibps) MiB/s."
        } elseif ($isFlexibleServiceLevel -and $poolThroughputDeltaMibps -gt 0) {
            Write-Output "TEST MODE: FSL pool throughput would be increased to $plannedPoolTargetThroughputMibps MiB/s before volume updates."
        } elseif ($isFlexibleServiceLevel -and $poolThroughputDeltaMibps -lt 0) {
            Write-Output "TEST MODE: FSL pool throughput would be decreased to $plannedPoolTargetThroughputMibps MiB/s after volume updates. Decreases may be deferred by the 24-hour cooldown."
        }
        foreach ($row in $updates) {
            Write-Output "TEST MODE: Volume '$($row.ShortName)' throughput would change from $($row.CurrentThroughputMibps) to $($row.NewThroughputMibps) MiB/s"
        }
        continue
    }

    if ((-not $isFlexibleServiceLevel) -and $poolThroughputDeltaMibps -gt 0 -and $classicPoolTargetSizing) {
        Write-Output "Increasing classic pool capacity before volume updates: $([math]::Round($anfPool.Size / $bytesPerTiB, 3)) -> $($classicPoolTargetSizing.SizeTiB) TiB"
        Update-AnfPoolSize -PoolResourceId $anfPool.Id -TargetSizeBytes $classicPoolTargetSizing.SizeBytes
        $anfPool = Wait-AnfPoolThroughputBudget -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -TargetPoolThroughputMibps $plannedPoolTargetThroughputMibps
    } elseif ($isFlexibleServiceLevel -and $poolThroughputDeltaMibps -gt 0) {
        Write-Output "Increasing FSL pool throughput before volume updates: $poolThroughputBudgetMibps -> $plannedPoolTargetThroughputMibps MiB/s"
        Update-AnfFslPoolThroughput -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
        $anfPool = Wait-AnfPoolThroughputBudget -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -TargetPoolThroughputMibps $plannedPoolTargetThroughputMibps
    }

    foreach ($row in @($updates | Sort-Object -Property NetChangeInThroughputMibps, ShortName)) {
        Write-Output "Updating volume '$($row.ShortName)' throughput from $($row.CurrentThroughputMibps) to $($row.NewThroughputMibps) MiB/s..."
        Update-AnfVolumeThroughput -VolumeResourceId $row.VolumeId -TargetThroughputMibps $row.NewThroughputMibps
    }

    if ($isFlexibleServiceLevel -and $poolThroughputDeltaMibps -lt 0) {
        try {
            Write-Output "Decreasing FSL pool throughput after volume updates: $poolThroughputBudgetMibps -> $plannedPoolTargetThroughputMibps MiB/s"
            Update-AnfFslPoolThroughput -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
        } catch {
            Write-Warning "FSL pool throughput decrease was deferred. ANF can enforce a 24-hour cooldown after increases. Error: $($_.Exception.Message)"
        }
    }

    Write-Output "Completed self-leveling updates for pool '$anfPoolName'."
}
catch {
    Write-Error "Failed processing capacity pool '$($anfTarget.CapacityPoolResourceId)': $($_.Exception.Message)"
    $failedCapacityPools += [PSCustomObject]@{
        CapacityPoolResourceId = $anfTarget.CapacityPoolResourceId
        Error = $_.Exception.Message
    }
}
}

if ($failedCapacityPools.Count -gt 0) {
    Write-Error "One or more capacity pools failed: $($failedCapacityPools.CapacityPoolResourceId -join ', ')"
    throw "ANF QoS Self Leveling failed for $($failedCapacityPools.Count) pool(s)."
}

Write-Output "ANF QoS Self Leveling completed."
