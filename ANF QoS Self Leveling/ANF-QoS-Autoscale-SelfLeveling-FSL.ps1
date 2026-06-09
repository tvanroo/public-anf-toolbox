<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 06/09/2026
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script automates the allocation of Throughput MiBs/Sec to Azure NetApp Files Flexible Service Level volumes based on past throughput limits reached metrics.

Recommended use:
Run on a recurring basis and allow it to balance the throughput of the volumes based on the past throughput limits reached metrics over time. 
You can adjust how aggressive the script is in a few ways:
    1. Adjust the $levelingAgressionPercent variable to a higher or lower value. This defines how much throughput from drives is reallocated to non-performant drives.
    2. Run this script more or less frequently and adjust the $increaseLookBackHours variable to define how far back in time the script looks for throughput limit metrics.
        a. More frequent running of the script will move the throughput around more frequently.
        b. A shorter look-back period will make the script more reactive (with each run) to changes in throughput usage.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# User Editable Variables (environment-first):
    $tenantId = $env:ANF_TenantId                           # Tenant ID for Azure authentication (optional)
    $subscriptionId = $env:ANF_SubscriptionId               # Optional subscription ID override (recommended for Automation)
    $resourceGroupName = $env:ANF_ResourceGroupName         # Optional fallback single-target resource group name
    $anfAccountName = $env:ANF_AccountName                  # Optional fallback single-target ANF account name
    $anfPoolName = $env:ANF_PoolName                        # Optional fallback single-target ANF pool name
    $targetPoolIncludeTagKey = if ($env:ANF_TargetPoolIncludeTagKey) { $env:ANF_TargetPoolIncludeTagKey } else { "AnfQosSelfLevelingTarget" }  # Capacity pools with this tag key/value are targeted
    $targetPoolIncludeTagValue = if ($env:ANF_TargetPoolIncludeTagValue) { $env:ANF_TargetPoolIncludeTagValue } else { "true" }                 # Tag value match is case-insensitive
    $testMode = if ($env:ANF_TestMode) { $env:ANF_TestMode } else { "Yes" }                                                                  # Test Mode Selector: "Yes", "No"  Yes displays report, No makes changes and displays report
    $minimumThroughputPerVolume = if ($env:ANF_MinimumThroughputPerVolume) { [int]$env:ANF_MinimumThroughputPerVolume } else { 1 }            # Minimum throughput per volume in MiB/s (minimum allowed is 1)
    $minimumPoolThroughputMibps = if ($env:ANF_MinimumPoolThroughputMibps) { [int]$env:ANF_MinimumPoolThroughputMibps } else { 128 }          # Minimum flexible service level pool throughput in MiB/s
    $increaseLookBackHours = if ($env:ANF_IncreaseLookBackHours) { [int]$env:ANF_IncreaseLookBackHours } else { 24 }                         # Increase signal look-back period in hours (default 1 day)
    $decreaseRequiredCleanDays = if ($env:ANF_DecreaseRequiredCleanDays) { [int]$env:ANF_DecreaseRequiredCleanDays } else { 3 }            # Decrease gate: requires this many clean 24-hour windows
    $levelingAgressionPercent = if ($env:ANF_LevelingAgressionPercent) { [int]$env:ANF_LevelingAgressionPercent } else { 10 }                 # Leveling Aggression Factor: How much throughput is re-allocated per run?
    $throughputLimitMetricAllowance = if ($env:ANF_ThroughputLimitMetricAllowance) { [double]$env:ANF_ThroughputLimitMetricAllowance } else { 6 }  # What ThroughputLimitMetric value is considered acceptable for a volume to be considered performant
    $decreaseRetrySleepSeconds = if ($env:ANF_DecreaseRetrySleepSeconds) { [int]$env:ANF_DecreaseRetrySleepSeconds } else { 300 }              # If a decrease update fails, retry at this interval (5 minutes)
    $decreaseRetryMaxWaitSeconds = if ($env:ANF_DecreaseRetryMaxWaitSeconds) { [int]$env:ANF_DecreaseRetryMaxWaitSeconds } else { 3600 }      # Maximum cumulative wait to keep retrying decreases (1 hour)
    $excludeTagKey = if ($env:ANF_ExcludeTagKey) { $env:ANF_ExcludeTagKey } else { "ExcludeFromAnfQosSelfLeveling" }                          # Volumes with this tag key/value pair are excluded from automation
    $excludeTagValue = if ($env:ANF_ExcludeTagValue) { $env:ANF_ExcludeTagValue } else { "true" }                                             # Tag value match is case-insensitive
# Reduce module/autoload noise in Automation logs
$VerbosePreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# Optional Azure Automation variable overrides (used by Deploy-in-Azure workflow)
if (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue) {
    try { $tenantId = (Get-AutomationVariable -Name "ANF_TenantId" -ErrorAction Stop) } catch {}
    try { $subscriptionId = (Get-AutomationVariable -Name "ANF_SubscriptionId" -ErrorAction Stop) } catch {}
    try { $resourceGroupName = (Get-AutomationVariable -Name "ANF_ResourceGroupName" -ErrorAction Stop) } catch {}
    try { $anfAccountName = (Get-AutomationVariable -Name "ANF_AccountName" -ErrorAction Stop) } catch {}
    try { $anfPoolName = (Get-AutomationVariable -Name "ANF_PoolName" -ErrorAction Stop) } catch {}
    try { $targetPoolIncludeTagKey = (Get-AutomationVariable -Name "ANF_TargetPoolIncludeTagKey" -ErrorAction Stop) } catch {}
    try { $targetPoolIncludeTagValue = (Get-AutomationVariable -Name "ANF_TargetPoolIncludeTagValue" -ErrorAction Stop) } catch {}
    try { $testMode = (Get-AutomationVariable -Name "ANF_TestMode" -ErrorAction Stop) } catch {}
    try { $increaseLookBackHours = [int](Get-AutomationVariable -Name "ANF_IncreaseLookBackHours" -ErrorAction Stop) } catch {}
    try { $increaseLookBackHours = [int](Get-AutomationVariable -Name "ANF_ThroughputLookBackHours" -ErrorAction Stop) } catch {}
    try { $minimumThroughputPerVolume = [int](Get-AutomationVariable -Name "ANF_MinimumThroughputPerVolume" -ErrorAction Stop) } catch {}
    try { $minimumPoolThroughputMibps = [int](Get-AutomationVariable -Name "ANF_MinimumPoolThroughputMibps" -ErrorAction Stop) } catch {}
    try { $decreaseRetrySleepSeconds = [int](Get-AutomationVariable -Name "ANF_DecreaseRetrySleepSeconds" -ErrorAction Stop) } catch {}
    try { $decreaseRetryMaxWaitSeconds = [int](Get-AutomationVariable -Name "ANF_DecreaseRetryMaxWaitSeconds" -ErrorAction Stop) } catch {}
    try { $excludeTagKey = (Get-AutomationVariable -Name "ANF_ExcludeTagKey" -ErrorAction Stop) } catch {}
    try { $excludeTagValue = (Get-AutomationVariable -Name "ANF_ExcludeTagValue" -ErrorAction Stop) } catch {}
    try { $decreaseRequiredCleanDays = [int](Get-AutomationVariable -Name "ANF_DecreaseRequiredCleanDays" -ErrorAction Stop) } catch {}
    try { $decreaseRequiredCleanDays = [int](Get-AutomationVariable -Name "ANF_DecreaseCleanWindowDays" -ErrorAction Stop) } catch {}
    try { $levelingAgressionPercent = [int](Get-AutomationVariable -Name "ANF_LevelingAgressionPercent" -ErrorAction Stop) } catch {}
    try { $throughputLimitMetricAllowance = [double](Get-AutomationVariable -Name "ANF_ThroughputLimitMetricAllowance" -ErrorAction Stop) } catch {}
}
function Normalize-SettingString {
    param([object]$Value)
    if ($null -eq $Value) {
        return $null
    }

    $normalized = "$Value"
    $normalized = $normalized.Trim()
    if ($normalized.Contains('\\"')) {
        $normalized = $normalized.Replace('\\"', '"')
    }
    while (
        $normalized.Length -ge 2 -and
        (
            ($normalized.StartsWith('"') -and $normalized.EndsWith('"')) -or
            ($normalized.StartsWith("'") -and $normalized.EndsWith("'"))
        )
    ) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    return $normalized
}
$tenantId = Normalize-SettingString $tenantId
$subscriptionId = Normalize-SettingString $subscriptionId
$resourceGroupName = Normalize-SettingString $resourceGroupName
$anfAccountName = Normalize-SettingString $anfAccountName
$anfPoolName = Normalize-SettingString $anfPoolName
$targetPoolIncludeTagKey = Normalize-SettingString $targetPoolIncludeTagKey
$targetPoolIncludeTagValue = Normalize-SettingString $targetPoolIncludeTagValue
$testMode = Normalize-SettingString $testMode
$excludeTagKey = Normalize-SettingString $excludeTagKey
$excludeTagValue = Normalize-SettingString $excludeTagValue

# Connect to Azure
if (-not (Get-AzContext)) {
    $isAutomationHost = [bool](Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)
    if ($isAutomationHost) {
        try {
            if ($tenantId) {
                Connect-AzAccount -Identity -TenantId $tenantId | Out-Null
            } else {
                Connect-AzAccount -Identity | Out-Null
            }
        } catch {
            if ($tenantId) {
                Connect-AzAccount -TenantId $tenantId | Out-Null
            } else {
                Connect-AzAccount | Out-Null
            }
        }
    } else {
        if ($tenantId) {
            Connect-AzAccount -TenantId $tenantId | Out-Null
        } else {
            Connect-AzAccount | Out-Null
        }
    }
    Get-AzContext
}
$availableSubscriptions = @()
try {
    $availableSubscriptions = @(Get-AzSubscription -ErrorAction SilentlyContinue)
} catch {}

if ($subscriptionId) {
    try {
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    } catch {
        if ($availableSubscriptions.Count -eq 1) {
            Set-AzContext -SubscriptionId $availableSubscriptions[0].Id -ErrorAction Stop | Out-Null
            Write-Host "Requested subscription '$subscriptionId' could not be selected; using the only discoverable subscription '$($availableSubscriptions[0].Id)'." -ForegroundColor Yellow
        } else {
            throw "Unable to set Azure context to subscription '$subscriptionId'. Ensure ANF_SubscriptionId is valid and this managed identity has access to that subscription."
        }
    }
} elseif ($availableSubscriptions.Count -eq 1) {
    Set-AzContext -SubscriptionId $availableSubscriptions[0].Id -ErrorAction Stop | Out-Null
}

$currentAzContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $currentAzContext -or -not $currentAzContext.Subscription -or [string]::IsNullOrWhiteSpace($currentAzContext.Subscription.Id)) {
    throw "No active Azure subscription context is available. Grant this managed identity access to the target subscription and set ANF_SubscriptionId."
}

if ($testMode -eq "Yes") {
    Write-Host "Script is running in test mode. Changes will not be made to the volumes." -ForegroundColor Green
} elseif ($testMode -eq "No") {
    Write-Host "Script is running in ***live*** mode. Changes ***will*** be made to the volumes." -ForegroundColor Yellow
} else { 
    Write-Host "Test Mode is not set to Yes or No. Exiting Script." -ForegroundColor Red
    exit
}
Write-Output "ANF QoS Self Leveling startup: Mode=$testMode; Subscription=$($currentAzContext.Subscription.Id); IncludeTag=$targetPoolIncludeTagKey=$targetPoolIncludeTagValue"
Write-Output "Tuning: increaseLookBackHours=$increaseLookBackHours; decreaseRequiredCleanDays=$decreaseRequiredCleanDays; throughputLimitMetricAllowance=$throughputLimitMetricAllowance; levelingAgressionPercent=$levelingAgressionPercent"

Write-Output "ANF operation mode: REST-only (Az.NetAppFiles cmdlets disabled)."
$anfApiVersion = "2026-04-01"
function Resolve-AnfThroughputMibpsFromProperties {
    param([object]$Properties)
    if ($null -eq $Properties) {
        return $null
    }
    $throughputCandidates = @(
        $Properties.totalThroughputMibps,
        $Properties.throughputMibps,
        $Properties.provisionedThroughputMibps,
        $Properties.actualThroughputMibps,
        $Properties.customThroughputMibps
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
function Invoke-AnfArmJson {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
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
    $uri = "$resourceManagerUrl$ResourceId" + "?api-version=$ApiVersion"
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }
    if ($BodyJson) {
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $BodyJson -ErrorAction Stop
    }
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ErrorAction Stop
}

function Get-AnfPool {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $context = Get-AzContext -ErrorAction Stop
    $resourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$AccountName/capacityPools/$PoolName"
    $poolCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($poolCandidate -and $poolCandidate.error) {
        $errorCode = $poolCandidate.error.code
        $errorMessage = $poolCandidate.error.message
        throw "Capacity pool REST API returned error for $ResourceGroupName/$AccountName/$PoolName. code='$errorCode' message='$errorMessage'"
    }
    $pool = $null
    if ($poolCandidate -and $poolCandidate.properties) {
        $pool = $poolCandidate
    } elseif ($poolCandidate -and $poolCandidate.value -and $poolCandidate.value.Count -gt 0) {
        $pool = $poolCandidate.value[0]
    } elseif ($poolCandidate -and $poolCandidate.content) {
        $nested = $poolCandidate.content
        if ($nested -is [string]) {
            try { $nested = $nested | ConvertFrom-Json } catch {}
        }
        if ($nested -and $nested.properties) {
            $pool = $nested
        }
    }
    if (-not $pool) {
        $topLevelProps = @()
        if ($poolCandidate) { $topLevelProps = @($poolCandidate.PSObject.Properties.Name) }
        throw "Unable to parse capacity pool REST response for $ResourceGroupName/$AccountName/$PoolName. Top-level properties present: $($topLevelProps -join ', ')"
    }
    $poolProperties = $pool.properties

    $resolvedQosType = $null
    $qosCandidates = @(
        $poolProperties.qosType,
        $poolProperties.QosType
    )
    foreach ($candidate in $qosCandidates) {
        if (-not [string]::IsNullOrWhiteSpace("$candidate")) {
            $resolvedQosType = "$candidate"
            break
        }
    }

    $resolvedThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $poolProperties

    if ($null -eq $resolvedThroughputMibps -or $resolvedThroughputMibps -le 0) {
        $propertyNames = @()
        if ($poolProperties) {
            $propertyNames = @($poolProperties.PSObject.Properties.Name)
        }
        throw "Unable to resolve capacity pool throughput from REST response for $ResourceGroupName/$AccountName/$PoolName. Properties present: $($propertyNames -join ', ')"
    }


    return [PSCustomObject]@{
        Id = $pool.id
        Name = $pool.name
        QosType = $resolvedQosType
        TotalThroughputMibps = $resolvedThroughputMibps
    }
}

function Get-AnfVolumes {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $context = Get-AzContext -ErrorAction Stop
    $resourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$AccountName/capacityPools/$PoolName/volumes"
    $volumesCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($volumesCandidate -and $volumesCandidate.error) {
        $errorCode = $volumesCandidate.error.code
        $errorMessage = $volumesCandidate.error.message
        throw "Volume list REST API returned error for $ResourceGroupName/$AccountName/$PoolName. code='$errorCode' message='$errorMessage'"
    }
    $volumes = @()
    if ($volumesCandidate -and $volumesCandidate.value) {
        $volumes = @($volumesCandidate.value)
    } elseif ($volumesCandidate -and $volumesCandidate.id) {
        $volumes = @($volumesCandidate)
    }
    if (-not $volumes) {
        return @()
    }

    return @($volumes | ForEach-Object {
        $volumeProperties = $_.properties
        $resolvedThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $volumeProperties
        if ($null -eq $resolvedThroughputMibps) {
            $resolvedThroughputMibps = 0
        }
        [PSCustomObject]@{
            Id = $_.id
            Name = $_.name
            Tags = $_.tags
            ActualThroughputMibps = $resolvedThroughputMibps
        }
    })
}

function Get-AnfVolume {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName,
        [Parameter(Mandatory=$true)][string]$VolumeName
    )

    $context = Get-AzContext -ErrorAction Stop
    $resourceId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.NetApp/netAppAccounts/$AccountName/capacityPools/$PoolName/volumes/$VolumeName"
    $volume = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    if ($volume -and $volume.error) {
        $errorCode = $volume.error.code
        $errorMessage = $volume.error.message
        throw "Volume REST API returned error for $ResourceGroupName/$AccountName/$PoolName/$VolumeName. code='$errorCode' message='$errorMessage'"
    }
    $volumeProperties = $volume.properties
    $resolvedThroughputMibps = Resolve-AnfThroughputMibpsFromProperties -Properties $volumeProperties
    if ($null -eq $resolvedThroughputMibps) {
        $resolvedThroughputMibps = 0
    }

    return [PSCustomObject]@{
        Id = $volume.id
        Name = $volume.name
        Tags = $volume.tags
        ActualThroughputMibps = $resolvedThroughputMibps
    }
}

function Set-AnfVolumeThroughput {
    param(
        [Parameter(Mandatory=$true)][object]$VolumeObject,
        [Parameter(Mandatory=$true)][double]$TargetThroughputMibps
    )

    $payload = @{
        properties = @{
            throughputMibps = [math]::Round($TargetThroughputMibps, 3)
        }
    } | ConvertTo-Json -Depth 4
    $null = Invoke-AnfArmJson -Method "PATCH" -ResourceId $VolumeObject.Id -ApiVersion $anfApiVersion -BodyJson $payload
}
function Get-AnfCapacityPoolsByTag {
    param(
        [Parameter(Mandatory=$true)][string]$TagKey,
        [Parameter(Mandatory=$true)][string]$TagValue
    )

    $context = Get-AzContext -ErrorAction Stop
    $subscriptionId = $context.Subscription.Id
    $accountsResourceId = "/subscriptions/$subscriptionId/providers/Microsoft.NetApp/netAppAccounts"
    $accountsCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $accountsResourceId -ApiVersion "2026-03-01"
    if ($accountsCandidate -and $accountsCandidate.error) {
        $errorCode = $accountsCandidate.error.code
        $errorMessage = $accountsCandidate.error.message
        throw "NetApp account list REST API returned error. code='$errorCode' message='$errorMessage'"
    }

    $accounts = @()
    if ($accountsCandidate -and $accountsCandidate.value) {
        $accounts = @($accountsCandidate.value)
    } elseif ($accountsCandidate -and $accountsCandidate.id) {
        $accounts = @($accountsCandidate)
    }

    $pools = @()
    foreach ($account in $accounts) {
        if (-not $account.id) {
            continue
        }
        if ($account.id -notmatch "/resourceGroups/([^/]+)/providers/Microsoft.NetApp/netAppAccounts/([^/]+)$") {
            continue
        }
        $rg = $Matches[1]
        $accountName = $Matches[2]

        $poolListResourceId = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.NetApp/netAppAccounts/$accountName/capacityPools"
        $poolListCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $poolListResourceId -ApiVersion $anfApiVersion
        if ($poolListCandidate -and $poolListCandidate.error) {
            $errorCode = $poolListCandidate.error.code
            $errorMessage = $poolListCandidate.error.message
            throw "Capacity pool list REST API returned error for $rg/$accountName. code='$errorCode' message='$errorMessage'"
        }

        $poolList = @()
        if ($poolListCandidate -and $poolListCandidate.value) {
            $poolList = @($poolListCandidate.value)
        } elseif ($poolListCandidate -and $poolListCandidate.id) {
            $poolList = @($poolListCandidate)
        }

        foreach ($pool in $poolList) {
            $candidateTagValue = $null
            if ($pool.tags) {
                if ($pool.tags -is [System.Collections.IDictionary]) {
                    if ($pool.tags.ContainsKey($TagKey)) {
                        $candidateTagValue = "$($pool.tags[$TagKey])"
                    }
                } else {
                    $tagProp = $pool.tags.PSObject.Properties | Where-Object { $_.Name -eq $TagKey } | Select-Object -First 1
                    if ($tagProp) {
                        $candidateTagValue = "$($tagProp.Value)"
                    }
                }
            }
            if ($candidateTagValue -and $candidateTagValue.ToLower() -eq $TagValue.ToLower()) {
                $poolName = $null
                if ($pool.id -and $pool.id -match "/capacityPools/([^/]+)$") {
                    $poolName = $Matches[1]
                } elseif ($pool.name -and $pool.name -match ".*/([^/]+)$") {
                    $poolName = $Matches[1]
                }
                if ($poolName) {
                    $pools += [PSCustomObject]@{
                        ResourceGroupName = $rg
                        AccountName = $accountName
                        PoolName = $poolName
                    }
                }
            }
        }
    }

    return $pools
}
function Invoke-FslSelfLevelingForPool {
    param(
        [Parameter(Mandatory=$true)][string]$TargetResourceGroupName,
        [Parameter(Mandatory=$true)][string]$TargetAnfAccountName,
        [Parameter(Mandatory=$true)][string]$TargetAnfPoolName
    )

Write-Host "Processing target pool: RG=$TargetResourceGroupName, Account=$TargetAnfAccountName, Pool=$TargetAnfPoolName" -ForegroundColor Cyan
Write-Output "Processing target pool: RG=$TargetResourceGroupName, Account=$TargetAnfAccountName, Pool=$TargetAnfPoolName"
# Get the Azure NetApp Files capacity pool details
$anfPool = Get-AnfPool -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName
# Get Capacity Pool QoS Type
$capacityPoolQosType = $anfPool.QosType
# Get the maximum provisioned throughput of the capacity pool in MiB/s
$capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps
Write-Output "Pool details: QoS=$capacityPoolQosType; TotalThroughputMibps=$capacityPoolMaxThroughput"
Write-Output "Decision inputs: minPoolThroughputMibps=$minimumPoolThroughputMibps; minThroughputPerVolume=$minimumThroughputPerVolume; increaseLookBackHours=$increaseLookBackHours; decreaseRequiredCleanDays=$decreaseRequiredCleanDays; allowanceThreshold=$throughputLimitMetricAllowance; levelingAgressionPercent=$levelingAgressionPercent."

function Update-FslPoolThroughputMibps {
    param(
        [Parameter(Mandatory=$true)][string]$PoolResourceId,
        [Parameter(Mandatory=$true)][double]$TargetThroughputMibps
    )

    $targetRounded = [math]::Round($TargetThroughputMibps, 3)
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
    $apiVersion = "2024-07-01-preview"
    $uri = "$resourceManagerUrl$PoolResourceId" + "?api-version=$apiVersion"
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $propertyCandidates = @("provisionedThroughputMibps", "totalThroughputMibps")
    $lastError = $null
    foreach ($propertyName in $propertyCandidates) {
        try {
            $body = @{
                properties = @{
                    $propertyName = $targetRounded
                }
            } | ConvertTo-Json -Depth 3

            $null = Invoke-RestMethod -Uri $uri -Method PATCH -Body $body -Headers $headers -ErrorAction Stop
            return
        } catch {
            $lastError = $_
        }
    }

    throw "Failed to update pool throughput to $targetRounded MiB/s via REST API. Last error: $($lastError.Exception.Message)"
}
# Flexible Service Level pools must be Manual QoS
if ($capacityPoolQosType -ne "Manual") {
    Write-Host "Exiting Script - Manual QoS is required" -ForegroundColor Red
    Write-Host "Capacity Pool QoS is currently set to '$capacityPoolQosType'" -ForegroundColor Red
    Write-Host "Flexible Service Level pools and volumes require Manual QoS for this script." -ForegroundColor Red
    Write-Output "Skipping pool because QoS is '$capacityPoolQosType' (expected 'Manual'): $TargetResourceGroupName/$TargetAnfAccountName/$TargetAnfPoolName"
    return
}

# Enforce minimum throughput constraints for flexible service level
if ($minimumThroughputPerVolume -lt 1) {
    Write-Host "minimumThroughputPerVolume cannot be lower than 1 MiB/s. Exiting script." -ForegroundColor Red
    return
}
if ($capacityPoolMaxThroughput -lt $minimumPoolThroughputMibps) {
    Write-Host "Capacity pool throughput is below the flexible service level minimum of $minimumPoolThroughputMibps MiB/s. Exiting script." -ForegroundColor Red
    return
}

# Get list of Volumes within Capacity Pool
$anfVolumes = Get-AnfVolumes -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName

# Collect Info for Each Volume and calculate values
# If there are no volumes, write host message and exit
if (-not $anfVolumes) {
    Write-Host "No volumes found in Azure NetApp Files Capacity Pool `"$TargetAnfPoolName`". Skipping this pool." -ForegroundColor Red
    return
}

# Split into managed vs excluded volumes based on tag
$excludedVolumes = @()
$managedVolumes = @()
foreach ($anfVolume in $anfVolumes) {
    $isExcludedVolume = $false
    if ($anfVolume.Tags) {
        if ($anfVolume.Tags -is [System.Collections.IDictionary]) {
            foreach ($tag in $anfVolume.Tags.GetEnumerator()) {
                if ($tag.Key -eq $excludeTagKey -and "$($tag.Value)".ToLower() -eq $excludeTagValue.ToLower()) {
                    $isExcludedVolume = $true
                    break
                }
            }
        } else {
            foreach ($tag in $anfVolume.Tags.PSObject.Properties) {
                if ($tag.Name -eq $excludeTagKey -and "$($tag.Value)".ToLower() -eq $excludeTagValue.ToLower()) {
                    $isExcludedVolume = $true
                    break
                }
            }
        }
    }

    if ($isExcludedVolume) {
        $excludedVolumes += $anfVolume
    } else {
        $managedVolumes += $anfVolume
    }
}

if (-not $managedVolumes) {
    Write-Host "All volumes in pool `"$TargetAnfPoolName`" are excluded by tag $excludeTagKey=$excludeTagValue. Skipping this pool." -ForegroundColor Yellow
    Write-Output "Decision: managed volume count is 0 after exclusion filter ($excludeTagKey=$excludeTagValue); skipping pool."
    return
}

$excludedThroughputMibps = [math]::Round(($excludedVolumes | Measure-Object -Property ActualThroughputMibps -Sum).Sum, 3)
# Excluded volume throughput remains part of total pool throughput and is reserved; only the remaining throughput is managed by this automation.
$capacityPoolManagedThroughput = [math]::Round($capacityPoolMaxThroughput - $excludedThroughputMibps, 3)
if ($capacityPoolManagedThroughput -le 0) {
    Write-Host "No managed pool throughput remains after excluded volume allocations. Exiting script." -ForegroundColor Red
    return
}
if ($excludedVolumes.Count -gt 0) {
    $excludedVolumeNames = ($excludedVolumes | ForEach-Object { $_.Name.Split('/')[2] }) -join ", "
    Write-Host "Excluded volumes by tag ($excludeTagKey=$excludeTagValue): $excludedVolumeNames" -ForegroundColor Yellow
}
Write-Output "Volume inventory: total=$($anfVolumes.Count); managed=$($managedVolumes.Count); excluded=$($excludedVolumes.Count)."
Write-Host "Pool throughput accounting: Total=$capacityPoolMaxThroughput MiB/s, ExcludedAllocated=$excludedThroughputMibps MiB/s, ManagedBudget=$capacityPoolManagedThroughput MiB/s" -ForegroundColor Cyan

# Collect data for each managed volume
$volumeData = foreach ($anfVolume in $managedVolumes) {
    [PSCustomObject]@{
        ShortName = $anfVolume.Name.split('/')[2]
        VolumeId = $anfVolume.Id
        ThroughputLimitMetric = [math]::Round($((Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'throughputLimitReached' -StartTime $(get-date).AddHours(-$increaseLookBackHours) -EndTime $(get-date) -TimeGrain 00:5:00 -WarningAction SilentlyContinue | Select-Object -ExpandProperty data | Select-Object -ExpandProperty Average) | Measure-Object -average).average, 3)
        CurrentThroughputMibps = [math]::Round($anfVolume.ActualThroughputMibps, 3)
    }
}
foreach ($volume in $volumeData) {
    Write-Output "Metric sample: volume=$($volume.ShortName); currentThroughputMibps=$($volume.CurrentThroughputMibps); throughputLimitReachedAvg=$($volume.ThroughputLimitMetric); increaseLookBackHours=$increaseLookBackHours."
}

# Ensure per-volume throughput floor can fit within managed pool throughput
if (($managedVolumes.Count * $minimumThroughputPerVolume) -gt $capacityPoolManagedThroughput) {
    Write-Host "The total minimum throughput floor across managed volumes exceeds available managed pool throughput. Adjust 'minimumThroughputPerVolume' lower. Exiting script." -ForegroundColor Red
    Write-Output "Decision: managedVolumeCount=$($managedVolumes.Count) * minimumThroughputPerVolume=$minimumThroughputPerVolume exceeds managedBudget=$capacityPoolManagedThroughput; aborting."
    return
}

# Calculate unallocated managed throughput budget
$totalCurrentThroughputMibps = [math]::Round(($volumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum, 3)
$unallocatedThroughputMibps = [math]::Round($capacityPoolManagedThroughput - $totalCurrentThroughputMibps, 3)


####Injecting Fake Test Data ###### Update the ThroughputLimitMetric value for each volume
#$volumeData[0].ThroughputLimitMetric = 0  # Vol1
#$volumeData[1].ThroughputLimitMetric = 5  # Vol2
#$volumeData[2].ThroughputLimitMetric = 15  # Vol3


# Calculate total throughput allocated to all volumes
$totalThroughput = [math]::Round(($volumeData | Measure-Object -Property CurrentThroughputMibps -Sum).Sum, 3)

# Add the "unallocated" row
$unallocatedRow = [PSCustomObject]@{
    ShortName = "unallocated"
    VolumeId = ""
    CurrentThroughputMibps = $unallocatedThroughputMibps
    ThroughputLimitMetric = 0.00
}

# Combine volume data with the unallocated row
$finalData = $volumeData + $unallocatedRow

# Add the property NewThroughputValue to each object
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name NewThroughputValue -Value 0 -Force
    $_
}

# Add throughputPercentage to each object in the finalData array
$finalData = $finalData | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name throughputPercentage -Value 0 -Force
    $_
}

# Add the property Performant to each object
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "" -Force
    } elseif ($_.ThroughputLimitMetric -le $throughputLimitMetricAllowance) {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "Yes" -Force
    } else {
        $_ | Add-Member -MemberType NoteProperty -Name Performant -Value "No" -Force
    }
    $_
}

# Add the property CleanLastNFullDays to each object
# Uses the last N full 24-hour periods anchored to script runtime.
$windowAnchorEnd = Get-Date
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name CleanLastNFullDays -Value $true -Force
    } else {
        $isCleanLastNFullDays = $true
        for ($dayOffset = $decreaseRequiredCleanDays; $dayOffset -ge 1; $dayOffset--) {
            $windowStart = $windowAnchorEnd.AddHours(-24 * $dayOffset)
            $windowEnd = $windowAnchorEnd.AddHours(-24 * ($dayOffset - 1))
            $windowMetricValues = Get-AzMetric -ResourceId $_.VolumeId -MetricName 'throughputLimitReached' -StartTime $windowStart -EndTime $windowEnd -TimeGrain 01:00:00 -WarningAction SilentlyContinue |
                Select-Object -ExpandProperty Data |
                Select-Object -ExpandProperty Average |
                Where-Object { $null -ne $_ }

            if (-not $windowMetricValues) {
                $isCleanLastNFullDays = $false
                break
            }

            $windowMetricMax = [double](($windowMetricValues | Measure-Object -Maximum).Maximum)
            if ($windowMetricMax -gt $throughputLimitMetricAllowance) {
                $isCleanLastNFullDays = $false
                break
            }
        }
        $_ | Add-Member -MemberType NoteProperty -Name CleanLastNFullDays -Value $isCleanLastNFullDays -Force
    }
    $_
}

# Set $allVolumesNonPerformant to true if all volumes except unallocated are non-performant
$nonPerformantVolumes = $finalData | Where-Object { $_.Performant -eq "No" -and $_.ShortName -ne "unallocated" } | Measure-Object
$performantVolumes = $finalData | Where-Object { $_.Performant -eq "Yes" -and $_.ShortName -ne "unallocated" } | Measure-Object
$totalVolumeQty = $managedVolumes.Count
Write-Output "Equilibrium goal: keep each volume's throughputLimitReached near threshold $throughputLimitMetricAllowance (above threshold = increase candidate, at/below threshold = decrease candidate subject to clean-window gate)."
Write-Output "Threshold distribution: above=$($nonPerformantVolumes.Count); at-or-below=$($performantVolumes.Count); total=$totalVolumeQty."

# For each volume calculate the amount of space it can give up, if any, and add it as a property called "SpaceToGiveUp"
$finalData = $finalData | ForEach-Object {
    if ($_.ShortName -eq "unallocated") {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = $_.CurrentThroughputMibps
    } elseif ($_.Performant -eq "Yes" -and $_.CurrentThroughputMibps -gt 1) {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = [math]::Round(
            [math]::Min(
                ($_.CurrentThroughputMibps * $levelingAgressionPercent / 100),
                ($_.CurrentThroughputMibps - $minimumThroughputPerVolume)
            ), 
            3
        )
    } elseif ($nonPerformantVolumes.Count -eq $totalVolumeQty) {
        $_ | Add-Member -MemberType NoteProperty -Name SpaceToGiveUp -Value 0 -Force
        $_.SpaceToGiveUp = [math]::Round(
            [math]::Min(
                ($_.CurrentThroughputMibps * $levelingAgressionPercent / 100),
                ($_.CurrentThroughputMibps - $minimumThroughputPerVolume)
            ), 
            3
        )
    }
    $_
}

$totalVolumeQty = $managedVolumes.Count
$capacityPoolMaxThroughput = $capacityPoolManagedThroughput
$totalminimumThroughputAllocated = [math]::Round($totalVolumeQty * $minimumThroughputPerVolume, 3)
$totalAvailableSpaceToGiveUp = [math]::Round(($finalData | Measure-Object -Property SpaceToGiveUp -Sum).Sum, 3)
$capacityPoolRemainingThroughputToAllocate = [math]::Round($capacityPoolMaxThroughput - $totalAvailableSpaceToGiveUp, 3)
$totalThroughputLimitMetric = [math]::Round(($finalData | Measure-Object -Property ThroughputLimitMetric -Sum).Sum, 3)
$applyZeroPressureDecreases = ($totalThroughputLimitMetric -eq 0)
if ($applyZeroPressureDecreases) {
    Write-Host "No Throughput Limit Reached Metrics found for any volume in the lookback window. Evaluating eligible per-volume decreases." -ForegroundColor Green
    Write-Output "No Throughput Limit Reached metrics above 0 were observed in the last $increaseLookBackHours hours; applying per-volume decreases only where clean-window criteria are met."
    Write-Output "Decrease gate detail: candidate volumes must be clean for the last $decreaseRequiredCleanDays full 24-hour windows (threshold <= $throughputLimitMetricAllowance)."
} else {
    Write-Output "Pressure mode active: totalThroughputLimitMetric=$totalThroughputLimitMetric > 0. Performing weighted rebalance toward allowance threshold."
}

# Calculate the percentage of TotalThroughput for each volume and if total throughput limits reached is less than $throughputLimitMetricAllowance
if (-not $applyZeroPressureDecreases) {
    $finalData | ForEach-Object {
        if ($_.ShortName -eq "unallocated") {
            $_.throughputPercentage = 0.00
        } else {
            $_.throughputPercentage = [math]::Round(($_.ThroughputLimitMetric / $totalThroughputLimitMetric) * 100, 3)
        }
    }
} else {
    $finalData | ForEach-Object {
        $_.throughputPercentage = 0.00
    }
}

# Apply percentage to throughput for each volume
$finalData | ForEach-Object {
    if (-not $applyZeroPressureDecreases) {
        if ($_.ShortName -ne "unallocated") {
            if ($_.Performant -eq "Yes" -and $_.CurrentThroughputMibps -lt 1) {
                $_.NewThroughputValue = 1
            } else {
                $_.NewThroughputValue = [math]::Round(($_.CurrentThroughputMibps - $_.SpaceToGiveUp) + ($totalAvailableSpaceToGiveUp * $_.throughputPercentage / 100), 3)
            }
        } elseif ($nonPerformantVolumes.Count -eq $totalVolumeQty) {
            $_.NewThroughputValue = [math]::Round(($_.CurrentThroughputMibps - $_.SpaceToGiveUp) + ($totalAvailableSpaceToGiveUp * $_.throughputPercentage / 100), 3)
        } else {
            $_.NewThroughputValue = 0
        }
    } else {
        if ($_.ShortName -eq "unallocated") {
            $_.NewThroughputValue = 0
        } elseif ($_.CleanLastNFullDays -and $_.CurrentThroughputMibps -gt $minimumThroughputPerVolume) {
            $_.NewThroughputValue = [math]::Round([math]::Max($minimumThroughputPerVolume, ($_.CurrentThroughputMibps - $_.SpaceToGiveUp)), 3)
        } else {
            $_.NewThroughputValue = $_.CurrentThroughputMibps
        }
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
        $_.NetChangeInThroughputMibs = [math]::Round($_.NewThroughputValue - $_.CurrentThroughputMibps, 3)
    } else {
        $_.NetChangeInThroughputMibs = 0
    }
}
foreach ($volume in ($finalData | Where-Object { $_.ShortName -ne "unallocated" })) {
    Write-Output "Decision snapshot: volume=$($volume.ShortName); metric=$($volume.ThroughputLimitMetric); performant=$($volume.Performant); cleanWindowMet=$($volume.CleanLastNFullDays); current=$($volume.CurrentThroughputMibps); spaceToGive=$($volume.SpaceToGiveUp); proposed=$($volume.NewThroughputValue); netChange=$($volume.NetChangeInThroughputMibs)."
}

# Prevent throughput decreases unless the last N full 24-hour periods were clean
$suppressedDecreaseCount = 0
$finalData | ForEach-Object {
    if ($_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -lt 0 -and -not $_.CleanLastNFullDays) {
        $_.NewThroughputValue = $_.CurrentThroughputMibps
        $_.NetChangeInThroughputMibs = 0
        $suppressedDecreaseCount += 1
    }
}
if ($suppressedDecreaseCount -gt 0) {
    Write-Output "Decrease gate applied: suppressed $suppressedDecreaseCount planned decrease(s) because clean-window requirement was not met (required clean windows: $decreaseRequiredCleanDays; threshold <= $throughputLimitMetricAllowance)."
}

# Calculate planned managed target throughput and resulting pool target throughput
$plannedManagedTargetThroughputMibps = [math]::Round((($finalData | Where-Object { $_.ShortName -ne "unallocated" } | Measure-Object -Property NewThroughputValue -Sum).Sum), 3)
$plannedPoolTargetThroughputMibps = [math]::Round(($excludedThroughputMibps + $plannedManagedTargetThroughputMibps), 3)
if ($plannedPoolTargetThroughputMibps -lt $minimumPoolThroughputMibps) {
    $plannedPoolTargetThroughputMibps = $minimumPoolThroughputMibps
}
$poolThroughputDeltaMibps = [math]::Round(($plannedPoolTargetThroughputMibps - $capacityPoolMaxThroughput), 3)
Write-Host "Planned pool throughput target: Current=$capacityPoolMaxThroughput MiB/s, Target=$plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Cyan

# Sort the data to ensure decreases happen first
$finalData = $finalData | Sort-Object -Property NetChangeInThroughputMibs

# If all volumes aside from unallocated are not performant, issue warning
if (($finalData | Where-Object { $_.Performant -eq "No" -and $_.ShortName -ne "unallocated" } | Measure-Object).Count -eq $finalData.Count - 1) {
    Write-Host "***WARNING: All volumes are non-performant. Consider adding throughput capacity to the capacity pool.***" -ForegroundColor Red
    $finalData | Format-Table -AutoSize
    return
}

# If there are no volume or pool throughput changes needed, write a host message and exit. Otherwise, run the rest of the code below.
if ((($finalData | Where-Object { $_.NetChangeInThroughputMibs -ne 0 } | Measure-Object).Count -eq 0) -and ($poolThroughputDeltaMibps -eq 0)) {
    Write-Host "All volumes are already at the correct throughput value. Exiting script." -ForegroundColor Green
    Write-Output "No net throughput deltas detected; leaving pool and volumes unchanged for $TargetResourceGroupName/$TargetAnfAccountName/$TargetAnfPoolName."
    Write-Output "Decision end-state: volumeChanges=0; poolThroughputDeltaMibps=$poolThroughputDeltaMibps."
    $finalData | Format-Table -AutoSize
    return
} else {
    # If $testMode is "No", update the volume settings in Azure with the new throughput values. Otherwise, display the table.
    if ($testMode -eq "No") {
        # Update the volumes with the new throughput values.
        # Apply decreases first, then increases, to maximize available headroom during updates.
        $finalData | Format-Table -AutoSize
        $poolIncreaseNeeded = $plannedPoolTargetThroughputMibps -gt $capacityPoolMaxThroughput
        $poolDecreaseNeeded = $plannedPoolTargetThroughputMibps -lt $capacityPoolMaxThroughput

        if ($poolIncreaseNeeded) {
            Write-Host "Increasing pool throughput before volume updates: $capacityPoolMaxThroughput -> $plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Yellow
            Update-FslPoolThroughputMibps -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
            $anfPool = Get-AnfPool -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName
            $capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps
        }

        $hadVolumeUpdateFailure = $false
        $orderedUpdates = @()
        $orderedUpdates += ($finalData | Where-Object { $_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -lt 0 })
        $orderedUpdates += ($finalData | Where-Object { $_.ShortName -ne "unallocated" -and $_.NetChangeInThroughputMibs -gt 0 })
        $orderedUpdates | ForEach-Object {
            if ($_.ShortName -ne "unallocated") {
                Write-Host "Updating volume `"$($_.ShortName)`" with new throughput value of `"$($_.NewThroughputValue)`" MiB/s" -ForegroundColor Yellow
                $anfVolume = Get-AnfVolume -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName -VolumeName $_.ShortName
                $isDecrease = $_.NewThroughputValue -lt $_.CurrentThroughputMibps
                if (-not $isDecrease) {
                    Set-AnfVolumeThroughput -VolumeObject $anfVolume -TargetThroughputMibps $_.NewThroughputValue
                } else {
                    $retryElapsedSeconds = 0
                    $decreaseUpdateSucceeded = $false
                    while (-not $decreaseUpdateSucceeded) {
                        try {
                            Set-AnfVolumeThroughput -VolumeObject $anfVolume -TargetThroughputMibps $_.NewThroughputValue
                            $decreaseUpdateSucceeded = $true
                        } catch {
                            if ($retryElapsedSeconds -ge $decreaseRetryMaxWaitSeconds) {
                                Write-Host "Decrease update still blocked for volume `"$($_.ShortName)`" after waiting $retryElapsedSeconds seconds. Skipping this decrease for now." -ForegroundColor Yellow
                                $hadVolumeUpdateFailure = $true
                                break
                            }
                            Write-Host "Decrease update blocked for volume `"$($_.ShortName)`". Retrying in $decreaseRetrySleepSeconds seconds (elapsed: $retryElapsedSeconds sec)." -ForegroundColor Yellow
                            Start-Sleep -Seconds $decreaseRetrySleepSeconds
                            $retryElapsedSeconds += $decreaseRetrySleepSeconds
                            $anfVolume = Get-AnfVolume -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName -VolumeName $_.ShortName
                        }
                    }
                }
            }
        }

        if ($poolDecreaseNeeded) {
            if ($hadVolumeUpdateFailure) {
                Write-Host "Skipping pool throughput decrease because one or more volume updates did not complete successfully." -ForegroundColor Yellow
            } else {
                Write-Host "Decreasing pool throughput after volume updates: $capacityPoolMaxThroughput -> $plannedPoolTargetThroughputMibps MiB/s" -ForegroundColor Yellow
                Update-FslPoolThroughputMibps -PoolResourceId $anfPool.Id -TargetThroughputMibps $plannedPoolTargetThroughputMibps
                $anfPool = Get-AnfPool -ResourceGroupName $TargetResourceGroupName -AccountName $TargetAnfAccountName -PoolName $TargetAnfPoolName
                $capacityPoolMaxThroughput = $anfPool.TotalThroughputMibps
            }
        }
    } else {
        if ($poolThroughputDeltaMibps -gt 0) {
            Write-Host "TEST MODE: Pool throughput would be increased to $plannedPoolTargetThroughputMibps MiB/s before volume updates." -ForegroundColor Yellow
        } elseif ($poolThroughputDeltaMibps -lt 0) {
            Write-Host "TEST MODE: Pool throughput would be decreased to $plannedPoolTargetThroughputMibps MiB/s after volume updates." -ForegroundColor Yellow
        }
        $finalData | Format-Table -AutoSize
    }
}
}

$targetPools = @()
$targetPools = Get-AnfCapacityPoolsByTag -TagKey $targetPoolIncludeTagKey -TagValue $targetPoolIncludeTagValue

if ($targetPools.Count -eq 0 -and
    $resourceGroupName -and
    $anfAccountName -and
    $anfPoolName) {
    Write-Host "No tagged pools found. Falling back to configured single target: $resourceGroupName / $anfAccountName / $anfPoolName" -ForegroundColor Yellow
    Write-Output "Target discovery: no tagged pools matched; using fallback single target $resourceGroupName/$anfAccountName/$anfPoolName."
    $targetPools += [PSCustomObject]@{
        ResourceGroupName = $resourceGroupName
        AccountName = $anfAccountName
        PoolName = $anfPoolName
    }
}

if ($targetPools.Count -eq 0) {
    Write-Host "No target pools found. Tag capacity pools with $targetPoolIncludeTagKey=$targetPoolIncludeTagValue to include them." -ForegroundColor Yellow
    Write-Output "Target discovery: found 0 targets. Tag capacity pools with $targetPoolIncludeTagKey=$targetPoolIncludeTagValue to include them."
    exit
}
Write-Output "Target discovery: found $($targetPools.Count) pool(s) to process."
foreach ($targetPool in $targetPools) {
    Write-Output "Target pool: $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName)"
}

$failedPools = @()
foreach ($targetPool in $targetPools) {
    try {
        Write-Output "Starting pool processing: $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName)"
        Invoke-FslSelfLevelingForPool -TargetResourceGroupName $targetPool.ResourceGroupName -TargetAnfAccountName $targetPool.AccountName -TargetAnfPoolName $targetPool.PoolName
        Write-Output "Completed pool processing: $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName)"
    } catch {
        $failedPools += "$($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName): $($_.Exception.Message)"
        Write-Host "Failed processing pool $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName): $($_.Exception.Message)" -ForegroundColor Red
        Write-Output "Failed pool processing: $($targetPool.ResourceGroupName)/$($targetPool.AccountName)/$($targetPool.PoolName): $($_.Exception.Message)"
    }
}

if ($failedPools.Count -gt 0) {
    Write-Output "Run summary: processed $($targetPools.Count) pool(s), failures=$($failedPools.Count)."
    throw "One or more target pools failed processing:`n$($failedPools -join "`n")"
}
Write-Output "Run summary: processed $($targetPools.Count) pool(s), failures=0."
