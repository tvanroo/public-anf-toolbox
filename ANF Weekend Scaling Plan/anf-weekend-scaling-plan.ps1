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
Move Azure NetApp Files volumes between Auto QoS classic-service-level pools for weekend cost savings.
This script is designed for Azure Automation and can also be run manually from Cloud Shell or a local PowerShell session.

Important behavior:
- Supports Standard, Premium, and Ultra capacity pools only.
- Flexible Service Level is not supported by this script. FSL throughput decreases can be limited by a 24-hour cooldown after an increase, which does not fit this pool-move schedule pattern.
- Auto QoS only: the script moves volumes between classic Auto QoS pools and does not assign Manual QoS volume throughput.
- The initial capacity pool Resource ID identifies the subscription, resource group, ANF account, and initial pool name. After the first move, the initial pool may no longer exist; the Resource ID still identifies the managed pool set.
- The script creates the missing target pool, moves all volumes with the ANF poolChange REST action, and removes the previous source pool only after the move requests complete.
- Every configured pool set is processed independently; no pool state or schedule decision crosses target boundaries.

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
   - ANF_CapacityPoolResourceId: One or more initial capacity pool Resource IDs separated by new lines, semicolons, or commas (string)

   Weekend scaling settings:
   - ANF_TestMode: "Yes" for preview, "No" for live changes (string, default: "Yes")
   - ANF_WeekdayPoolName: Weekday target pool name. Blank defaults to "<initial-pool>-weekday" (string)
   - ANF_WeekendPoolName: Weekend target pool name. Blank defaults to "<initial-pool>-weekend" (string)
   - ANF_WeekdayServiceLevel: Weekday service level: Standard, Premium, or Ultra (string, default: "Ultra")
   - ANF_WeekendServiceLevel: Weekend service level: Standard, Premium, or Ultra (string, default: "Standard")
   - ANF_WeekendStartDay: Weekend window start day (string, default: "Friday")
   - ANF_WeekendStartTime: Weekend window start time in HH:mm (string, default: "18:00")
   - ANF_WeekendFullDays: Comma-separated full weekend days (string, default: "Saturday,Sunday")
   - ANF_WeekendEndDay: Weekend window end day (string, default: "Monday")
   - ANF_WeekendEndTime: Weekend window end time in HH:mm (string, default: "06:00")
   - ANF_TimeZone: Time zone ID for schedule decisions (string, default: "Central Standard Time")
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

function Convert-AnfDelimitedSetting {
    param([Parameter(Mandatory=$true)][string]$Value)

    return @("$Value" -split '[,;]+' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
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

function Test-AnfFlexibleServiceLevel {
    param([object]$ServiceLevel)

    if ($null -eq $ServiceLevel) {
        return $false
    }

    return "$ServiceLevel".Trim().ToLowerInvariant() -eq "flexible"
}

function Resolve-AnfClassicServiceLevel {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Value
    )

    switch ("$Value".Trim()) {
        "Standard" { return "Standard" }
        "Premium" { return "Premium" }
        "Ultra" { return "Ultra" }
        default {
            throw "$Name must be Standard, Premium, or Ultra. Flexible Service Level is not supported by this script because FSL throughput decreases can be limited by a 24-hour cooldown after an increase."
        }
    }
}

function Convert-AnfTimeToMinutes {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Value
    )

    if ($Value -notmatch '^([01][0-9]|2[0-3]):([0-5][0-9])$') {
        throw "$Name must use HH:mm format, for example 18:00. Current value: '$Value'"
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

function Test-AnfWeekendWindow {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentDay,
        [Parameter(Mandatory=$true)][int]$CurrentMinutes,
        [Parameter(Mandatory=$true)][string]$WeekendStartDay,
        [Parameter(Mandatory=$true)][int]$WeekendStartMinutes,
        [Parameter(Mandatory=$true)][string[]]$WeekendFullDays,
        [Parameter(Mandatory=$true)][string]$WeekendEndDay,
        [Parameter(Mandatory=$true)][int]$WeekendEndMinutes
    )

    return (
        ($CurrentDay -eq $WeekendStartDay -and $CurrentMinutes -ge $WeekendStartMinutes) -or
        ($WeekendFullDays -contains $CurrentDay) -or
        ($CurrentDay -eq $WeekendEndDay -and $CurrentMinutes -le $WeekendEndMinutes)
    )
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
$weekdayPoolNameSetting = "$((Get-AnfSetting -Name "ANF_WeekdayPoolName" -Default ([string]::Empty)))".Trim()
$weekendPoolNameSetting = "$((Get-AnfSetting -Name "ANF_WeekendPoolName" -Default ([string]::Empty)))".Trim()
$weekdayServiceLevel = Resolve-AnfClassicServiceLevel -Name "ANF_WeekdayServiceLevel" -Value "$((Get-AnfSetting -Name "ANF_WeekdayServiceLevel" -Default "Ultra"))"
$weekendServiceLevel = Resolve-AnfClassicServiceLevel -Name "ANF_WeekendServiceLevel" -Value "$((Get-AnfSetting -Name "ANF_WeekendServiceLevel" -Default "Standard"))"
$weekendStartDay = "$((Get-AnfSetting -Name "ANF_WeekendStartDay" -Default "Friday"))".Trim()
$weekendStartTime = "$((Get-AnfSetting -Name "ANF_WeekendStartTime" -Default "18:00"))".Trim()
$weekendFullDays = @(Convert-AnfDelimitedSetting -Value "$((Get-AnfSetting -Name "ANF_WeekendFullDays" -Default "Saturday,Sunday"))")
$weekendEndDay = "$((Get-AnfSetting -Name "ANF_WeekendEndDay" -Default "Monday"))".Trim()
$weekendEndTime = "$((Get-AnfSetting -Name "ANF_WeekendEndTime" -Default "06:00"))".Trim()
$timeZone = "$((Get-AnfSetting -Name "ANF_TimeZone" -Default "Central Standard Time"))"

if (-not (Test-AnfYes -Value $testMode) -and -not "$testMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}
if ($weekendFullDays -contains $weekendStartDay -or $weekendFullDays -contains $weekendEndDay) {
    throw "ANF_WeekendFullDays must not include ANF_WeekendStartDay or ANF_WeekendEndDay."
}

$weekendStartMinutes = Convert-AnfTimeToMinutes -Name "ANF_WeekendStartTime" -Value $weekendStartTime
$weekendEndMinutes = Convert-AnfTimeToMinutes -Name "ANF_WeekendEndTime" -Value $weekendEndTime
$timeZoneInfo = Get-AnfTimeZoneInfo -TimeZoneId $timeZone
$localizedNow = [System.TimeZoneInfo]::ConvertTime((Get-Date), $timeZoneInfo)
$currentDay = $localizedNow.ToString("dddd", [System.Globalization.CultureInfo]::InvariantCulture)
$currentMinutes = ($localizedNow.Hour * 60) + $localizedNow.Minute
$currentTime = $localizedNow.ToString("HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
$isWeekendWindow = Test-AnfWeekendWindow -CurrentDay $currentDay -CurrentMinutes $currentMinutes -WeekendStartDay $weekendStartDay -WeekendStartMinutes $weekendStartMinutes -WeekendFullDays $weekendFullDays -WeekendEndDay $weekendEndDay -WeekendEndMinutes $weekendEndMinutes
$targetPoolLabel = if ($isWeekendWindow) { "weekend" } else { "weekday" }
$targetServiceLevel = if ($isWeekendWindow) { $weekendServiceLevel } else { $weekdayServiceLevel }

Write-Output "=== ANF Weekend Scaling Plan Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}
Write-Output "Schedule Time Zone: $timeZone"
Write-Output "Localized Current Time: $currentDay $currentTime"
Write-Output "Weekend Window: $weekendStartDay $weekendStartTime through $weekendEndDay $weekendEndTime"
Write-Output "Weekend Full Days: $($weekendFullDays -join ', ')"
Write-Output "Target Pool Label: $targetPoolLabel"
Write-Output "Target Service Level: $targetServiceLevel"
Write-Output "Weekday Service Level: $weekdayServiceLevel"
Write-Output "Weekend Service Level: $weekendServiceLevel"
Write-Output "Auto QoS only: Manual QoS pools are rejected"

if (Test-AnfYes -Value $testMode) {
    Write-Output "Running in TEST MODE - no changes will be made"
} else {
    Write-Output "Running in LIVE MODE - changes will be applied"
}

$anfApiVersion = "2026-04-01"

function Get-AnfArmToken {
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

    return [PSCustomObject]@{
        ResourceManagerUrl = $resourceManagerUrl
        AccessToken = $token
    }
}

function Get-AnfResponseHeaderValue {
    param(
        [Parameter(Mandatory=$true)][object]$Headers,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if (-not $Headers.ContainsKey($Name)) {
        return $null
    }

    $value = $Headers[$Name]
    if ($value -is [array]) {
        return ($value | Select-Object -First 1)
    }

    return $value
}

function Wait-AnfArmOperation {
    param(
        [Parameter(Mandatory=$true)][object]$InitialResponse,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [Parameter()][int]$TimeoutSeconds = 3600
    )

    $pollUrl = Get-AnfResponseHeaderValue -Headers $InitialResponse.Headers -Name "Azure-AsyncOperation"
    if (-not $pollUrl) {
        $pollUrl = Get-AnfResponseHeaderValue -Headers $InitialResponse.Headers -Name "Location"
    }

    if (-not $pollUrl) {
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $retryAfter = Get-AnfResponseHeaderValue -Headers $InitialResponse.Headers -Name "Retry-After"
        if (-not $retryAfter) {
            $retryAfter = 15
        }

        Start-Sleep -Seconds ([int]$retryAfter)
        $pollResponse = Invoke-WebRequest -Uri $pollUrl -Method "GET" -Headers $Headers -UseBasicParsing -SkipHttpErrorCheck
        if ($pollResponse.StatusCode -ge 400) {
            throw "ARM long-running operation poll failed with HTTP $($pollResponse.StatusCode): $($pollResponse.Content)"
        }

        $status = $null
        if ($pollResponse.Content) {
            try {
                $statusBody = $pollResponse.Content | ConvertFrom-Json -ErrorAction Stop
                $status = $statusBody.status
            } catch {}
        }

        if (-not $status -and $pollResponse.StatusCode -ge 200 -and $pollResponse.StatusCode -lt 300) {
            return
        }

        if ($status -in @("Succeeded", "Success")) {
            return
        }
        if ($status -in @("Failed", "Canceled", "Cancelled")) {
            throw "ARM long-running operation failed with status '$status'. Response: $($pollResponse.Content)"
        }
    } while ((Get-Date) -lt $deadline)

    throw "ARM long-running operation did not complete within $TimeoutSeconds seconds. Poll URL: $pollUrl"
}

function Invoke-AnfArmJson {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter()][string]$QueryString = "",
        [Parameter()][string]$BodyJson,
        [Parameter()][switch]$WaitForCompletion,
        [Parameter()][switch]$AllowNotFound
    )

    $tokenInfo = Get-AnfArmToken
    $normalizedQueryString = ""
    if ($QueryString) {
        $normalizedQueryString = "$QueryString"
        if ($normalizedQueryString.StartsWith("?")) {
            $normalizedQueryString = "&$($normalizedQueryString.Substring(1))"
        } elseif (-not $normalizedQueryString.StartsWith("&")) {
            $normalizedQueryString = "&$normalizedQueryString"
        }
    }

    $uri = "$($tokenInfo.ResourceManagerUrl)$ResourceId" + "?api-version=$ApiVersion$normalizedQueryString"
    $headers = @{
        'Authorization' = "Bearer $($tokenInfo.AccessToken)"
        'Content-Type' = 'application/json'
    }

    $invokeParams = @{
        Uri = $uri
        Method = $Method
        Headers = $headers
        UseBasicParsing = $true
        SkipHttpErrorCheck = $true
    }
    if ($BodyJson) {
        $invokeParams['Body'] = $BodyJson
    }

    $response = Invoke-WebRequest @invokeParams
    if ($response.StatusCode -eq 404 -and $AllowNotFound) {
        return $null
    }
    if ($response.StatusCode -ge 400) {
        throw "ARM $Method failed for $ResourceId with HTTP $($response.StatusCode): $($response.Content)"
    }

    if ($WaitForCompletion) {
        Wait-AnfArmOperation -InitialResponse $response -Headers $headers
    }

    if ($response.Content) {
        try {
            return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            return $response.Content
        }
    }

    return $null
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
    $resolvedCoolAccess = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('coolAccess', 'CoolAccess')
    $resolvedEncryptionType = Get-AnfObjectProperty -InputObject $poolProperties -PropertyNames @('encryptionType', 'EncryptionType')
    $resolvedTags = Get-AnfObjectProperty -InputObject $Pool -PropertyNames @('tags', 'Tags')

    return [PSCustomObject]@{
        Id = $Pool.id
        Name = $Pool.name
        Location = $resolvedLocation
        Size = [double]$resolvedSize
        ServiceLevel = $resolvedServiceLevel
        QosType = $resolvedQosType
        CoolAccess = $resolvedCoolAccess
        EncryptionType = $resolvedEncryptionType
        Tags = $resolvedTags
        Raw = $Pool
    }
}

function Convert-AnfRestVolume {
    param([Parameter(Mandatory=$true)][object]$Volume)

    return [PSCustomObject]@{
        Id = $Volume.id
        Name = Get-AnfVolumeShortName -VolumeObject $Volume
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
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter()][switch]$AllowNotFound
    )

    $resourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName
    $poolCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion -AllowNotFound:$AllowNotFound
    if ($null -eq $poolCandidate -and $AllowNotFound) {
        return $null
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
    $volumes = @()
    if ($volumesCandidate -and $volumesCandidate.value) {
        $volumes = @($volumesCandidate.value)
    } elseif ($volumesCandidate -and $volumesCandidate.id) {
        $volumes = @($volumesCandidate)
    }

    return @($volumes | ForEach-Object { Convert-AnfRestVolume -Volume $_ })
}

function Get-AnfPoolState {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $pool = Get-AnfPool -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName -AllowNotFound
    $volumes = @()
    if ($pool) {
        $volumes = @(Get-AnfVolumes -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName)
    }

    return [PSCustomObject]@{
        Label = $Label
        PoolName = $PoolName
        Pool = $pool
        Volumes = $volumes
        VolumeCount = $volumes.Count
    }
}

function New-AnfPool {
    param(
        [Parameter(Mandatory=$true)][object]$SourcePool,
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$TargetPoolName,
        [Parameter(Mandatory=$true)][string]$TargetServiceLevel
    )

    $targetPoolResourceId = New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $TargetPoolName
    $properties = @{
        serviceLevel = $TargetServiceLevel
        size = [long]$SourcePool.Size
        qosType = "Auto"
    }

    if ($null -ne $SourcePool.CoolAccess -and "$($SourcePool.CoolAccess)" -ne "") {
        $properties.coolAccess = [bool]$SourcePool.CoolAccess
    }
    if ($SourcePool.EncryptionType) {
        $properties.encryptionType = $SourcePool.EncryptionType
    }

    $body = @{
        location = $SourcePool.Location
        properties = $properties
    }
    if ($SourcePool.Tags) {
        $body.tags = $SourcePool.Tags
    }

    $bodyJson = $body | ConvertTo-Json -Depth 10
    $null = Invoke-AnfArmJson -Method "PUT" -ResourceId $targetPoolResourceId -ApiVersion $anfApiVersion -BodyJson $bodyJson -WaitForCompletion
    return Get-AnfPool -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $TargetPoolName
}

function Move-AnfVolumeToPool {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeResourceId,
        [Parameter(Mandatory=$true)][string]$TargetPoolResourceId
    )

    $body = @{
        newPoolResourceId = $TargetPoolResourceId
    } | ConvertTo-Json -Depth 3

    $null = Invoke-AnfArmJson -Method "POST" -ResourceId "$VolumeResourceId/poolChange" -ApiVersion $anfApiVersion -BodyJson $body -WaitForCompletion
}

function Remove-AnfPool {
    param([Parameter(Mandatory=$true)][string]$PoolResourceId)

    $null = Invoke-AnfArmJson -Method "DELETE" -ResourceId $PoolResourceId -ApiVersion $anfApiVersion -WaitForCompletion
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

$failedPoolSets = @()
foreach ($anfTarget in $anfTargets) {
try {
    $subscriptionId = $anfTarget.SubscriptionId
    $resourceGroupName = $anfTarget.ResourceGroupName
    $anfAccountName = $anfTarget.AccountName
    $initialPoolName = $anfTarget.PoolName
    $weekdayPoolName = if ($weekdayPoolNameSetting) { $weekdayPoolNameSetting } else { "$initialPoolName-weekday" }
    $weekendPoolName = if ($weekendPoolNameSetting) { $weekendPoolNameSetting } else { "$initialPoolName-weekend" }

    if ($initialPoolName -eq $weekdayPoolName -or $initialPoolName -eq $weekendPoolName -or $weekdayPoolName -eq $weekendPoolName) {
        throw "Initial, weekday, and weekend pool names must be unique. Initial='$initialPoolName'; Weekday='$weekdayPoolName'; Weekend='$weekendPoolName'."
    }

    Write-Output ""
    Write-Output ("=" * 100)
    Write-Output "Processing managed pool set from initial pool Resource ID: $($anfTarget.CapacityPoolResourceId)"
    Write-Output "Target subscription: $subscriptionId"
    Write-Output "Target ANF account: $anfAccountName"
    Write-Output "Initial pool name: $initialPoolName"
    Write-Output "Weekday pool name: $weekdayPoolName ($weekdayServiceLevel)"
    Write-Output "Weekend pool name: $weekendPoolName ($weekendServiceLevel)"

    try {
        $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    } catch {
        throw "Failed to set Azure context to target subscription '$subscriptionId': $($_.Exception.Message)"
    }

    $null = Get-AnfAccount -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName
    $states = @(
        Get-AnfPoolState -Label "initial" -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $initialPoolName
        Get-AnfPoolState -Label "weekday" -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekdayPoolName
        Get-AnfPoolState -Label "weekend" -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $weekendPoolName
    )

    foreach ($state in $states) {
        if ($state.Pool) {
            Write-Output "Pool state: $($state.Label) pool '$($state.PoolName)' exists; serviceLevel=$($state.Pool.ServiceLevel); qosType=$($state.Pool.QosType); volumes=$($state.VolumeCount)"
            if (Test-AnfFlexibleServiceLevel -ServiceLevel $state.Pool.ServiceLevel) {
                throw "Flexible Service Level is not supported by this script. Pool '$($state.PoolName)' is Flexible. FSL throughput decreases can be limited by a 24-hour cooldown after an increase."
            }
            if ($state.Pool.QosType -ne "Auto") {
                throw "Auto QoS only: pool '$($state.PoolName)' has QoS type '$($state.Pool.QosType)'. This script does not manage Manual QoS volume throughput."
            }
        } else {
            Write-Output "Pool state: $($state.Label) pool '$($state.PoolName)' does not exist."
        }
    }

    $activeStates = @($states | Where-Object { $_.VolumeCount -gt 0 })
    if ($activeStates.Count -gt 1) {
        throw "More than one managed pool currently contains volumes. Resolve the ambiguous state before running automation. Active pools: $($activeStates.PoolName -join ', ')"
    }
    if ($activeStates.Count -eq 0) {
        throw "No volumes found in the initial, weekday, or weekend pools for account '$anfAccountName'. Nothing can be moved."
    }

    $sourceState = $activeStates[0]
    $desiredPoolName = if ($targetPoolLabel -eq "weekend") { $weekendPoolName } else { $weekdayPoolName }
    $desiredState = $states | Where-Object { $_.PoolName -eq $desiredPoolName } | Select-Object -First 1
    $sourcePool = $sourceState.Pool
    $volumesToMove = @($sourceState.Volumes)

    Write-Output "Active pool: $($sourceState.PoolName) ($($sourceState.Label))"
    Write-Output "Desired pool for current schedule: $desiredPoolName ($targetPoolLabel)"
    Write-Output "Volumes in active pool: $($volumesToMove.Count)"

    if ($sourceState.PoolName -eq $desiredPoolName) {
        if ($sourcePool.ServiceLevel -ne $targetServiceLevel) {
            throw "Active target pool '$desiredPoolName' has service level '$($sourcePool.ServiceLevel)' but expected '$targetServiceLevel'. Correct the pool or settings before continuing."
        }

        Write-Output "The active volumes are already in the correct $targetPoolLabel pool for the current schedule."
        continue
    }

    if ($desiredState.Pool -and $desiredState.Pool.ServiceLevel -ne $targetServiceLevel) {
        throw "Existing target pool '$desiredPoolName' has service level '$($desiredState.Pool.ServiceLevel)' but expected '$targetServiceLevel'."
    }

    if (Test-AnfYes -Value $testMode) {
        Write-Output "TEST MODE: Would ensure target pool '$desiredPoolName' exists with service level '$targetServiceLevel' and size copied from '$($sourceState.PoolName)'."
        foreach ($volume in $volumesToMove) {
            Write-Output "TEST MODE: Would move volume '$($volume.Name)' from '$($sourceState.PoolName)' to '$desiredPoolName'."
        }
        Write-Output "TEST MODE: Would remove source pool '$($sourceState.PoolName)' after successful volume moves."
        continue
    }

    $targetPool = $desiredState.Pool
    if (-not $targetPool) {
        Write-Output "Creating target pool '$desiredPoolName' with service level '$targetServiceLevel'..."
        $targetPool = New-AnfPool -SourcePool $sourcePool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -TargetPoolName $desiredPoolName -TargetServiceLevel $targetServiceLevel
        Write-Output "Target pool created: $($targetPool.Id)"
    } else {
        Write-Output "Using existing empty target pool: $($targetPool.Id)"
    }

    foreach ($volume in $volumesToMove) {
        Write-Output "Moving volume '$($volume.Name)' from '$($sourceState.PoolName)' to '$desiredPoolName'..."
        Move-AnfVolumeToPool -VolumeResourceId $volume.Id -TargetPoolResourceId $targetPool.Id
    }

    Write-Output "Removing source pool '$($sourceState.PoolName)' after completed volume moves..."
    Remove-AnfPool -PoolResourceId $sourcePool.Id
    Write-Output "Completed weekend scaling move for managed pool set '$initialPoolName'."
}
catch {
    $failedPoolSets += [PSCustomObject]@{
        CapacityPoolResourceId = $anfTarget.CapacityPoolResourceId
        Error = $_.Exception.Message
    }
    Write-Warning "Weekend scaling failed for $($anfTarget.CapacityPoolResourceId). Error: $($_.Exception.Message)"
    continue
}
}

if ($failedPoolSets.Count -gt 0) {
    Write-Error "One or more managed pool sets failed: $($failedPoolSets.CapacityPoolResourceId -join ', ')"
    throw "ANF Weekend Scaling failed for $($failedPoolSets.Count) managed pool set(s)."
}

Write-Output "ANF Weekend Scaling Plan completed."
