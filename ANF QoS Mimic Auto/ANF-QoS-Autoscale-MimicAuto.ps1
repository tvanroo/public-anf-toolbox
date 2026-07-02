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
Allocate Azure NetApp Files Manual QoS volume throughput to mimic Auto QoS by assigning each volume a share of the pool throughput based on provisioned volume size.
This script is designed for Azure Automation and can also be run manually from Cloud Shell or a local PowerShell session.

Important behavior:
- Supports Standard, Premium, Ultra, and Flexible Service Level capacity pools.
- Auto QoS pools are converted to Manual QoS when ANF_ConvertToManualMode is Yes. In test mode, this conversion is only reported.
- Classic service level throughput per TiB is hard-coded: Standard=16, Premium=64, Ultra=128 MiB/s.
- FSL uses the current manual pool throughput as the mimic-auto budget. The script does not purchase, increase, or decrease FSL pool throughput.
- Every configured capacity pool is processed independently; no capacity, throughput, or service-level math crosses pool boundaries.

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

   QoS settings:
   - ANF_TestMode: "Yes" for preview, "No" for live changes (string, default: "Yes")
   - ANF_ConvertToManualMode: "Yes" to convert classic Auto QoS pools to Manual QoS before assigning volume throughput (string, default: "Yes")
   - ANF_MinimumThroughputPerVolume: Per-volume throughput floor in MiB/s (int, default: 1)
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

if (-not (Test-AnfYes -Value $testMode) -and -not "$testMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Test Mode is not set to Yes or No. Exiting Script."
    throw "Invalid test mode configuration"
}
if (-not (Test-AnfYes -Value $convertToManualMode) -and -not "$convertToManualMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Convert to Manual Mode is not set to Yes or No. Exiting Script."
    throw "Invalid conversion mode configuration"
}

Write-Output "=== ANF QoS Mimic Auto Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Tenant ID: $tenantId"
Write-Output "Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}
Write-Output "Minimum Throughput Per Volume: $minimumThroughputPerVolume MiB/s"
Write-Output "Convert Auto QoS to Manual: $convertToManualMode"

if (Test-AnfYes -Value $testMode) {
    Write-Output "Running in TEST MODE - no changes will be made"
} else {
    Write-Output "Running in LIVE MODE - changes will be applied"
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

function Get-AnfPoolThroughputBudgetMibps {
    param([Parameter(Mandatory=$true)][object]$Pool)

    if (Test-AnfFlexibleServiceLevel -ServiceLevel $Pool.ServiceLevel) {
        if ($Pool.QosType -ne "Manual") {
            throw "Flexible Service Level pools require Manual QoS. Pool '$($Pool.Name)' has QoS type '$($Pool.QosType)'."
        }

        if ($Pool.TotalThroughputMibps -le 0) {
            throw "Unable to determine current FSL pool throughput for '$($Pool.Name)'."
        }

        return (Convert-ToWholeThroughputMibps -Value $Pool.TotalThroughputMibps -Minimum 1)
    }

    $throughputPerTiB = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $Pool.ServiceLevel
    $poolTiB = [double]$Pool.Size / $bytesPerTiB
    return (Convert-ToWholeThroughputMibps -Value ($poolTiB * $throughputPerTiB) -Minimum 1)
}

function Get-AnfMimicAutoPlan {
    param(
        [Parameter(Mandatory=$true)][object[]]$Volumes,
        [Parameter(Mandatory=$true)][int]$PoolThroughputBudgetMibps,
        [Parameter(Mandatory=$true)][int]$MinimumThroughputPerVolume
    )

    if ($Volumes.Count -eq 0) {
        return @()
    }

    $minimumTotal = $Volumes.Count * $MinimumThroughputPerVolume
    if ($minimumTotal -gt $PoolThroughputBudgetMibps) {
        throw "Minimum throughput requirement exceeds available pool throughput. Volumes=$($Volumes.Count), MinimumPerVolume=$MinimumThroughputPerVolume MiB/s, Required=$minimumTotal MiB/s, Available=$PoolThroughputBudgetMibps MiB/s."
    }

    $totalSizeGiB = [double](($Volumes | Measure-Object -Property SizeGiB -Sum).Sum)
    if ($totalSizeGiB -le 0) {
        throw "Total volume size is 0 GiB. Cannot calculate mimic-auto allocation."
    }

    $remainingThroughput = $PoolThroughputBudgetMibps - $minimumTotal
    $planRows = foreach ($volume in $Volumes) {
        $rawTarget = $MinimumThroughputPerVolume + (($remainingThroughput * [double]$volume.SizeGiB) / $totalSizeGiB)
        $floorTarget = [math]::Floor($rawTarget)
        [PSCustomObject]@{
            ShortName = $volume.ShortName
            VolumeId = $volume.VolumeId
            SizeGiB = $volume.SizeGiB
            CapacityPercentage = [math]::Round(([double]$volume.SizeGiB / $totalSizeGiB) * 100, 3)
            CurrentThroughputMibps = [int][math]::Round([double]$volume.CurrentThroughputMibps, 0, [System.MidpointRounding]::AwayFromZero)
            NewThroughputMibps = [int]$floorTarget
            FractionalRemainder = [double]($rawTarget - $floorTarget)
            NetChangeInThroughputMibps = 0
        }
    }

    $allocatedThroughput = [int](($planRows | Measure-Object -Property NewThroughputMibps -Sum).Sum)
    $remainingRoundingThroughput = $PoolThroughputBudgetMibps - $allocatedThroughput
    if ($remainingRoundingThroughput -gt 0) {
        foreach ($row in @($planRows | Sort-Object -Property FractionalRemainder, ShortName -Descending | Select-Object -First $remainingRoundingThroughput)) {
            $row.NewThroughputMibps += 1
        }
    }

    foreach ($row in $planRows) {
        $row.NetChangeInThroughputMibps = $row.NewThroughputMibps - $row.CurrentThroughputMibps
    }

    return @($planRows | Sort-Object -Property NetChangeInThroughputMibps, ShortName)
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
            Write-Output "Capacity pool QoS after conversion: $($anfPool.QosType)"
        }
    }

    $poolThroughputBudgetMibps = Get-AnfPoolThroughputBudgetMibps -Pool $anfPool
    if ($isFlexibleServiceLevel) {
        Write-Output "FSL uses the current manual pool throughput as the mimic-auto budget: $poolThroughputBudgetMibps MiB/s"
    } else {
        $classicRate = Get-AnfClassicManualThroughputPerTiB -ServiceLevel $anfPool.ServiceLevel
        Write-Output "Classic service level throughput budget: $classicRate MiB/s per TiB x $([math]::Round($anfPool.Size / $bytesPerTiB, 3)) TiB = $poolThroughputBudgetMibps MiB/s"
    }

    $anfVolumes = @(Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName)
    if ($anfVolumes.Count -eq 0) {
        Write-Output "No volumes found in Azure NetApp Files capacity pool '$anfPoolName'. Skipping pool."
        continue
    }

    $volumeInputs = foreach ($anfVolume in $anfVolumes) {
        [PSCustomObject]@{
            ShortName = $anfVolume.Name
            VolumeId = $anfVolume.Id
            SizeGiB = [math]::Round($anfVolume.UsageThreshold / $bytesPerGiB, 3)
            CurrentThroughputMibps = $anfVolume.ThroughputMibps
        }
    }

    $finalData = @(Get-AnfMimicAutoPlan -Volumes $volumeInputs -PoolThroughputBudgetMibps $poolThroughputBudgetMibps -MinimumThroughputPerVolume $minimumThroughputPerVolume)
    $totalCurrentThroughputMibps = [int](($finalData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum)
    $unallocatedThroughputMibps = $poolThroughputBudgetMibps - $totalCurrentThroughputMibps
    $unallocatedSizeGiB = [math]::Round(($anfPool.Size / $bytesPerGiB) - (($volumeInputs | Measure-Object -Property SizeGiB -Sum).Sum), 3)
    $unallocatedRow = [PSCustomObject]@{
        ShortName = "unallocated"
        VolumeId = ""
        SizeGiB = $unallocatedSizeGiB
        CapacityPercentage = 0
        CurrentThroughputMibps = $unallocatedThroughputMibps
        NewThroughputMibps = 0
        FractionalRemainder = 0
        NetChangeInThroughputMibps = 0
    }

    $displayData = @($finalData + $unallocatedRow)
    $displayData | Select-Object ShortName, SizeGiB, CapacityPercentage, CurrentThroughputMibps, NewThroughputMibps, NetChangeInThroughputMibps | Format-Table -AutoSize

    $targetThroughputTotal = [int](($finalData | Measure-Object -Property NewThroughputMibps -Sum).Sum)
    Write-Output "Planned managed volume throughput total: $targetThroughputTotal MiB/s of $poolThroughputBudgetMibps MiB/s"

    $updates = @($finalData | Where-Object { $_.NetChangeInThroughputMibps -ne 0 })
    if ($updates.Count -eq 0) {
        Write-Output "All volumes in pool '$anfPoolName' are already at the mimic-auto throughput values."
        continue
    }

    if (Test-AnfYes -Value $testMode) {
        foreach ($row in $updates) {
            Write-Output "TEST MODE: Volume '$($row.ShortName)' throughput would change from $($row.CurrentThroughputMibps) to $($row.NewThroughputMibps) MiB/s"
        }
        continue
    }

    foreach ($row in @($updates | Sort-Object -Property NetChangeInThroughputMibps, ShortName)) {
        Write-Output "Updating volume '$($row.ShortName)' throughput from $($row.CurrentThroughputMibps) to $($row.NewThroughputMibps) MiB/s..."
        Update-AnfVolumeThroughput -VolumeResourceId $row.VolumeId -TargetThroughputMibps $row.NewThroughputMibps
    }

    Write-Output "Completed throughput updates for pool '$anfPoolName'."
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
    throw "ANF QoS Mimic Auto failed for $($failedCapacityPools.Count) pool(s)."
}

Write-Output "ANF QoS Mimic Auto completed."
