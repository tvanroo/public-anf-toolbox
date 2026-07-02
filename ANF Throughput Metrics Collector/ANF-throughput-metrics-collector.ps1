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
- One or more capacity pools, supplied as full Resource IDs.
- All volumes in each pool, or a filtered set of volume names.

Settings can be supplied as Azure Automation variables or as process environment variables with the same names.

Required:
- ANF_CapacityPoolResourceId: One or more capacity pool Resource IDs separated by new lines, semicolons, or commas.

Optional:
- ANF_TenantId: Azure tenant ID. If omitted, the current Azure context tenant is used.
- ANF_VolumeName: Optional volume name filter. Multiple values can be separated by new lines, semicolons, or commas.
- ANF_LookBackDays: Metric lookback in days. Default: 30.
- ANF_TimeGrainMinutes: Metric interval in minutes. Default: 5.
- ANF_OutputPath: CSV output path. Default: ./ANF-throughput-metrics.csv.
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

        $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq $propertyName } | Select-Object -First 1
        if ($property) {
            return $property.Value
        }
    }

    return $null
}

$tenantId = Get-AnfSetting -Name "ANF_TenantId" -Default ""
$capacityPoolResourceIdSetting = Get-AnfSetting -Name "ANF_CapacityPoolResourceId"
$anfTargets = @()
if ($capacityPoolResourceIdSetting) {
    $anfTargets = @(Resolve-AnfCapacityPoolResourceIds -CapacityPoolResourceIds $capacityPoolResourceIdSetting)
}

if ($anfTargets.Count -eq 0) {
    Write-Error "ANF_CapacityPoolResourceId must be set before running this script"
    throw "Missing required variable: ANF_CapacityPoolResourceId"
}

$lookBackDays = Convert-AnfSettingToInt -Name "ANF_LookBackDays" -Value (Get-AnfSetting -Name "ANF_LookBackDays" -Default 30) -Minimum 1
$timeGrainMinutes = Convert-AnfSettingToInt -Name "ANF_TimeGrainMinutes" -Value (Get-AnfSetting -Name "ANF_TimeGrainMinutes" -Default 5) -Minimum 1
$outputPath = "$((Get-AnfSetting -Name "ANF_OutputPath" -Default "./ANF-throughput-metrics.csv"))"
$overwriteOutput = "$((Get-AnfSetting -Name "ANF_OverwriteOutput" -Default "No"))"
$volumeNameFilters = @(Split-AnfSettingList -Value (Get-AnfSetting -Name "ANF_VolumeName" -Default ""))
$metricNames = "ReadThroughput,WriteThroughput,TotalThroughput,OtherThroughput"

if (-not (Test-AnfYes -Value $overwriteOutput) -and -not "$overwriteOutput".Trim().Equals("No", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ANF_OverwriteOutput must be Yes or No. Current value: '$overwriteOutput'"
}

if ((Test-Path -LiteralPath $outputPath) -and -not (Test-AnfYes -Value $overwriteOutput)) {
    throw "Output file already exists: $outputPath. Set ANF_OverwriteOutput to Yes or choose a different ANF_OutputPath."
}

Write-Output "=== ANF Throughput Metrics Collector Configuration ==="
Write-Output "Execution Mode: $(if ($runningInAutomation) { 'Azure Automation Account' } else { 'Local/Manual Execution' })"
Write-Output "Capacity Pool Targets: $($anfTargets.Count)"
foreach ($anfTarget in $anfTargets) {
    Write-Output "  - $($anfTarget.CapacityPoolResourceId)"
}
Write-Output "Volume Filter: $(if ($volumeNameFilters.Count -gt 0) { $volumeNameFilters -join ', ' } else { 'All volumes in each pool' })"
Write-Output "Lookback: $lookBackDays day(s)"
Write-Output "Interval: $timeGrainMinutes minute(s)"
Write-Output "Output Path: $outputPath"
Write-Output "Overwrite Output: $overwriteOutput"

$anfApiVersion = "2026-04-01"

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
    $volumesCandidate = Invoke-AnfArmJson -Method "GET" -ResourceId $resourceId -ApiVersion $anfApiVersion
    $volumes = @()
    if ($volumesCandidate -and $volumesCandidate.value) {
        $volumes = @($volumesCandidate.value)
    } elseif ($volumesCandidate -and $volumesCandidate.id) {
        $volumes = @($volumesCandidate)
    }

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
        $filterSet = @{}
        foreach ($volumeNameFilter in $volumeNameFilters) {
            $filterSet[$volumeNameFilter.ToLowerInvariant()] = $true
        }
        $anfVolumes = @($anfVolumes | Where-Object { $filterSet.ContainsKey($_.Name.ToLowerInvariant()) })
        if ($anfVolumes.Count -eq 0) {
            Write-Warning "No volumes in '$anfPoolName' matched ANF_VolumeName filter: $($volumeNameFilters -join ', ')"
            continue
        }
    }

    Write-Output "Collecting $metricNames from $($anfVolumes.Count) volume(s), $($startTimeUtc.ToString('u')) through $($endTimeUtc.ToString('u'))"
    foreach ($anfVolume in $anfVolumes) {
        Write-Output "Collecting metrics for volume '$($anfVolume.Name)'..."
        try {
            $metricResponse = Get-AnfMetricSeries -ResourceId $anfVolume.Id -MetricNames $metricNames -StartTimeUtc $startTimeUtc -EndTimeUtc $endTimeUtc -TimeGrainMinutes $timeGrainMinutes
            foreach ($metric in @($metricResponse.value)) {
                $metricName = Get-AnfObjectProperty -InputObject $metric.name -PropertyNames @('value', 'Value', 'localizedValue', 'LocalizedValue')
                foreach ($timeSeries in @($metric.timeseries)) {
                    foreach ($dataPoint in @($timeSeries.data)) {
                        if ($null -ne $dataPoint.average) {
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
                                AverageBytesPerSecond = [math]::Round([double]$dataPoint.average, 3)
                                AverageMiBps = [math]::Round(([double]$dataPoint.average / 1024 / 1024), 3)
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
    Write-Warning "No metrics data was collected. Check pool IDs, volume filters, metric availability, and RBAC permissions."
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
