#!/usr/bin/env pwsh
<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 07/02/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
Scale classic Azure NetApp Files capacity pool size and evenly assigned Manual QoS volume throughput based on time of day.
This script is designed for Azure Automation and can also be run manually from Cloud Shell or a local PowerShell session.

Important behavior:
- Supports Standard, Premium, and Ultra capacity pools only.
- Flexible Service Level is not supported by this script. FSL throughput decreases can be limited by a 24-hour cooldown after an increase, which does not fit this daily size-based pattern.
- This script is useful only when the classic pool is over-provisioned in capacity to reach a throughput requirement. If the pool is sized only for provisioned volume capacity, lowering the pool size may not be possible or useful.
- Auto QoS pools are converted to Manual QoS before volume throughput is assigned. In test mode, this conversion is only reported.
- Classic service level throughput per TiB is hard-coded: Standard=16, Premium=64, Ultra=128 MiB/s.

Azure Automation Account Setup Requirements:
1. REQUIRED MODULES:
   - Az.Accounts

2. REQUIRED RBAC PERMISSIONS for Managed Identity:
   - Azure NetApp Files Administrator on the target ANF account scope.

3. SETTINGS:
   Settings can be supplied as Azure Automation variables or as process environment variables with the same names.
   Azure Automation variables are used first when running in an Automation Account; otherwise environment variables are used before defaults.

   Required target settings:
   - ANF_TenantId: Azure Tenant ID (string)
   - ANF_CapacityPoolResourceId: One or more capacity pool Resource IDs separated by new lines, semicolons, or commas (string)

   Daily scaling settings:
   - ANF_TestMode: "Yes" for preview, "No" for live changes (string, default: "Yes")
   - ANF_OnHoursTiBs: Target pool size in TiB during on-hours (int, default: 2)
   - ANF_OffHoursTiBs: Target pool size in TiB during off-hours/weekends (int, default: 1)
   - ANF_DayStartTime: Business day start time in HH:mm (string, default: "08:30")
   - ANF_DayEndTime: Business day end time in HH:mm (string, default: "18:30")
   - ANF_TimeZone: Time zone ID for schedule decisions (string, default: "Central Standard Time")
   - ANF_WeekDays: Comma-separated business days (string, default: "Monday,Tuesday,Wednesday,Thursday,Friday")
   - ANF_WeekendDays: Comma-separated weekend days (string, default: "Saturday,Sunday")
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

function Convert-AnfDelimitedSetting {
    param([Parameter(Mandatory=$true)][string]$Value)

    return @("$Value" -split '[,;]+' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
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
            throw "Unsupported service level '$ServiceLevel'. This script supports Standard, Premium, and Ultra only."
        }
    }
}

function Convert-AnfTimeToMinutes {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Value
    )

    if ($Value -notmatch '^([01][0-9]|2[0-3]):([0-5][0-9])$') {
        throw "$Name must use HH:mm format, for example 08:30. Current value: '$Value'"
    }

    return ([int]$Matches[1] * 60) + [int]$Matches[2]
}

function Get-AnfTimeZoneInfo {
    param([Parameter(Mandatory=$true)][string]$TimeZoneId)

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    } catch {
        $fallbackMap = @{
            "Central Standard Time" = "America/Chicago"
            "Eastern Standard Time" = "America/New_York"
            "Mountain Standard Time" = "America/Denver"
            "Pacific Standard Time" = "America/Los_Angeles"
        }

        if ($fallbackMap.ContainsKey($TimeZoneId)) {
            try {
                return [System.TimeZoneInfo]::FindSystemTimeZoneById($fallbackMap[$TimeZoneId])
            } catch {}
        }

        throw "Unable to resolve ANF_TimeZone '$TimeZoneId'. Use a time zone ID available in this Automation runtime."
    }
}

$tenantId = Get-AnfSetting -Name "ANF_TenantId" -Default "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
$capacityPoolResourceIdSetting = Get-AnfSetting -Name "ANF_CapacityPoolResourceId"
$anfTargets = @()

if ($capacityPoolResourceIdSetting) {
    $anfTargets = @(Resolve-AnfCapacityPoolResourceIds -CapacityPoolResourceIds $capacityPoolResourceIdSetting)
} else {
    $legacySubscriptionId = Get-AnfSetting -Name "ANF_SubscriptionId" -Default "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    $legacyResourceGroupName = Get-AnfSetting -Name "ANF_ResourceGroupName" -Default "example-rg"
    $legacyAccountName = Get-AnfSetting -Name "ANF_AccountName" -Default "example-anf-acct"
    $legacyPoolName = Get-AnfSetting -Name "ANF_PoolName" -Default "example-anf-pool"
    if ($legacySubscriptionId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -and $legacyResourceGroupName -ne "example-rg" -and $legacyAccountName -ne "example-anf-acct" -and $legacyPoolName -ne "example-anf-pool") {
        $capacityPoolResourceIdSetting = "/subscriptions/$legacySubscriptionId/resourceGroups/$legacyResourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$legacyAccountName/capacityPools/$legacyPoolName"
        $anfTargets = @(Resolve-AnfCapacityPoolResourceIds -CapacityPoolResourceIds $capacityPoolResourceIdSetting)
    }
}

if ($anfTargets.Count -eq 0) {
    Write-Error "ANF_CapacityPoolResourceId must be set before running this script"
    throw "Missing required variable: ANF_CapacityPoolResourceId"
}

$onHoursTiBs = Convert-AnfSettingToInt -Name "ANF_OnHoursTiBs" -Value (Get-AnfSetting -Name "ANF_OnHoursTiBs" -Default 2) -Minimum 1
$offHoursTiBs = Convert-AnfSettingToInt -Name "ANF_OffHoursTiBs" -Value (Get-AnfSetting -Name "ANF_OffHoursTiBs" -Default 1) -Minimum 1
$dayStartTime = "$((Get-AnfSetting -Name "ANF_DayStartTime" -Default "08:30"))"
$dayEndTime = "$((Get-AnfSetting -Name "ANF_DayEndTime" -Default "18:30"))"
$timeZone = "$((Get-AnfSetting -Name "ANF_TimeZone" -Default "Central Standard Time"))"
$weekDays = @(Convert-AnfDelimitedSetting -Value "$((Get-AnfSetting -Name "ANF_WeekDays" -Default "Monday,Tuesday,Wednesday,Thursday,Friday"))")
$weekendDays = @(Convert-AnfDelimitedSetting -Value "$((Get-AnfSetting -Name "ANF_WeekendDays" -Default "Saturday,Sunday"))")
$testMode = "$((Get-AnfSetting -Name "ANF_TestMode" -Default "Yes"))"

$dayStartMinutes = Convert-AnfTimeToMinutes -Name "ANF_DayStartTime" -Value $dayStartTime
$dayEndMinutes = Convert-AnfTimeToMinutes -Name "ANF_DayEndTime" -Value $dayEndTime
if ($dayStartMinutes -ge $dayEndMinutes) {
    throw "ANF_DayStartTime must be earlier than ANF_DayEndTime. Overnight business windows are not supported."
}

$timeZoneInfo = Get-AnfTimeZoneInfo -TimeZoneId $timeZone
$localizedNow = [System.TimeZoneInfo]::ConvertTime((Get-Date), $timeZoneInfo)
$currentDay = $localizedNow.ToString("dddd", [System.Globalization.CultureInfo]::InvariantCulture)
$currentMinutes = ($localizedNow.Hour * 60) + $localizedNow.Minute
$currentTime = $localizedNow.ToString("HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
$isBusinessDay = ($weekDays -contains $currentDay) -and -not ($weekendDays -contains $currentDay)
$isOnHours = $isBusinessDay -and $currentMinutes -ge $dayStartMinutes -and $currentMinutes -lt $dayEndMinutes
$targetPeriodName = if ($isOnHours) { "on-hours" } else { "off-hours" }
$targetTiBs = if ($isOnHours) { $onHoursTiBs } else { $offHoursTiBs }

Write-Output "=== ANF Daily Pool Size Scaling Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}
Write-Output "Schedule Time Zone: $timeZone"
Write-Output "Localized Current Time: $currentDay $currentTime"
Write-Output "On-hours Window: $dayStartTime-$dayEndTime"
Write-Output "Week Days: $($weekDays -join ', ')"
Write-Output "Weekend Days: $($weekendDays -join ', ')"
Write-Output "Target Period: $targetPeriodName"
Write-Output "On-hours Target: $onHoursTiBs TiB"
Write-Output "Off-hours Target: $offHoursTiBs TiB"

if ($testMode -eq "Yes") {
    Write-Output "Running in TEST MODE - no changes will be made"
} elseif ($testMode -eq "No") {
    Write-Output "Running in LIVE MODE - changes will be applied"
} else {
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}

$anfApiVersion = "2026-04-01"
$bytesPerGiB = [math]::Pow(1024, 3)
$bytesPerTiB = [math]::Pow(1024, 4)

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
    $resolvedLocation = Get-AnfObjectProperty -InputObject $Pool -PropertyNames @('location', 'Location')

    return [PSCustomObject]@{
        Id = $Pool.id
        Name = $Pool.name
        Location = $resolvedLocation
        Size = [double]$resolvedSize
        ServiceLevel = $resolvedServiceLevel
        QosType = $resolvedQosType
        Raw = $Pool
    }
}

function Convert-AnfRestVolume {
    param([Parameter(Mandatory=$true)][object]$Volume)

    $volumeProperties = $Volume.properties
    $usageThreshold = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('usageThreshold', 'UsageThreshold')
    $throughputMibps = Get-AnfObjectProperty -InputObject $volumeProperties -PropertyNames @('throughputMibps', 'ThroughputMibps')
    if ($null -eq $throughputMibps) {
        $throughputMibps = 0
    }

    return [PSCustomObject]@{
        Id = $Volume.id
        Name = Get-AnfVolumeShortName -VolumeObject $Volume
        UsageThreshold = [double]$usageThreshold
        ThroughputMibps = [double]$throughputMibps
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
    if ($account -and $account.error) {
        throw "ANF account REST API returned error for $ResourceGroupName/$AccountName. code='$($account.error.code)' message='$($account.error.message)'"
    }

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
    if ($poolCandidate -and $poolCandidate.error) {
        throw "Capacity pool REST API returned error for $ResourceGroupName/$AccountName/$PoolName. code='$($poolCandidate.error.code)' message='$($poolCandidate.error.message)'"
    }

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

function Update-AnfPoolSize {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][long]$TargetSizeBytes
    )

    $body = @{
        properties = @{
            size = $TargetSizeBytes
        }
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $PoolResourceId -ApiVersion $anfApiVersion -BodyJson $body
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
    $capacityPoolResourceId = $anfTarget.CapacityPoolResourceId
    $subscriptionId = $anfTarget.SubscriptionId
    $resourceGroupName = $anfTarget.ResourceGroupName
    $anfAccountName = $anfTarget.AccountName
    $anfPoolName = $anfTarget.PoolName

    Write-Output ""
    Write-Output ("=" * 100)
    Write-Output "Processing capacity pool: $capacityPoolResourceId"
    Write-Output "Target subscription: $subscriptionId"
    Write-Output "Target resource group: $resourceGroupName"
    Write-Output "Target ANF account: $anfAccountName"
    Write-Output "Target capacity pool: $anfPoolName"

    try {
        Write-Output "Setting subscription context to target pool subscription: $subscriptionId"
        $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
        $updatedContext = Get-AzContext
        Write-Output "Successfully set target subscription context: $($updatedContext.Subscription.Name) ($($updatedContext.Subscription.Id))"
    } catch {
        Write-Error "Failed to set subscription context for capacity pool $capacityPoolResourceId. $_"
        throw "Subscription context failed for capacity pool $capacityPoolResourceId"
    }

    Write-Output "Connecting to ANF Account: $anfAccountName..."
    $null = Get-AnfAccount -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName
    Write-Output "Successfully connected to ANF Account: $anfAccountName"

    Write-Output "Connecting to ANF Pool: $anfPoolName..."
    $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    Write-Output "Successfully connected to ANF Pool: $anfPoolName"

    $poolSizeTiB = [math]::Round($anfPool.Size / $bytesPerTiB, 2)
    $poolServiceLevel = $anfPool.ServiceLevel
    $poolQosType = $anfPool.QosType
    Write-Output "Pool Size: $poolSizeTiB TiB ($poolServiceLevel service level, $poolQosType QoS)"

    if (Test-AnfFlexibleServiceLevel -ServiceLevel $poolServiceLevel) {
        throw "Flexible Service Level is not supported by this script. FSL throughput decreases can be limited by a 24-hour cooldown after an increase; use a dedicated FSL throughput workflow instead."
    }

    $throughputPerTiB = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $poolServiceLevel
    Write-Output "Classic throughput rate: $throughputPerTiB MiB/s per TiB ($poolServiceLevel)"

    Write-Output "Getting volumes in pool..."
    $anfVolumes = $null
    $maxRetries = 3
    $retryCount = 0
    $volumeRetrievalCompleted = $false

    while ($retryCount -lt $maxRetries -and -not $volumeRetrievalCompleted) {
        try {
            if ($retryCount -gt 0) {
                Write-Output "Retry attempt $retryCount of $($maxRetries - 1)..."
                Start-Sleep -Seconds (5 * $retryCount)
            }

            $anfVolumes = Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
            $volumeRetrievalCompleted = $true
        } catch {
            $retryCount++
            $errorMessage = $_.Exception.Message
            if ($retryCount -lt $maxRetries) {
                Write-Warning "Failed to retrieve volumes from pool (attempt $retryCount of $maxRetries): $errorMessage"
                continue
            }

            throw "Volume retrieval failed after $maxRetries attempts: $errorMessage"
        }
    }

    $volumeCount = if ($null -eq $anfVolumes) { 0 } else { @($anfVolumes).Count }
    Write-Output "Successfully retrieved $volumeCount volume(s)"

    if ($volumeCount -eq 0) {
        Write-Warning "No volumes found in Azure NetApp Files Capacity Pool '$anfPoolName'. Skipping this pool."
        continue
    }

    $totalProvisionedVolumeGiB = [math]::Round((($anfVolumes | Measure-Object -Property UsageThreshold -Sum).Sum) / $bytesPerGiB, 2)
    $minimumPoolTiBsForVolumes = [math]::Max([math]::Ceiling($totalProvisionedVolumeGiB / 1024), 1)
    if ($targetTiBs -lt $minimumPoolTiBsForVolumes) {
        throw "Target pool size is below provisioned volume capacity. Target=$targetTiBs TiB, provisioned volumes=$totalProvisionedVolumeGiB GiB, minimum pool size=$minimumPoolTiBsForVolumes TiB."
    }

    $targetPoolSizeBytes = [long]([double]$targetTiBs * $bytesPerTiB)
    $targetPoolThroughputMibps = [int]($targetTiBs * $throughputPerTiB)
    if ($targetPoolThroughputMibps -lt $volumeCount) {
        throw "Target pool throughput $targetPoolThroughputMibps MiB/s is too low to assign at least 1 MiB/s to each of $volumeCount volumes."
    }

    $targetThroughputPerVolume = [int][math]::Floor($targetPoolThroughputMibps / $volumeCount)
    if ($targetThroughputPerVolume -lt 1) {
        $targetThroughputPerVolume = 1
    }

    $poolNeedsResize = [math]::Abs([double]$anfPool.Size - [double]$targetPoolSizeBytes) -gt 1
    $qosNeedsConversion = "$poolQosType" -eq "Auto"
    $volumesNeedingThroughputUpdate = @($anfVolumes | Where-Object { [int][math]::Round($_.ThroughputMibps, 0) -ne $targetThroughputPerVolume })
    $isPoolExpansion = $targetPoolSizeBytes -gt $anfPool.Size
    $isPoolContraction = $targetPoolSizeBytes -lt $anfPool.Size

    Write-Output ""
    Write-Output "Daily scaling analysis:"
    Write-Output "  Current localized time: $currentDay $currentTime ($timeZone)"
    Write-Output "  Selected period: $targetPeriodName"
    Write-Output "  Current pool size: $poolSizeTiB TiB"
    Write-Output "  Target pool size: $targetTiBs TiB"
    Write-Output "  Provisioned volume capacity: $totalProvisionedVolumeGiB GiB"
    Write-Output "  Target pool throughput: $targetPoolThroughputMibps MiB/s"
    Write-Output "  Volume count: $volumeCount"
    Write-Output "  Target throughput per volume: $targetThroughputPerVolume MiB/s"
    Write-Output "  Pool resize needed: $poolNeedsResize"
    Write-Output "  QoS conversion needed: $qosNeedsConversion"
    Write-Output "  Volume throughput updates needed: $($volumesNeedingThroughputUpdate.Count)"

    if ($testMode -eq "Yes") {
        Write-Output ""
        Write-Output "Test mode enabled - no changes were made"
        if ($qosNeedsConversion) {
            Write-Output "TEST MODE: Capacity Pool QoS would be converted from Auto to Manual"
        }
        if ($poolNeedsResize) {
            Write-Output "TEST MODE: Capacity Pool would be resized from $poolSizeTiB TiB to $targetTiBs TiB"
        }
        foreach ($volume in $volumesNeedingThroughputUpdate) {
            Write-Output "TEST MODE: Volume '$($volume.Name)' throughput would be set from $($volume.ThroughputMibps) to $targetThroughputPerVolume MiB/s"
        }
        continue
    }

    if ($qosNeedsConversion) {
        Write-Output "Converting Capacity Pool QoS from Auto to Manual..."
        Update-AnfPoolQosTypeManual -PoolResourceId $anfPool.Id
        $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
        Write-Output "Capacity Pool QoS converted to Manual"
    }

    if ($isPoolExpansion -and $poolNeedsResize) {
        Write-Output "Expanding pool before increasing volume throughput..."
        Update-AnfPoolSize -PoolResourceId $anfPool.Id -TargetSizeBytes $targetPoolSizeBytes
        Write-Output "Capacity Pool resized to $targetTiBs TiB"
    }

    foreach ($volume in $volumesNeedingThroughputUpdate) {
        Write-Output "Updating volume '$($volume.Name)' throughput from $($volume.ThroughputMibps) to $targetThroughputPerVolume MiB/s..."
        Update-AnfVolumeThroughput -VolumeResourceId $volume.Id -TargetThroughputMibps $targetThroughputPerVolume
    }

    if ($isPoolContraction -and $poolNeedsResize) {
        Write-Output "Contracting pool after reducing volume throughput..."
        Update-AnfPoolSize -PoolResourceId $anfPool.Id -TargetSizeBytes $targetPoolSizeBytes
        Write-Output "Capacity Pool resized to $targetTiBs TiB"
    } elseif (-not $isPoolExpansion -and $poolNeedsResize) {
        Write-Output "Resizing pool..."
        Update-AnfPoolSize -PoolResourceId $anfPool.Id -TargetSizeBytes $targetPoolSizeBytes
        Write-Output "Capacity Pool resized to $targetTiBs TiB"
    }

    Write-Output "Capacity pool processing completed: $capacityPoolResourceId"
} catch {
    $failureMessage = $_.Exception.Message
    $failedCapacityPools += [PSCustomObject]@{
        CapacityPoolResourceId = $capacityPoolResourceId
        Error = $failureMessage
    }
    Write-Warning "Capacity pool processing failed for $capacityPoolResourceId. Error: $failureMessage"
    continue
}
}

if ($failedCapacityPools.Count -gt 0) {
    Write-Error "One or more capacity pools failed: $($failedCapacityPools.CapacityPoolResourceId -join ', ')"
    throw "Capacity pool processing failed for $($failedCapacityPools.Count) target(s)"
}

Write-Output ""
Write-Output "Script execution completed successfully"
