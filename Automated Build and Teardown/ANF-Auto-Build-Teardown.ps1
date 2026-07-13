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
Create or delete a small Azure NetApp Files test layout: account, capacity pool, and sequentially named volumes.
This script is intended for lab/test environments, not production teardown workflows.

Important safety behavior:
- ANF_TestMode defaults to Yes. In test mode, create/delete actions are only reported.
- Delete mode with ANF_TestMode=No requires ANF_DeleteConfirmation to exactly match DELETE <account>/<pool>.
- The script is non-interactive so it can be reviewed, rerun, and automated without hidden prompts.

Supported service levels:
- Standard, Premium, Ultra, and Flexible.
- Flexible Service Level always uses Manual QoS and requires a pool throughput value.
- Large-volume creation can be requested with ANF_IsLargeVolume=Yes.
#>

$ErrorActionPreference = "Stop"
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

function Test-AnfFlexibleServiceLevel {
    param([object]$ServiceLevel)
    return "$ServiceLevel".Trim().Equals("Flexible", [System.StringComparison]::OrdinalIgnoreCase)
}

function Split-AnfSettingList {
    param([Parameter()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return @()
    }

    return @("$Value" -split '[\r\n;,]+' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

$tenantId = [string](Get-AnfSetting -Name "ANF_TenantId" -Default "")
$subscriptionId = [string](Get-AnfSetting -Name "ANF_SubscriptionId" -Default "")
$resourceGroupName = [string](Get-AnfSetting -Name "ANF_ResourceGroupName")
$anfAccountName = [string](Get-AnfSetting -Name "ANF_AccountName")
$anfPoolName = [string](Get-AnfSetting -Name "ANF_PoolName")
$location = [string](Get-AnfSetting -Name "ANF_Location")
$operation = [string](Get-AnfSetting -Name "ANF_Operation" -Default "Create")
$testMode = [string](Get-AnfSetting -Name "ANF_TestMode" -Default "Yes")
$serviceLevel = [string](Get-AnfSetting -Name "ANF_ServiceLevel" -Default "Standard")
$qosType = [string](Get-AnfSetting -Name "ANF_QosType" -Default "Auto")
$poolSizeTiB = Convert-AnfSettingToInt -Name "ANF_PoolSizeTiB" -Value (Get-AnfSetting -Name "ANF_PoolSizeTiB" -Default 1) -Minimum 1
$volumePrefix = [string](Get-AnfSetting -Name "ANF_VolumePrefix" -Default "Vol")
$volumeCount = Convert-AnfSettingToInt -Name "ANF_VolumeCount" -Value (Get-AnfSetting -Name "ANF_VolumeCount" -Default 3) -Minimum 0
$volumeSizeGiB = Convert-AnfSettingToInt -Name "ANF_VolumeSizeGiB" -Value (Get-AnfSetting -Name "ANF_VolumeSizeGiB" -Default 60) -Minimum 1
$delegatedSubnetId = [string](Get-AnfSetting -Name "ANF_DelegatedSubnetId" -Default "")
$networkFeatures = [string](Get-AnfSetting -Name "ANF_NetworkFeatures" -Default "Standard")
$protocolTypes = @(Split-AnfSettingList -Value (Get-AnfSetting -Name "ANF_ProtocolTypes" -Default "NFSv3"))
$volumeThroughputMibps = Convert-AnfSettingToInt -Name "ANF_VolumeThroughputMibps" -Value (Get-AnfSetting -Name "ANF_VolumeThroughputMibps" -Default 1) -Minimum 1
$fslPoolThroughputMibps = Convert-AnfSettingToInt -Name "ANF_FslPoolThroughputMibps" -Value (Get-AnfSetting -Name "ANF_FslPoolThroughputMibps" -Default 128) -Minimum 128
$isLargeVolumeSetting = [string](Get-AnfSetting -Name "ANF_IsLargeVolume" -Default "No")
$largeVolumeMaximumSizeGiB = Convert-AnfSettingToInt -Name "ANF_LargeVolumeMaximumSizeGiB" -Value (Get-AnfSetting -Name "ANF_LargeVolumeMaximumSizeGiB" -Default 1048576) -Minimum 51200
$deleteConfirmation = [string](Get-AnfSetting -Name "ANF_DeleteConfirmation" -Default "")
$waitSleepSeconds = Convert-AnfSettingToInt -Name "ANF_WaitSleepSeconds" -Value (Get-AnfSetting -Name "ANF_WaitSleepSeconds" -Default 30) -Minimum 1
$waitMaxSeconds = Convert-AnfSettingToInt -Name "ANF_WaitMaxSeconds" -Value (Get-AnfSetting -Name "ANF_WaitMaxSeconds" -Default 3600) -Minimum 60

$bytesPerGiB = [int64]1073741824
$bytesPerTiB = [int64]1099511627776
$anfApiVersion = "2026-04-01"

if ([string]::IsNullOrWhiteSpace($resourceGroupName)) { throw "ANF_ResourceGroupName is required." }
if ([string]::IsNullOrWhiteSpace($anfAccountName)) { throw "ANF_AccountName is required." }
if ([string]::IsNullOrWhiteSpace($anfPoolName)) { throw "ANF_PoolName is required." }
if ([string]::IsNullOrWhiteSpace($location)) { throw "ANF_Location is required." }

$operation = $operation.Trim()
if ($operation -notin @("Create", "Delete")) {
    throw "ANF_Operation must be Create or Delete. Current value: '$operation'"
}

if (-not (Test-AnfYes -Value $testMode) -and -not "$testMode".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ANF_TestMode must be Yes or No. Current value: '$testMode'"
}

if ($serviceLevel -notin @("Standard", "Premium", "Ultra", "Flexible")) {
    throw "ANF_ServiceLevel must be Standard, Premium, Ultra, or Flexible. Current value: '$serviceLevel'"
}

$isFlexibleServiceLevel = Test-AnfFlexibleServiceLevel -ServiceLevel $serviceLevel
if ($qosType -notin @("Auto", "Manual")) {
    throw "ANF_QosType must be Auto or Manual. Current value: '$qosType'"
}

if ($isFlexibleServiceLevel -and $qosType -ne "Manual") {
    Write-Warning "Flexible Service Level requires Manual QoS. ANF_QosType '$qosType' will be treated as Manual."
    $qosType = "Manual"
}

if (Test-AnfYes -Value $isLargeVolumeSetting) {
    $minimumVolumeSizeGiB = 51200
    if ($volumeSizeGiB -lt $minimumVolumeSizeGiB) {
        throw "ANF_IsLargeVolume is Yes, so ANF_VolumeSizeGiB must be at least $minimumVolumeSizeGiB GiB."
    }
    if ($volumeSizeGiB -gt $largeVolumeMaximumSizeGiB) {
        throw "ANF_VolumeSizeGiB exceeds ANF_LargeVolumeMaximumSizeGiB ($largeVolumeMaximumSizeGiB GiB)."
    }
} else {
    if ($volumeSizeGiB -lt 50) {
        throw "Regular ANF volumes must be at least 50 GiB."
    }
}

if ($operation -eq "Create" -and [string]::IsNullOrWhiteSpace($delegatedSubnetId)) {
    throw "ANF_DelegatedSubnetId is required for Create operations."
}

$poolSizeBytes = [int64]$poolSizeTiB * $bytesPerTiB
$volumeSizeBytes = [int64]$volumeSizeGiB * $bytesPerGiB
$accountResourceId = $null
$poolResourceId = $null

Write-Output "=== ANF Auto Build/Teardown Configuration ==="
Write-Output "Operation: $operation"
Write-Output "Test Mode: $testMode"
Write-Output "Resource Group: $resourceGroupName"
Write-Output "ANF Account: $anfAccountName"
Write-Output "Capacity Pool: $anfPoolName"
Write-Output "Location: $location"
Write-Output "Service Level: $serviceLevel"
Write-Output "QoS Type: $qosType"
Write-Output "Pool Size: $poolSizeTiB TiB"
Write-Output "Volumes: $volumeCount x $volumeSizeGiB GiB, prefix '$volumePrefix'"
Write-Output "Large Volumes: $isLargeVolumeSetting"
if ($isFlexibleServiceLevel) {
    Write-Output "FSL Pool Throughput: $fslPoolThroughputMibps MiB/s"
}
if ($qosType -eq "Manual") {
    Write-Output "Volume Throughput: $volumeThroughputMibps MiB/s"
}

if (Test-AnfYes -Value $testMode) {
    Write-Output "Running in TEST MODE - no Azure resources will be created or deleted"
} else {
    Write-Output "Running in LIVE MODE - Azure resources may be created or deleted"
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

function Get-AnfResourceOrNull {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion
    )

    try {
        return Invoke-AnfArmJson -Method "GET" -ResourceId $ResourceId -ApiVersion $ApiVersion
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }

        if ($_.ErrorDetails.Message -match '"code"\s*:\s*"ResourceNotFound"') {
            return $null
        }

        throw
    }
}

function Get-AnfResourceCollectionValues {
    param(
        [Parameter(Mandatory=$true)][string]$CollectionResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion
    )

    $response = Get-AnfResourceOrNull -ResourceId $CollectionResourceId -ApiVersion $ApiVersion
    if ($response -and $response.value) {
        return @($response.value)
    }

    return @()
}

function Get-AnfResourceShortName {
    param([Parameter(Mandatory=$true)][object]$Resource)

    if ($Resource.name) {
        $name = [string]$Resource.name
        if ($name.Contains('/')) {
            return $name.Split('/')[-1]
        }

        return $name
    }

    if ($Resource.id -and "$($Resource.id)" -match '/([^/]+)$') {
        return $Matches[1]
    }

    return ""
}

function New-AnfResourceId {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter()][string]$AccountName,
        [Parameter()][string]$PoolName,
        [Parameter()][string]$VolumeName
    )

    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    if ($AccountName) {
        $resourceId = "$resourceId/providers/Microsoft.NetApp/netAppAccounts/$AccountName"
    }
    if ($PoolName) {
        $resourceId = "$resourceId/capacityPools/$PoolName"
    }
    if ($VolumeName) {
        $resourceId = "$resourceId/volumes/$VolumeName"
    }

    return $resourceId
}

function Wait-AnfProvisioningState {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter()][string]$DesiredState = "Succeeded",
        [Parameter()][switch]$WaitForDelete
    )

    $deadline = (Get-Date).AddSeconds($waitMaxSeconds)
    do {
        $resource = Get-AnfResourceOrNull -ResourceId $ResourceId -ApiVersion $ApiVersion
        if ($WaitForDelete) {
            if ($null -eq $resource) {
                return
            }
        } elseif ($resource -and $resource.properties -and $resource.properties.provisioningState -eq $DesiredState) {
            return
        }

        if ((Get-Date) -gt $deadline) {
            if ($WaitForDelete) {
                throw "Timed out waiting for resource deletion: $ResourceId"
            }
            $state = if ($resource -and $resource.properties) { $resource.properties.provisioningState } else { "not found" }
            throw "Timed out waiting for provisioning state '$DesiredState' on $ResourceId. Current state: $state"
        }

        Start-Sleep -Seconds $waitSleepSeconds
    } while ($true)
}

function Wait-AnfChildResourceCollectionEmpty {
    param(
        [Parameter(Mandatory=$true)][string]$CollectionResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter(Mandatory=$true)][string]$ResourceTypeLabel
    )

    $deadline = (Get-Date).AddSeconds($waitMaxSeconds)
    do {
        $remainingResources = @(Get-AnfResourceCollectionValues -CollectionResourceId $CollectionResourceId -ApiVersion $ApiVersion)
        if ($remainingResources.Count -eq 0) {
            Write-Output "Confirmed no remaining $ResourceTypeLabel."
            return
        }

        if ((Get-Date) -gt $deadline) {
            $remainingNames = @($remainingResources | ForEach-Object { Get-AnfResourceShortName -Resource $_ }) -join ', '
            throw "Timed out waiting for $ResourceTypeLabel to be removed. Remaining: $remainingNames"
        }

        $remainingNamesForLog = @($remainingResources | ForEach-Object { Get-AnfResourceShortName -Resource $_ }) -join ', '
        Write-Output "Waiting for $ResourceTypeLabel to be removed. Remaining: $remainingNamesForLog"
        Start-Sleep -Seconds $waitSleepSeconds
    } while ($true)
}

function Wait-AnfNamedChildAbsent {
    param(
        [Parameter(Mandatory=$true)][string]$CollectionResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter(Mandatory=$true)][string]$ChildName,
        [Parameter(Mandatory=$true)][string]$ResourceTypeLabel
    )

    $deadline = (Get-Date).AddSeconds($waitMaxSeconds)
    do {
        $remainingResources = @(Get-AnfResourceCollectionValues -CollectionResourceId $CollectionResourceId -ApiVersion $ApiVersion)
        $matchingResources = @($remainingResources | Where-Object {
            (Get-AnfResourceShortName -Resource $_).Equals($ChildName, [System.StringComparison]::OrdinalIgnoreCase)
        })

        if ($matchingResources.Count -eq 0) {
            Write-Output "Confirmed $ResourceTypeLabel '$ChildName' is no longer listed by the parent resource."
            return
        }

        if ((Get-Date) -gt $deadline) {
            $states = @($matchingResources | ForEach-Object {
                if ($_.properties -and $_.properties.provisioningState) {
                    "$ChildName ($($_.properties.provisioningState))"
                } else {
                    $ChildName
                }
            }) -join ', '
            throw "Timed out waiting for $ResourceTypeLabel '$ChildName' to disappear from parent collection. Remaining: $states"
        }

        Write-Output "Waiting for $ResourceTypeLabel '$ChildName' to disappear from parent collection."
        Start-Sleep -Seconds $waitSleepSeconds
    } while ($true)
}

function New-AnfAccountBodyJson {
    return @{
        location = $location
        properties = @{}
        tags = @{
            "managed-by" = "public-anf-toolbox"
            "solution" = "anf-auto-build-teardown"
        }
    } | ConvertTo-Json -Depth 6
}

function New-AnfPoolBodyJson {
    $properties = @{
        serviceLevel = $serviceLevel
        size = $poolSizeBytes
        qosType = $qosType
    }

    if ($isFlexibleServiceLevel) {
        $properties.customThroughputMibps = $fslPoolThroughputMibps
    }

    return @{
        location = $location
        properties = $properties
        tags = @{
            "managed-by" = "public-anf-toolbox"
            "solution" = "anf-auto-build-teardown"
        }
    } | ConvertTo-Json -Depth 8
}

function New-AnfVolumeBodyJson {
    param([Parameter(Mandatory=$true)][string]$VolumeName)

    $properties = @{
        creationToken = $VolumeName
        serviceLevel = $serviceLevel
        subnetId = $delegatedSubnetId
        usageThreshold = $volumeSizeBytes
        networkFeatures = $networkFeatures
        protocolTypes = $protocolTypes
    }

    if ($qosType -eq "Manual") {
        $properties.throughputMibps = $volumeThroughputMibps
    }

    if (Test-AnfYes -Value $isLargeVolumeSetting) {
        $properties.isLargeVolume = $true
    }

    return @{
        location = $location
        properties = $properties
        tags = @{
            "managed-by" = "public-anf-toolbox"
            "solution" = "anf-auto-build-teardown"
        }
    } | ConvertTo-Json -Depth 8
}

Write-Output "Authenticating to Azure..."
try {
    try {
        $null = Disable-AzContextAutosave -Scope Process -ErrorAction Stop
    } catch {
        Write-Warning "Unable to disable Az context autosave: $($_.Exception.Message)"
    }

    if ($runningInAutomation) {
        $null = Connect-AzAccount -Identity -ErrorAction Stop
    } else {
        try {
            $currentContext = Get-AzContext -ErrorAction Stop
            if ($currentContext -and $currentContext.Account -and $currentContext.Account.Id) {
                if ($tenantId -and $currentContext.Tenant.Id -ne $tenantId) {
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                }
            } else {
                if ($tenantId) {
                    $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
                } else {
                    $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
                }
            }
        } catch {
            if ($tenantId) {
                $null = Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -ErrorAction Stop
            } else {
                $null = Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        $subscriptionId = (Get-AzContext).Subscription.Id
    } else {
        $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    }

    Write-Output "Azure Context: $((Get-AzContext).Account.Id) in subscription $((Get-AzContext).Subscription.Name)"
} catch {
    Write-Error "Failed to authenticate to Azure: $_"
    throw "Authentication failed"
}

$resourceGroupResourceId = New-AnfResourceId -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName
$accountResourceId = New-AnfResourceId -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName
$poolResourceId = New-AnfResourceId -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName

if (-not (Get-AnfResourceOrNull -ResourceId $resourceGroupResourceId -ApiVersion "2021-04-01")) {
    throw "Resource group '$resourceGroupName' was not found in subscription '$subscriptionId'. Create the resource group before running this script."
}

if ($operation -eq "Create") {
    $existingVolumeBytes = [int64]0
    $existingVolumes = @()
    $existingPool = Get-AnfResourceOrNull -ResourceId $poolResourceId -ApiVersion $anfApiVersion
    if ($existingPool) {
        $volumesResponse = Get-AnfResourceOrNull -ResourceId "$poolResourceId/volumes" -ApiVersion $anfApiVersion
        if ($volumesResponse -and $volumesResponse.value) {
            $existingVolumes = @($volumesResponse.value)
            foreach ($existingVolume in $existingVolumes) {
                if ($existingVolume.properties.usageThreshold) {
                    $existingVolumeBytes += [int64]$existingVolume.properties.usageThreshold
                }
            }
        }
    }

    $requestedVolumeBytes = [int64]$volumeCount * $volumeSizeBytes
    if (($existingVolumeBytes + $requestedVolumeBytes) -gt $poolSizeBytes) {
        throw "Requested volume capacity exceeds target pool size. Existing=$([math]::Round($existingVolumeBytes / $bytesPerGiB, 0)) GiB, Requested=$([math]::Round($requestedVolumeBytes / $bytesPerGiB, 0)) GiB, Pool=$($poolSizeTiB * 1024) GiB."
    }

    if (Test-AnfYes -Value $testMode) {
        Write-Output "TEST MODE: Would create or verify ANF account: $accountResourceId"
        Write-Output "TEST MODE: Would create or verify capacity pool: $poolResourceId"
        for ($i = 1; $i -le $volumeCount; $i++) {
            $volumeName = "$volumePrefix$i"
            Write-Output "TEST MODE: Would create or verify volume: $volumeName"
        }
        return
    }

    if (-not (Get-AnfResourceOrNull -ResourceId $accountResourceId -ApiVersion $anfApiVersion)) {
        Write-Output "Creating ANF account '$anfAccountName'..."
        $null = Invoke-AnfArmJson -Method "PUT" -ResourceId $accountResourceId -ApiVersion $anfApiVersion -BodyJson (New-AnfAccountBodyJson)
        Wait-AnfProvisioningState -ResourceId $accountResourceId -ApiVersion $anfApiVersion
    } else {
        Write-Output "ANF account '$anfAccountName' already exists."
    }

    if (-not (Get-AnfResourceOrNull -ResourceId $poolResourceId -ApiVersion $anfApiVersion)) {
        Write-Output "Creating capacity pool '$anfPoolName'..."
        $null = Invoke-AnfArmJson -Method "PUT" -ResourceId $poolResourceId -ApiVersion $anfApiVersion -BodyJson (New-AnfPoolBodyJson)
        Wait-AnfProvisioningState -ResourceId $poolResourceId -ApiVersion $anfApiVersion
    } else {
        Write-Output "Capacity pool '$anfPoolName' already exists."
    }

    for ($i = 1; $i -le $volumeCount; $i++) {
        $volumeName = "$volumePrefix$i"
        $volumeResourceId = New-AnfResourceId -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -VolumeName $volumeName
        if (-not (Get-AnfResourceOrNull -ResourceId $volumeResourceId -ApiVersion $anfApiVersion)) {
            Write-Output "Creating volume '$volumeName'..."
            $null = Invoke-AnfArmJson -Method "PUT" -ResourceId $volumeResourceId -ApiVersion $anfApiVersion -BodyJson (New-AnfVolumeBodyJson -VolumeName $volumeName)
            Wait-AnfProvisioningState -ResourceId $volumeResourceId -ApiVersion $anfApiVersion
        } else {
            Write-Output "Volume '$volumeName' already exists."
        }
    }

    Write-Output "ANF create workflow completed."
    return
}

if ($operation -eq "Delete") {
    $expectedConfirmation = "DELETE $anfAccountName/$anfPoolName"
    $poolVolumesResourceId = "$poolResourceId/volumes"
    $accountPoolsResourceId = "$accountResourceId/capacityPools"
    $volumes = @(Get-AnfResourceCollectionValues -CollectionResourceId $poolVolumesResourceId -ApiVersion $anfApiVersion)

    if (Test-AnfYes -Value $testMode) {
        Write-Output "TEST MODE: Would delete $($volumes.Count) volume(s), capacity pool '$anfPoolName', and ANF account '$anfAccountName'."
        foreach ($volume in $volumes) {
            Write-Output "TEST MODE: Would delete volume: $($volume.name)"
        }
        Write-Output "TEST MODE: Live delete requires ANF_TestMode=No and ANF_DeleteConfirmation='$expectedConfirmation'."
        return
    }

    if ($deleteConfirmation -ne $expectedConfirmation) {
        throw "Live delete requires ANF_DeleteConfirmation to exactly equal '$expectedConfirmation'. Current value: '$deleteConfirmation'"
    }

    foreach ($volume in $volumes) {
        Write-Output "Deleting volume '$($volume.name)'..."
        $null = Invoke-AnfArmJson -Method "DELETE" -ResourceId $volume.id -ApiVersion $anfApiVersion
        Wait-AnfProvisioningState -ResourceId $volume.id -ApiVersion $anfApiVersion -WaitForDelete
    }
    Wait-AnfChildResourceCollectionEmpty -CollectionResourceId $poolVolumesResourceId -ApiVersion $anfApiVersion -ResourceTypeLabel "volume(s) in pool '$anfPoolName'"

    if (Get-AnfResourceOrNull -ResourceId $poolResourceId -ApiVersion $anfApiVersion) {
        Write-Output "Deleting capacity pool '$anfPoolName'..."
        $null = Invoke-AnfArmJson -Method "DELETE" -ResourceId $poolResourceId -ApiVersion $anfApiVersion
        Wait-AnfProvisioningState -ResourceId $poolResourceId -ApiVersion $anfApiVersion -WaitForDelete
        Wait-AnfNamedChildAbsent -CollectionResourceId $accountPoolsResourceId -ApiVersion $anfApiVersion -ChildName $anfPoolName -ResourceTypeLabel "capacity pool"
    } else {
        Write-Output "Capacity pool '$anfPoolName' was not found."
        Wait-AnfNamedChildAbsent -CollectionResourceId $accountPoolsResourceId -ApiVersion $anfApiVersion -ChildName $anfPoolName -ResourceTypeLabel "capacity pool"
    }

    $remainingPools = @(Get-AnfResourceCollectionValues -CollectionResourceId $accountPoolsResourceId -ApiVersion $anfApiVersion)
    if ($remainingPools.Count -gt 0) {
        $remainingPoolNames = @($remainingPools | ForEach-Object { Get-AnfResourceShortName -Resource $_ }) -join ', '
        throw "ANF account '$anfAccountName' still contains capacity pool(s): $remainingPoolNames. The account will not be deleted until all pools are gone."
    }

    if (Get-AnfResourceOrNull -ResourceId $accountResourceId -ApiVersion $anfApiVersion) {
        Write-Output "Deleting ANF account '$anfAccountName'..."
        $null = Invoke-AnfArmJson -Method "DELETE" -ResourceId $accountResourceId -ApiVersion $anfApiVersion
        Wait-AnfProvisioningState -ResourceId $accountResourceId -ApiVersion $anfApiVersion -WaitForDelete
    } else {
        Write-Output "ANF account '$anfAccountName' was not found."
    }

    Write-Output "ANF delete workflow completed."
}
