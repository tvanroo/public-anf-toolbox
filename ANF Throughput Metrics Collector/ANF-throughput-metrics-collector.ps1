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
Collect historical Azure NetApp Files volume throughput metrics and export the data to CSV.
This script is read-only. It does not resize pools, resize volumes, change QoS, or modify ANF resources.

Supported targets:
- Standard, Premium, Ultra, and Flexible Service Level capacity pools.
- All visible ANF capacity pools discovered from the authenticated Azure context by default.
- One or more explicit capacity pools, optionally supplied as full Resource IDs.
- Optional account, pool, and volume text filters.

Settings can be supplied as Azure Automation variables or as process environment variables with the same names.

Required:
- None. With no target variables set, the script discovers ANF capacity pools visible to the authenticated identity.

Optional:
- ANF_TenantId: Azure tenant ID. If omitted, the current Azure context tenant is used.
- ANF_SubscriptionId: Optional subscription ID or name used for discovery. If omitted and multiple active subscriptions are visible, local runs prompt for one.
- ANF_CapacityPoolResourceId: Optional explicit capacity pool Resource IDs separated by new lines, semicolons, or commas.
- ANF_AccountNameFilter: Optional account name text filter. Multiple values can be separated by new lines, semicolons, or commas.
- ANF_PoolNameFilter: Optional capacity pool name text filter. Multiple values can be separated by new lines, semicolons, or commas.
- ANF_VolumeNameFilter: Optional volume name text filter. Multiple values can be separated by new lines, semicolons, or commas.
- ANF_LookBackDays: Metric lookback in days. Default: 30.
- ANF_TimeGrainMinutes: Metric interval in minutes. Default: 5.
- ANF_OutputPath: CSV output path. Default: timestamped ./ANF-throughput-metrics-<yyyyMMdd-HHmmssZ>.csv.
- ANF_OverwriteOutput: Yes/No overwrite guard for existing CSV output. Default: No.
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

function Split-AnfSettingList {
    param([Parameter()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return @()
    }

    return @("$Value" -split '[\r\n;,]+' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Test-AnfTextFilter {
    param(
        [Parameter(Mandatory=$true)][string]$Value,
        [Parameter()][string[]]$Filters = @()
    )

    if ($Filters.Count -eq 0) {
        return $true
    }

    foreach ($filter in $Filters) {
        if ($Value.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
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

    $tokens = @(Split-AnfSettingList -Value $CapacityPoolResourceIds)
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

        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ("$key".Equals($propertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }

        $property = $InputObject.PSObject.Properties | Where-Object { $_.Name.Equals($propertyName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

$tenantId = Get-AnfSetting -Name "ANF_TenantId" -Default ""
$subscriptionSelectionSetting = Get-AnfSetting -Name "ANF_SubscriptionId" -Default ""
$subscriptionSelections = @(Split-AnfSettingList -Value $subscriptionSelectionSetting)
$capacityPoolResourceIdSetting = Get-AnfSetting -Name "ANF_CapacityPoolResourceId" -Default ""
$anfTargets = @()
if ($capacityPoolResourceIdSetting) {
    $anfTargets = @(Resolve-AnfCapacityPoolResourceIds -CapacityPoolResourceIds $capacityPoolResourceIdSetting)
}

$lookBackDays = Convert-AnfSettingToInt -Name "ANF_LookBackDays" -Value (Get-AnfSetting -Name "ANF_LookBackDays" -Default 30) -Minimum 1
$timeGrainMinutes = Convert-AnfSettingToInt -Name "ANF_TimeGrainMinutes" -Value (Get-AnfSetting -Name "ANF_TimeGrainMinutes" -Default 5) -Minimum 1
$runTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssZ")
$defaultOutputPath = "./ANF-throughput-metrics-$runTimestamp.csv"
$outputPath = "$((Get-AnfSetting -Name "ANF_OutputPath" -Default $defaultOutputPath))"
$overwriteOutput = "$((Get-AnfSetting -Name "ANF_OverwriteOutput" -Default "No"))"
$accountNameFilters = @(Split-AnfSettingList -Value (Get-AnfSetting -Name "ANF_AccountNameFilter" -Default ""))
$poolNameFilters = @(Split-AnfSettingList -Value (Get-AnfSetting -Name "ANF_PoolNameFilter" -Default ""))
$volumeNameFilterSetting = Get-AnfSetting -Name "ANF_VolumeNameFilter" -Default (Get-AnfSetting -Name "ANF_VolumeName" -Default "")
$volumeNameFilters = @(Split-AnfSettingList -Value $volumeNameFilterSetting)
$metricNames = "ReadThroughput,WriteThroughput,TotalThroughput,OtherThroughput,throughputLimitReached"

if (-not (Test-AnfYes -Value $overwriteOutput) -and -not "$overwriteOutput".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ANF_OverwriteOutput must be Yes or No. Current value: '$overwriteOutput'"
}

if ((Test-Path -LiteralPath $outputPath) -and -not (Test-AnfYes -Value $overwriteOutput)) {
    throw "Output file already exists: $outputPath. Set ANF_OverwriteOutput to Yes or choose a different ANF_OutputPath."
}

Write-Output "=== ANF Throughput Metrics Collector Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Target Mode: $(if ($anfTargets.Count -gt 0) { 'Explicit capacity pool Resource ID list' } else { 'Discovery across visible Azure subscriptions' })"
if ($anfTargets.Count -gt 0) {
    Write-Output "Explicit Capacity Pool Targets: $($anfTargets.Count)"
    foreach ($anfTarget in $anfTargets) {
        Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
    }
}
Write-Output "Account Filter: $(if ($accountNameFilters.Count -gt 0) { $accountNameFilters -join ', ' } else { 'None' })"
Write-Output "Pool Filter: $(if ($poolNameFilters.Count -gt 0) { $poolNameFilters -join ', ' } else { 'None' })"
Write-Output "Volume Filter: $(if ($volumeNameFilters.Count -gt 0) { $volumeNameFilters -join ', ' } else { 'All volumes in each matched pool' })"
Write-Output "Subscription Selection: $(if ($subscriptionSelections.Count -gt 0) { $subscriptionSelections -join ', ' } elseif ($anfTargets.Count -gt 0) { 'Derived from explicit capacity pool Resource ID(s)' } else { 'Prompt when multiple active subscriptions are visible' })"
Write-Output "Metrics: $metricNames"
Write-Output "Lookback: $lookBackDays day(s)"
Write-Output "Interval: $timeGrainMinutes minute(s)"
Write-Output "Output Path: $outputPath"
Write-Output "Overwrite Output: $overwriteOutput"

$anfApiVersion = "2026-04-01"

function New-AnfArmHeaders {
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
        Headers = @{
            'Authorization' = "Bearer $token"
            'Content-Type' = 'application/json'
        }
    }
}

function Invoke-AnfArmUriJson {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter()][string]$BodyJson,
        [Parameter()][object]$ArmContext = $null
    )

    if (-not $ArmContext) {
        $ArmContext = New-AnfArmHeaders
    }

    if ($BodyJson) {
        return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $ArmContext.Headers -Body $BodyJson -ErrorAction Stop
    }

    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $ArmContext.Headers -ErrorAction Stop
}

function Invoke-AnfArmJson {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion,
        [Parameter()][string]$QueryString = "",
        [Parameter()][string]$BodyJson
    )

    $armContext = New-AnfArmHeaders
    $normalizedQueryString = ""
    if ($QueryString) {
        $normalizedQueryString = "$QueryString"
        if ($normalizedQueryString.StartsWith("?")) {
            $normalizedQueryString = "&$($normalizedQueryString.Substring(1))"
        } elseif (-not $normalizedQueryString.StartsWith("&")) {
            $normalizedQueryString = "&$normalizedQueryString"
        }
    }

    $uri = "$($armContext.ResourceManagerUrl)$ResourceId" + "?api-version=$ApiVersion$normalizedQueryString"
    return Invoke-AnfArmUriJson -Method $Method -Uri $uri -BodyJson $BodyJson -ArmContext $armContext
}

function Get-AnfArmListValues {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$ApiVersion
    )

    $values = @()
    $response = Invoke-AnfArmJson -Method "GET" -ResourceId $ResourceId -ApiVersion $ApiVersion
    while ($response) {
        $valueProperty = $response.PSObject.Properties | Where-Object { $_.Name.Equals("value", [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($valueProperty) {
            if ($null -ne $valueProperty.Value) {
                $values += @($valueProperty.Value)
            }
        } elseif (Get-AnfObjectProperty -InputObject $response -PropertyNames @('id', 'Id')) {
            $values += $response
        }

        $nextLink = Get-AnfObjectProperty -InputObject $response -PropertyNames @('nextLink', 'NextLink')
        if (-not $nextLink) {
            break
        }

        $response = Invoke-AnfArmUriJson -Method "GET" -Uri $nextLink
    }

    return @($values)
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

function Resolve-AnfNetAppAccountResourceId {
    param([Parameter(Mandatory=$true)][string]$AccountResourceId)

    $normalizedResourceId = "$AccountResourceId".Trim().TrimEnd("/")
    $pattern = '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.NetApp/netAppAccounts/([^/]+)$'
    if ($normalizedResourceId -notmatch $pattern) {
        throw "Unexpected ANF account Resource ID format: $AccountResourceId"
    }

    return [PSCustomObject]@{
        AccountResourceId = $normalizedResourceId
        SubscriptionId = $Matches[1]
        ResourceGroupName = $Matches[2]
        AccountName = $Matches[3]
    }
}

function Test-AnfCapacityPoolTarget {
    param([Parameter()][object]$Target)

    if ($null -eq $Target) {
        return $false
    }

    foreach ($propertyName in @('CapacityPoolResourceId', 'SubscriptionId', 'ResourceGroupName', 'AccountName', 'PoolName')) {
        $value = Get-AnfObjectProperty -InputObject $Target -PropertyNames @($propertyName)
        if ([string]::IsNullOrWhiteSpace("$value")) {
            return $false
        }
    }

    return $true
}

function Select-AnfCapacityPoolTargets {
    param(
        [Parameter(Mandatory=$true)][object[]]$Targets,
        [Parameter()][string[]]$AccountFilters = @(),
        [Parameter()][string[]]$PoolFilters = @()
    )

    return @($Targets | Where-Object {
        (Test-AnfCapacityPoolTarget -Target $_) -and
        (Test-AnfTextFilter -Value $_.AccountName -Filters $AccountFilters) -and
        (Test-AnfTextFilter -Value $_.PoolName -Filters $PoolFilters)
    })
}

function Get-AnfSubscriptionIdFromObject {
    param([Parameter(Mandatory=$true)][object]$Subscription)

    $subscriptionId = Get-AnfObjectProperty -InputObject $Subscription -PropertyNames @('Id', 'SubscriptionId')
    return "$subscriptionId"
}

function Get-AnfSubscriptionNameFromObject {
    param([Parameter(Mandatory=$true)][object]$Subscription)

    $subscriptionName = Get-AnfObjectProperty -InputObject $Subscription -PropertyNames @('Name', 'SubscriptionName')
    if ([string]::IsNullOrWhiteSpace("$subscriptionName")) {
        return (Get-AnfSubscriptionIdFromObject -Subscription $Subscription)
    }

    return "$subscriptionName"
}

function Select-AnfDiscoverySubscriptions {
    param(
        [Parameter(Mandatory=$true)][object[]]$Subscriptions,
        [Parameter()][string[]]$SubscriptionSelections = @()
    )

    if ($SubscriptionSelections.Count -gt 0) {
        $matchedSubscriptions = @($Subscriptions | Where-Object {
            $subscriptionId = Get-AnfSubscriptionIdFromObject -Subscription $_
            $subscriptionName = Get-AnfSubscriptionNameFromObject -Subscription $_
            $isMatch = $false
            foreach ($selection in $SubscriptionSelections) {
                if ($subscriptionId.Equals($selection, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $subscriptionName.Equals($selection, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isMatch = $true
                    break
                }
            }
            $isMatch
        })

        if ($matchedSubscriptions.Count -eq 0) {
            throw "ANF_SubscriptionId did not match any visible active subscription by ID or name: $($SubscriptionSelections -join ', ')"
        }

        return @($matchedSubscriptions)
    }

    if ($Subscriptions.Count -le 1) {
        return @($Subscriptions)
    }

    if ($runningInAutomation) {
        $context = Get-AzContext -ErrorAction Stop
        $contextSubscriptionId = if ($context.Subscription -and $context.Subscription.Id) { "$($context.Subscription.Id)" } else { "" }
        if (-not $contextSubscriptionId) {
            throw "Multiple active subscriptions are visible and no current subscription context is available. Set ANF_SubscriptionId."
        }

        $currentSubscription = @($Subscriptions | Where-Object { (Get-AnfSubscriptionIdFromObject -Subscription $_).Equals($contextSubscriptionId, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
        if ($currentSubscription.Count -eq 0) {
            throw "Current subscription '$contextSubscriptionId' was not found in the visible subscription list. Set ANF_SubscriptionId."
        }

        Write-Warning "Multiple active subscriptions are visible. Azure Automation cannot prompt, so discovery is limited to current subscription '$contextSubscriptionId'."
        return @($currentSubscription)
    }

    $subscriptionPromptLines = [System.Collections.Generic.List[string]]::new()
    $subscriptionPromptLines.Add("")
    $subscriptionPromptLines.Add("Multiple active Azure subscriptions are visible. Select one for ANF discovery:")
    for ($index = 0; $index -lt $Subscriptions.Count; $index++) {
        $subscription = $Subscriptions[$index]
        $subscriptionPromptLines.Add(("  [{0}] {1} ({2})" -f ($index + 1), (Get-AnfSubscriptionNameFromObject -Subscription $subscription), (Get-AnfSubscriptionIdFromObject -Subscription $subscription)))
    }
    $subscriptionPromptLines.Add("Enter subscription number")
    $subscriptionPrompt = $subscriptionPromptLines -join [Environment]::NewLine

    while ($true) {
        $selection = Read-Host $subscriptionPrompt
        $selectionNumber = 0
        if ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $Subscriptions.Count) {
            return @($Subscriptions[$selectionNumber - 1])
        }

        Write-Warning "Invalid selection '$selection'. Enter a number from 1 to $($Subscriptions.Count)."
    }
}

function Get-AnfDiscoverySubscriptions {
    param([Parameter()][string[]]$SubscriptionSelections = @())

    $subscriptions = @()
    try {
        $subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object {
            -not $_.State -or "$($_.State)".Equals("Enabled", [System.StringComparison]::OrdinalIgnoreCase)
        })
    } catch {
        Write-Warning "Unable to enumerate Azure subscriptions; falling back to the current context subscription. $($_.Exception.Message)"
    }

    if ($subscriptions.Count -gt 0) {
        return @(Select-AnfDiscoverySubscriptions -Subscriptions $subscriptions -SubscriptionSelections $SubscriptionSelections)
    }

    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Subscription -or -not $context.Subscription.Id) {
        throw "Unable to resolve a subscription for ANF discovery. Set an Azure context or provide ANF_CapacityPoolResourceId."
    }

    return @([PSCustomObject]@{
        Id = $context.Subscription.Id
        Name = $context.Subscription.Name
        State = "Current"
    })
}

function Get-AnfDiscoveredCapacityPoolTargets {
    param(
        [Parameter()][string[]]$SubscriptionSelections = @(),
        [Parameter()][string[]]$AccountFilters = @(),
        [Parameter()][string[]]$PoolFilters = @()
    )

    $targets = @()
    $seenResourceIds = @{}
    $subscriptions = @(Get-AnfDiscoverySubscriptions -SubscriptionSelections $SubscriptionSelections)
    Write-Host "Discovering ANF capacity pools in $($subscriptions.Count) selected subscription(s)..."

    foreach ($subscription in $subscriptions) {
        $subscriptionId = Get-AnfSubscriptionIdFromObject -Subscription $subscription
        $subscriptionName = Get-AnfSubscriptionNameFromObject -Subscription $subscription
        if (-not $subscriptionId) {
            Write-Warning "Skipping subscription entry with no subscription ID."
            continue
        }

        try {
            $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
            Write-Host "Scanning subscription: $subscriptionName ($subscriptionId)"
            $accountResourceId = "/subscriptions/$subscriptionId/providers/Microsoft.NetApp/netAppAccounts"
            $accounts = @(Get-AnfArmListValues -ResourceId $accountResourceId -ApiVersion $anfApiVersion)
        } catch {
            Write-Warning "Skipping subscription '$subscriptionName' because ANF account discovery failed: $($_.Exception.Message)"
            continue
        }

        foreach ($account in $accounts) {
            try {
                $accountId = Get-AnfObjectProperty -InputObject $account -PropertyNames @('id', 'Id')
                if ([string]::IsNullOrWhiteSpace("$accountId")) {
                    Write-Warning "Skipping ANF account response without a Resource ID."
                    continue
                }

                $accountTarget = Resolve-AnfNetAppAccountResourceId -AccountResourceId $accountId
            } catch {
                Write-Warning $_.Exception.Message
                continue
            }

            if (-not (Test-AnfTextFilter -Value $accountTarget.AccountName -Filters $AccountFilters)) {
                continue
            }

            try {
                $poolCollectionId = "$($accountTarget.AccountResourceId)/capacityPools"
                $pools = @(Get-AnfArmListValues -ResourceId $poolCollectionId -ApiVersion $anfApiVersion)
            } catch {
                Write-Warning "Unable to list capacity pools for ANF account '$($accountTarget.AccountName)': $($_.Exception.Message)"
                continue
            }

            foreach ($pool in $pools) {
                try {
                    $poolId = Get-AnfObjectProperty -InputObject $pool -PropertyNames @('id', 'Id')
                    if ([string]::IsNullOrWhiteSpace("$poolId")) {
                        Write-Warning "Skipping capacity pool response in ANF account '$($accountTarget.AccountName)' because it did not include a Resource ID."
                        continue
                    }

                    $poolTarget = Resolve-AnfCapacityPoolResourceId -CapacityPoolResourceId $poolId
                } catch {
                    Write-Warning $_.Exception.Message
                    continue
                }

                if (-not (Test-AnfCapacityPoolTarget -Target $poolTarget)) {
                    Write-Warning "Skipping capacity pool response in ANF account '$($accountTarget.AccountName)' because its Resource ID metadata was incomplete."
                    continue
                }

                if (-not (Test-AnfTextFilter -Value $poolTarget.PoolName -Filters $PoolFilters)) {
                    continue
                }

                $dedupeKey = $poolTarget.CapacityPoolResourceId.ToLowerInvariant()
                if ($seenResourceIds.ContainsKey($dedupeKey)) {
                    continue
                }

                $seenResourceIds[$dedupeKey] = $true
                $targets += $poolTarget
            }
        }
    }

    return @($targets)
}

function Test-AnfThroughputMetric {
    param([Parameter(Mandatory=$true)][string]$MetricName)

    return @('ReadThroughput', 'WriteThroughput', 'TotalThroughput', 'OtherThroughput').Contains($MetricName)
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

function Convert-AnfRestVolume {
    param([Parameter(Mandatory=$true)][object]$Volume)

    return [PSCustomObject]@{
        Id = $Volume.id
        Name = Get-AnfVolumeShortName -VolumeObject $Volume
        Raw = $Volume
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
    if (-not $poolCandidate -or -not $poolCandidate.properties) {
        throw "Unable to parse capacity pool REST response for $ResourceGroupName/$AccountName/$PoolName."
    }

    return $poolCandidate
}

function Get-AnfVolumes {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$PoolName
    )

    $resourceId = "$(New-AnfResourceId -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -AccountName $AccountName -PoolName $PoolName)/volumes"
    $volumes = @(Get-AnfArmListValues -ResourceId $resourceId -ApiVersion $anfApiVersion)

    return @($volumes | ForEach-Object { Convert-AnfRestVolume -Volume $_ })
}

function Get-AnfMetricSeries {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$MetricNames,
        [Parameter(Mandatory=$true)][datetime]$StartTimeUtc,
        [Parameter(Mandatory=$true)][datetime]$EndTimeUtc,
        [Parameter(Mandatory=$true)][int]$TimeGrainMinutes
    )

    $interval = "PT${TimeGrainMinutes}M"
    $timespan = "{0:o}/{1:o}" -f $StartTimeUtc, $EndTimeUtc
    $queryString = "&metricnames=$([uri]::EscapeDataString($MetricNames))&timespan=$([uri]::EscapeDataString($timespan))&interval=$interval&aggregation=Average"
    $metricsResourceId = "$ResourceId/providers/microsoft.insights/metrics"
    return Invoke-AnfArmJson -Method "GET" -ResourceId $metricsResourceId -ApiVersion "2018-01-01" -QueryString $queryString
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
        Write-Output "Successfully authenticated using Managed Identity"
    } else {
        try {
            $currentContext = Get-AzContext -ErrorAction Stop
            if ($currentContext -and $currentContext.Account -and $currentContext.Account.Id) {
                Write-Output "Already authenticated to Azure as: $($currentContext.Account.Id)"
                if ($tenantId -and $currentContext.Tenant.Id -ne $tenantId) {
                    Write-Output "Switching to specified tenant: $tenantId"
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
            Write-Output "No valid existing Azure context found; starting device authentication."
            if ($tenantId) {
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

if ($anfTargets.Count -gt 0) {
    $anfTargets = @(Select-AnfCapacityPoolTargets -Targets $anfTargets -AccountFilters $accountNameFilters -PoolFilters $poolNameFilters)
} else {
    $anfTargets = @(Get-AnfDiscoveredCapacityPoolTargets -SubscriptionSelections $subscriptionSelections -AccountFilters $accountNameFilters -PoolFilters $poolNameFilters)
}

if ($anfTargets.Count -eq 0) {
    Write-Warning "No ANF capacity pools matched the current context and filters. No metrics were collected."
    return
}

Write-Output "Matched Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}

$endTimeUtc = (Get-Date).ToUniversalTime()
$startTimeUtc = $endTimeUtc.AddDays(-$lookBackDays)
$allMetricsData = @()
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

    $anfPool = Get-AnfPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName
    $serviceLevel = Get-AnfObjectProperty -InputObject $anfPool.properties -PropertyNames @('serviceLevel', 'ServiceLevel')
    $qosType = Get-AnfObjectProperty -InputObject $anfPool.properties -PropertyNames @('qosType', 'QosType')
    Write-Output "Pool details: ServiceLevel=$serviceLevel; QoS=$qosType"

    $anfVolumes = @(Get-AnfVolumes -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName)
    if ($anfVolumes.Count -eq 0) {
        Write-Warning "No volumes found in capacity pool '$anfPoolName'. Skipping pool."
        continue
    }

    if ($volumeNameFilters.Count -gt 0) {
        $anfVolumes = @($anfVolumes | Where-Object { Test-AnfTextFilter -Value $_.Name -Filters $volumeNameFilters })
        if ($anfVolumes.Count -eq 0) {
            Write-Warning "No volumes in '$anfPoolName' matched ANF_VolumeNameFilter: $($volumeNameFilters -join ', ')"
            continue
        }
    }

    Write-Output "Collecting $metricNames from $($anfVolumes.Count) volume(s), $($startTimeUtc.ToString('u')) through $($endTimeUtc.ToString('u'))"
    foreach ($anfVolume in $anfVolumes) {
        Write-Output "Collecting metrics for volume '$($anfVolume.Name)'..."
        try {
            $metricResponse = Get-AnfMetricSeries -ResourceId $anfVolume.Id -MetricNames $metricNames -StartTimeUtc $startTimeUtc -EndTimeUtc $endTimeUtc -TimeGrainMinutes $timeGrainMinutes
            foreach ($metric in @($metricResponse.value)) {
                $metricName = "$(Get-AnfObjectProperty -InputObject $metric.name -PropertyNames @('value', 'Value', 'localizedValue', 'LocalizedValue'))"
                $metricUnit = Get-AnfObjectProperty -InputObject $metric -PropertyNames @('unit', 'Unit')
                $isThroughputMetric = Test-AnfThroughputMetric -MetricName $metricName
                foreach ($timeSeries in @($metric.timeseries)) {
                    foreach ($dataPoint in @($timeSeries.data)) {
                        if ($null -ne $dataPoint.average) {
                            $averageValue = [double]$dataPoint.average
                            $allMetricsData += [PSCustomObject]@{
                                Timestamp = $dataPoint.timeStamp
                                SubscriptionId = $subscriptionId
                                ResourceGroup = $resourceGroupName
                                ANFAccount = $anfAccountName
                                ANFPool = $anfPoolName
                                ServiceLevel = $serviceLevel
                                QoSType = $qosType
                                VolumeName = $anfVolume.Name
                                VolumeId = $anfVolume.Id
                                MetricName = $metricName
                                MetricUnit = if ($metricUnit) { $metricUnit } elseif ($isThroughputMetric) { "BytesPerSecond" } else { "Value" }
                                AverageValue = [math]::Round($averageValue, 3)
                                AverageBytesPerSecond = if ($isThroughputMetric) { [math]::Round($averageValue, 3) } else { $null }
                                AverageMiBps = if ($isThroughputMetric) { [math]::Round(($averageValue / 1024 / 1024), 3) } else { $null }
                                TimeGrainMinutes = $timeGrainMinutes
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Warning "Failed collecting metrics for volume '$($anfVolume.Name)': $($_.Exception.Message)"
        }
    }
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
    throw "ANF throughput metrics collection failed for $($failedCapacityPools.Count) pool(s)."
}

if ($allMetricsData.Count -eq 0) {
    Write-Warning "No metrics data was collected. Check discovery scope, filters, metric availability, and RBAC permissions."
    return
}

$outputDirectory = Split-Path -Path $outputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
}

$exportParams = @{
    Path = $outputPath
    NoTypeInformation = $true
}
if (Test-AnfYes -Value $overwriteOutput) {
    $exportParams.Force = $true
}

$allMetricsData | Sort-Object Timestamp, ANFAccount, ANFPool, VolumeName, MetricName | Export-Csv @exportParams

$uniqueVolumes = @($allMetricsData | Select-Object -ExpandProperty VolumeId -Unique).Count
$dateRange = $allMetricsData | Measure-Object -Property Timestamp -Minimum -Maximum
Write-Output ""
Write-Output "Metrics collection completed successfully."
Write-Output "Total data points collected: $($allMetricsData.Count)"
Write-Output "Volumes processed: $uniqueVolumes"
Write-Output "Date range: $($dateRange.Minimum) to $($dateRange.Maximum)"
Write-Output "Data exported to: $outputPath"
