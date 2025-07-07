<# *********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
This repository is published publicly as a resource for other Azure NetApp Files (ANF) and Azure specialists. However, please be aware of the following:

1. **Unofficial Content:** Nothing in this repository is official, supported, or fully tested. This content is my own personal work and is not warranted in any way.
2. **No Endorsement:** While I work for NetApp, none of this content is officially from NetApp nor Microsoft, nor is it endorsed or supported by NetApp or Microsoft.
3. **Use at Your Own Risk:** Please use good judgment, test anything you'll run, and ensure you fully understand any code or scripts you use from this repository.

By using any content from this repository, you acknowledge that you do so at your own risk and that you are solely responsible for any consequences that may arise.
*********************** WARNING: UNSUPPORTED SCRIPT. USE AT YOUR OWN RISK. ************************
Last Edit Date: 07/07/2025
https://github.com/tvanroo/public-anf-toolbox
Author: Toby vanRoojen - toby.vanroojen (at) netapp.com

Script Purpose:
This script collects the last 30 days of total throughput metrics for Azure NetApp Files volumes 
with 5-minute resolution and exports the data to CSV format.

Azure Automation Account Requirements:
To run via an Azure Automation Script, the script must be modified to authenticate to Azure using a Service Principal. 
Use "Connect-AzAccount -Identity" instead of "Connect-AzAccount".

#>

# Install az modules and az.netappfiles module if needed
# Install-Module -Name Az -Force -AllowClobber
# Install-Module -Name Az.NetAppFiles -Force -AllowClobber

# Check for required modules
Write-Host "Checking for required Azure PowerShell modules..." -ForegroundColor Cyan

$requiredModules = @('Az.Accounts', 'Az.NetAppFiles', 'Az.Monitor')
foreach ($module in $requiredModules) {
    try {
        $moduleInfo = Get-Module -Name $module -ListAvailable | Select-Object -First 1
        if ($moduleInfo) {
            Write-Host "  ✓ $module ($($moduleInfo.Version)) is available" -ForegroundColor Green
        } else {
            Write-Host "  ✗ $module is not installed" -ForegroundColor Red
            Write-Host "    Please install with: Install-Module -Name $module -Force -AllowClobber" -ForegroundColor Yellow
            exit 1
        }
    }
    catch {
        Write-Host "  ✗ Error checking module $module`: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# User Configurable Variables for Volume Identification:
$tenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"      # Tenant ID for the Azure subscription
$subscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" # Subscription ID (optional - will use current context if not specified)
$resourceGroupName = "example-rg"                       # Resource group name where the Azure NetApp Files resources are located
$anfAccountName = "example-anf-acct"                    # Azure NetApp Files account name
$anfPoolName = "example-anf-pool"                       # Azure NetApp Files capacity pool name
$volumeName = ""                                        # Specific volume name (leave empty to collect for all volumes in pool)

# Script Configuration Variables:
$lookBackDays = 30                                      # Number of days to look back for metrics (30 days)
$outputPath = "C:\temp\ANF-throughput-metrics.csv"     # Output CSV file path
$timeGrainMinutes = 5                                   # Time grain in minutes (5-minute resolution)

# Validate configuration variables
Write-Host "Validating configuration..." -ForegroundColor Cyan

if ($tenantId -eq "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -or [string]::IsNullOrEmpty($tenantId)) {
    Write-Host "ERROR: Please update the tenantId variable with your actual Azure Tenant ID" -ForegroundColor Red
    exit 1
}

if ($resourceGroupName -eq "example-rg" -or [string]::IsNullOrEmpty($resourceGroupName)) {
    Write-Host "ERROR: Please update the resourceGroupName variable with your actual Resource Group name" -ForegroundColor Red
    exit 1
}

if ($anfAccountName -eq "example-anf-acct" -or [string]::IsNullOrEmpty($anfAccountName)) {
    Write-Host "ERROR: Please update the anfAccountName variable with your actual ANF Account name" -ForegroundColor Red
    exit 1
}

if ($anfPoolName -eq "example-anf-pool" -or [string]::IsNullOrEmpty($anfPoolName)) {
    Write-Host "ERROR: Please update the anfPoolName variable with your actual ANF Pool name" -ForegroundColor Red
    exit 1
}

Write-Host "Configuration validation passed" -ForegroundColor Green

# Connect to Azure
Write-Host "Connecting to Azure..." -ForegroundColor Cyan
try {
    $currentContext = Get-AzContext
    if (-not $currentContext -or $currentContext.Account -eq $null) {
        Write-Host "No valid Azure context found. Please authenticate..." -ForegroundColor Yellow
        Connect-AzAccount -TenantId $tenantId -ErrorAction Stop
        Write-Host "Successfully connected to Azure" -ForegroundColor Green
    } else {
        Write-Host "Using existing Azure connection for: $($currentContext.Account.Id)" -ForegroundColor Green
        
        # Check if the current context is for the correct tenant
        if ($currentContext.Tenant.Id -ne $tenantId) {
            Write-Host "Current context is for tenant $($currentContext.Tenant.Id), but script needs $tenantId" -ForegroundColor Yellow
            Write-Host "Switching to correct tenant..." -ForegroundColor Yellow
            Connect-AzAccount -TenantId $tenantId -ErrorAction Stop
        }
    }
    
    # Set subscription context if specified
    if ($subscriptionId -ne "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -and -not [string]::IsNullOrEmpty($subscriptionId)) {
        Write-Host "Setting subscription context to: $subscriptionId" -ForegroundColor Cyan
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
        Write-Host "Set subscription context to: $subscriptionId" -ForegroundColor Green
    }
    
    $finalContext = Get-AzContext
    Write-Host "Current Azure context: $($finalContext.Account.Id) - Subscription: $($finalContext.Subscription.Name)" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to connect to Azure: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "" -ForegroundColor White
    Write-Host "Please try one of the following:" -ForegroundColor Yellow
    Write-Host "1. Run 'Connect-AzAccount -TenantId $tenantId' manually first" -ForegroundColor White
    Write-Host "2. If you have MFA enabled, you may need to authenticate interactively" -ForegroundColor White
    Write-Host "3. Check that your tenant ID is correct: $tenantId" -ForegroundColor White
    exit 1
}

Write-Host "Starting throughput metrics collection..." -ForegroundColor Green
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor White
Write-Host "  ANF Account: $anfAccountName" -ForegroundColor White
Write-Host "  ANF Pool: $anfPoolName" -ForegroundColor White
Write-Host "  Volume: $(if ($volumeName) { $volumeName } else { 'All volumes in pool' })" -ForegroundColor White
Write-Host "  Look-back period: $lookBackDays days" -ForegroundColor White
Write-Host "  Resolution: $timeGrainMinutes minutes" -ForegroundColor White
Write-Host "  Output file: $outputPath" -ForegroundColor White

try {
    # Get the Azure NetApp Files account details
    Write-Host "Connecting to ANF Account: $anfAccountName..." -ForegroundColor Cyan
    $anfAccount = Get-AzNetAppFilesAccount -ResourceGroupName $resourceGroupName -Name $anfAccountName -ErrorAction Stop
    Write-Host "Successfully connected to ANF Account: $anfAccountName" -ForegroundColor Green

    # Get the Azure NetApp Files capacity pool details
    Write-Host "Connecting to ANF Pool: $anfPoolName..." -ForegroundColor Cyan
    $anfPool = Get-AzNetAppFilesPool -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -Name $anfPoolName -ErrorAction Stop
    Write-Host "Successfully connected to ANF Pool: $anfPoolName" -ForegroundColor Green

    # Get volumes to process
    Write-Host "Getting volumes..." -ForegroundColor Cyan
    if ($volumeName) {
        # Get specific volume
        Write-Host "Looking for specific volume: $volumeName" -ForegroundColor Cyan
        $anfVolumes = @(Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -Name $volumeName -ErrorAction Stop)
        Write-Host "Processing specific volume: $volumeName" -ForegroundColor Green
    } else {
        # Get all volumes in the pool
        Write-Host "Getting all volumes in pool..." -ForegroundColor Cyan
        $anfVolumes = Get-AzNetAppFilesVolume -ResourceGroupName $resourceGroupName -AccountName $anfAccountName -PoolName $anfPoolName -ErrorAction Stop
        Write-Host "Processing all volumes in pool: $($anfVolumes.Count) volumes found" -ForegroundColor Green
    }

    if (-not $anfVolumes -or $anfVolumes.Count -eq 0) {
        Write-Host "No volumes found matching the criteria. Exiting." -ForegroundColor Red
        exit
    }

    # Calculate time range
    $endTime = Get-Date
    $startTime = $endTime.AddDays(-$lookBackDays)
    $timeGrain = "00:0$($timeGrainMinutes):00"

    Write-Host "Collecting metrics from $($startTime.ToString('yyyy-MM-dd HH:mm:ss')) to $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan

    # Initialize array to store all metrics data
    $allMetricsData = @()    # Process each volume
    foreach ($anfVolume in $anfVolumes) {
        $volumeShortName = $anfVolume.Name.Split('/')[2]
        Write-Host "Collecting metrics for volume: $volumeShortName..." -ForegroundColor Yellow

        try {
            # Get throughput metrics for the volume
            $throughputMetrics = Get-AzMetric -ResourceId $anfVolume.Id -MetricName 'ReadThroughput,WriteThroughput,TotalThroughput,OtherThroughput' -StartTime $startTime -EndTime $endTime -TimeGrain $timeGrain -WarningAction SilentlyContinue -ErrorAction Stop

            foreach ($metric in $throughputMetrics) {
                $metricName = $metric.Name.Value
                
                foreach ($dataPoint in $metric.Data) {
                    if ($null -ne $dataPoint.Average) {
                        $metricsRecord = [PSCustomObject]@{
                            Timestamp = $dataPoint.TimeStamp
                            ResourceGroup = $resourceGroupName
                            ANFAccount = $anfAccountName
                            ANFPool = $anfPoolName
                            VolumeName = $volumeShortName
                            VolumeId = $anfVolume.Id
                            MetricName = $metricName
                            Value = [math]::Round($dataPoint.Average, 3)
                            Unit = 'BytesPerSecond'
                            ValueMiBps = [math]::Round($dataPoint.Average / 1024 / 1024, 3)
                            TimeGrainMinutes = $timeGrainMinutes
                        }
                        $allMetricsData += $metricsRecord
                    }
                }
            }

            $totalDataPoints = ($throughputMetrics | ForEach-Object { $_.Data.Count } | Measure-Object -Sum).Sum
            Write-Host "  Collected $totalDataPoints data points across all metrics" -ForegroundColor Green
        }
        catch {
            Write-Host "  Error collecting metrics for volume $volumeShortName`: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Export to CSV
    if ($allMetricsData.Count -gt 0) {
        # Create output directory if it doesn't exist
        $outputDir = Split-Path -Path $outputPath -Parent
        if (-not (Test-Path -Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        # Export data to CSV
        $allMetricsData | Sort-Object Timestamp, VolumeName, MetricName | Export-Csv -Path $outputPath -NoTypeInformation -Force

        Write-Host "`nMetrics collection completed successfully!" -ForegroundColor Green
        Write-Host "Total data points collected: $($allMetricsData.Count)" -ForegroundColor Cyan
        Write-Host "Data exported to: $outputPath" -ForegroundColor Cyan
        
        # Display summary statistics
        $uniqueVolumes = ($allMetricsData | Select-Object -Unique VolumeName).Count
        $dateRange = ($allMetricsData | Measure-Object -Property Timestamp -Minimum -Maximum)
        
        Write-Host "`nSummary:" -ForegroundColor Cyan
        Write-Host "  Volumes processed: $uniqueVolumes" -ForegroundColor White
        Write-Host "  Date range: $($dateRange.Minimum.ToString('yyyy-MM-dd HH:mm')) to $($dateRange.Maximum.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor White
        Write-Host "  Metrics included: ReadThroughput, WriteThroughput, TotalThroughput, OtherThroughput" -ForegroundColor White
        Write-Host "  Time resolution: $timeGrainMinutes minutes" -ForegroundColor White
    }
    else {
        Write-Host "No metrics data was collected. Please check your configuration and try again." -ForegroundColor Red
    }
}
catch {
    Write-Host "Error occurred during script execution: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}

Write-Host "`nScript execution completed." -ForegroundColor Green
