# ================================
# AVD Usage vs Quota Report Script - Enhanced Version
# ================================
#
# USAGE:
#   .\AzureCostsReports.ps1                              # Overall subscription usage report (May 2025)
#   .\AzureCostsReports.ps1 -UseClientTags               # Client tag-based analysis (May 2025)
#   .\AzureCostsReports.ps1 -StartDate "2025-06-01" -EndDate "2025-06-30"  # Custom date range
#   .\AzureCostsReports.ps1 -DefaultClientName "MyOrg"   # Custom name for overall report
#
# PARAMETERS:
#   -UseClientTags       : Enable client tag-based analysis (looks for "Client" tag on resources)
#   -DefaultClientName   : Name to use for overall subscription analysis (default: "All Resources")
#   -StartDate          : Start date for usage analysis (default: May 1, 2025)
#   -EndDate            : End date for usage analysis (default: May 31, 2025)
#   -ShowDetailedBreakdown : Show detailed breakdown by service category
#   -Help               : Show this help message
#

# Script parameters
param(
    [switch]$UseClientTags = $false,
    [string]$DefaultClientName = "All Resources",
    [switch]$Help = $false,
    [switch]$ShowDetailedBreakdown = $false,
    [datetime]$StartDate = (Get-Date "2025-05-01"),
    [datetime]$EndDate = (Get-Date "2025-05-31"),
    [string]$SubscriptionId = "77b12327-9e5d-4e1a-a3c5-6e4485a30793",
    [string]$ResourceGroups = ""
)

# Show help if requested
if ($Help) {
    Write-Host @"
=== Azure Usage vs Quota Report Script - Help ===

DESCRIPTION:
  This script generates Azure resource usage reports with optional quota comparison.
  It can work in two modes:
  
  1. Overall Subscription Analysis (default): Aggregates all resources in the subscription
  2. Client Tag-based Analysis: Groups resources by 'Client' tag for multi-tenant scenarios

USAGE:
  .\AzureCostsReports.ps1                                    # Overall subscription report (May 2025)
  .\AzureCostsReports.ps1 -UseClientTags                     # Client tag-based analysis (May 2025)
  .\AzureCostsReports.ps1 -StartDate "2025-06-01" -EndDate "2025-06-30"  # Custom date range
  .\AzureCostsReports.ps1 -DefaultClientName "MyCompany"     # Custom name for overall report
  .\AzureCostsReports.ps1 -Help                              # Show this help

PARAMETERS:
  -UseClientTags       Enable client tag-based analysis (looks for 'Client' tag on resources)
  -DefaultClientName   Name to use for overall subscription analysis (default: 'All Resources')
  -StartDate          Start date for usage analysis (default: May 1, 2025)
  -EndDate            End date for usage analysis (default: May 31, 2025)
  -SubscriptionId     Azure subscription ID to analyze
  -ResourceGroups     Comma-separated list of resource groups to filter by (optional, all if empty)
  -ShowDetailedBreakdown Show detailed breakdown by service category
  -Help               Show this help message

EXAMPLES:
  # Generate overall usage report for May 2025 (default)
  .\AzureCostsReports.ps1
  
  # Analyze June 2025 usage by client tags
  .\AzureCostsReports.ps1 -UseClientTags -StartDate "2025-06-01" -EndDate "2025-06-30"
  
  # Generate custom date range report
  .\AzureCostsReports.ps1 -StartDate "2025-04-15" -EndDate "2025-04-30"
  
  # Filter by specific resource groups
  .\AzureCostsReports.ps1 -ResourceGroups "rg-prod,rg-test,rg-dev"
  
  # Custom subscription and resource group filtering
  .\AzureCostsReports.ps1 -SubscriptionId "your-sub-id" -ResourceGroups "rg-prod"

REQUIREMENTS:
  - Azure PowerShell module (Az)
  - Connected to Azure (Connect-AzAccount)
  - Appropriate permissions for Cost Management data

"@ -ForegroundColor Cyan
    exit 0
}

# Predefined quotas per client (adjust as needed) - optional when UseClientTags is false
$quotas = @{
    "ClientA-Prod" = @{
        CoreHours = 10000
        DataOutGB = 100
        DataInGB  = 500
        DiskStorageGB = 1000
        BlobStorageGB = 500
    }
    "ClientB-Test" = @{
        CoreHours = 2000
        DataOutGB = 50
        DataInGB  = 200
        DiskStorageGB = 500
        BlobStorageGB = 200
    }
    $DefaultClientName = @{
        CoreHours = 50000
        DataOutGB = 1000
        DataInGB  = 2000
        DiskStorageGB = 5000
        BlobStorageGB = 2000
    }
}

# VM SKU -> vCPU mapping (will be populated dynamically from Azure APIs)
$vmSkuCores = @{}
$vmInstanceData = @{}

# Storage data tracking
$storageData = @{}
$diskData = @{}

# Step 1. Connect to Azure
#Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
#Connect-AzAccount

# Check if connected to Azure
try {
    $context = Get-AzContext
    if ($null -eq $context) {
        Write-Host "Not connected to Azure. Please run Connect-AzAccount first." -ForegroundColor Red
        exit 1
    }
    Write-Host "✓ Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "✓ Subscription: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Error "Azure PowerShell module not available. Please install with: Install-Module -Name Az"
    exit 1
}

Write-Host "`n=== Starting Azure Usage Report Script ===" -ForegroundColor Cyan
Write-Host "Mode: $(if ($UseClientTags) { 'Client Tag-based Analysis' } else { 'Overall Subscription Analysis' })" -ForegroundColor Yellow
Write-Host "Date Range: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow

# Validate date range
if ($StartDate -gt $EndDate) {
    Write-Error "Start date cannot be after end date"
    exit 1
}

if ($EndDate -gt (Get-Date)) {
    Write-Warning "End date is in the future. Results may be incomplete."
}

# Calculate date range span
$daySpan = ($EndDate - $StartDate).Days + 1
Write-Host "Analysis Period: $daySpan days" -ForegroundColor Gray

# Parse resource groups filter if provided
$resourceGroupsFilter = @()
if (-not [string]::IsNullOrEmpty($ResourceGroups)) {
    $resourceGroupsFilter = $ResourceGroups.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrEmpty($_) }
    Write-Host "Resource Groups Filter: $($resourceGroupsFilter -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "Resource Groups Filter: All resource groups" -ForegroundColor Yellow
}

# Function to discover VMs and VMSS and populate SKU mapping
function Get-VMSpecifications {
    Write-Host "`n=== Discovering Virtual Machines and Scale Sets ===" -ForegroundColor Yellow
    
    try {
        # Get all standalone VMs in the subscription
        $allVms = Get-AzVM -Status
        
        # Apply resource group filter if specified
        if ($resourceGroupsFilter.Count -gt 0) {
            $vms = $allVms | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
            Write-Host "✓ Found $($allVms.Count) total VMs, $($vms.Count) in filtered resource groups" -ForegroundColor Green
        } else {
            $vms = $allVms
            Write-Host "✓ Found $($vms.Count) standalone virtual machines" -ForegroundColor Green
        }
        
        # Get all Virtual Machine Scale Sets
        $allVmss = Get-AzVmss
        
        # Apply resource group filter if specified
        if ($resourceGroupsFilter.Count -gt 0) {
            $vmss = $allVmss | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
            Write-Host "✓ Found $($allVmss.Count) total VMSS, $($vmss.Count) in filtered resource groups" -ForegroundColor Green
        } else {
            $vmss = $allVmss
            Write-Host "✓ Found $($vmss.Count) Virtual Machine Scale Sets" -ForegroundColor Green
        }
        
        # Get VMSS instances
        $vmssInstances = @()
        foreach ($scaleset in $vmss) {
            try {
                $instances = Get-AzVmssVM -ResourceGroupName $scaleset.ResourceGroupName -VMScaleSetName $scaleset.Name
                $vmssInstances += $instances
                Write-Host "  - $($scaleset.Name): $($instances.Count) instances (SKU: $($scaleset.Sku.Name))" -ForegroundColor Gray
            } catch {
                Write-Host "  ⚠ Failed to get instances for $($scaleset.Name): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        Write-Host "✓ Found $($vmssInstances.Count) total VMSS instances" -ForegroundColor Green
        
        $totalCompute = $vms.Count + $vmssInstances.Count
        if ($totalCompute -eq 0) {
            Write-Host "No compute resources found in subscription. Using fallback SKU mapping..." -ForegroundColor Yellow
            return
        }
        
        # Get unique VM sizes from both VMs and VMSS
        $uniqueSizes = @()
        $uniqueSizes += $vms | Select-Object -ExpandProperty HardwareProfile | Select-Object -ExpandProperty VmSize
        $uniqueSizes += $vmss | Select-Object -ExpandProperty Sku | Select-Object -ExpandProperty Name
        $uniqueSizes = $uniqueSizes | Sort-Object -Unique
        
        Write-Host "✓ Found $($uniqueSizes.Count) unique VM/VMSS sizes: $($uniqueSizes -join ', ')" -ForegroundColor Green
        
        # Get VM size information for each unique size
        Write-Host "Retrieving VM specifications from Azure APIs..." -ForegroundColor Yellow
        foreach ($size in $uniqueSizes) {
            try {
                # Get VM size info - try different locations as some sizes may not be available in all regions
                $locations = @('eastus', 'westus2', 'westeurope', 'northeurope', 'southeastasia')
                $vmSizeInfo = $null
                
                foreach ($location in $locations) {
                    try {
                        $vmSizeInfo = Get-AzVMSize -Location $location | Where-Object { $_.Name -eq $size }
                        if ($vmSizeInfo) {
                            break
                        }
                    } catch {
                        # Continue to next location
                        continue
                    }
                }
                
                if ($vmSizeInfo) {
                    $vmSkuCores[$size] = $vmSizeInfo.NumberOfCores
                    Write-Host "  ✓ $size`: $($vmSizeInfo.NumberOfCores) cores" -ForegroundColor Gray
                } else {
                    # Fallback: try to extract from name or use default
                    $coreCount = Get-CoreCountFromVMName -vmSize $size
                    $vmSkuCores[$size] = $coreCount
                    Write-Host "  ⚠ $size`: $coreCount cores (estimated)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  ⚠ Failed to get specs for $size`: $($_.Exception.Message)" -ForegroundColor Yellow
                $vmSkuCores[$size] = 1  # Default fallback
            }
        }
        
        # Store VM instance data for better tracking
        foreach ($vm in $vms) {
            $vmInstanceData[$vm.Name] = @{
                ResourceGroup = $vm.ResourceGroupName
                Size = $vm.HardwareProfile.VmSize
                Status = $vm.PowerState
                Location = $vm.Location
                Cores = $vmSkuCores[$vm.HardwareProfile.VmSize]
                Tags = $vm.Tags
                Type = "VM"
            }
        }
        
        # Store VMSS instance data
        foreach ($scaleset in $vmss) {
            $coreCount = if ($vmSkuCores.ContainsKey($scaleset.Sku.Name)) { $vmSkuCores[$scaleset.Sku.Name] } else { 2 }
            $vmInstanceData[$scaleset.Name] = @{
                ResourceGroup = $scaleset.ResourceGroupName
                Size = $scaleset.Sku.Name
                Status = "Scale Set"
                Location = $scaleset.Location
                Cores = $coreCount
                Tags = $scaleset.Tags
                Type = "VMSS"
                Capacity = $scaleset.Sku.Capacity
                TotalCores = $coreCount * $scaleset.Sku.Capacity
            }
        }
        
        Write-Host "✓ VM and VMSS specifications populated successfully" -ForegroundColor Green
        
    } catch {
        Write-Host "⚠ Error discovering VMs: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Using fallback SKU mapping..." -ForegroundColor Yellow
        
        # Fallback to basic mapping
        $vmSkuCores = @{
            "Standard_D2s_v3" = 2; "Standard_D4s_v3" = 4; "Standard_D8s_v3" = 8
            "Standard_E2s_v3" = 2; "Standard_E4s_v3" = 4; "Standard_E8s_v3" = 8; "Standard_E16s_v3" = 16
            "Standard_B1s" = 1; "Standard_B2s" = 2; "Standard_B4ms" = 4
        }
    }
}

# Helper function to estimate core count from VM size name
function Get-CoreCountFromVMName {
    param([string]$vmSize)
    
    # Try to extract number from common VM naming patterns
    if ($vmSize -match "(\d+)") {
        $number = [int]$matches[1]
        # For sizes like D2, E4, etc., the number often represents cores
        if ($vmSize -match "^Standard_[DE]\d+") {
            return $number
        }
        # For sizes like B1s, B2s, etc.
        if ($vmSize -match "^Standard_B\d+") {
            return $number
        }
    }
    
    # Default fallback
    return 2
}

# Function to discover Azure Storage resources
function Get-StorageSpecifications {
    Write-Host "`n=== Discovering Azure Storage Resources ===" -ForegroundColor Yellow
    
    try {
        # Get all storage accounts
        $allStorageAccounts = Get-AzStorageAccount
        
        # Apply resource group filter if specified
        if ($resourceGroupsFilter.Count -gt 0) {
            $storageAccounts = $allStorageAccounts | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
            Write-Host "✓ Found $($allStorageAccounts.Count) total storage accounts, $($storageAccounts.Count) in filtered resource groups" -ForegroundColor Green
        } else {
            $storageAccounts = $allStorageAccounts
            Write-Host "✓ Found $($storageAccounts.Count) storage accounts" -ForegroundColor Green
        }
        
        # Get managed disks
        $allDisks = Get-AzDisk
        
        # Apply resource group filter if specified
        if ($resourceGroupsFilter.Count -gt 0) {
            $disks = $allDisks | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
            Write-Host "✓ Found $($allDisks.Count) total managed disks, $($disks.Count) in filtered resource groups" -ForegroundColor Green
        } else {
            $disks = $allDisks
            Write-Host "✓ Found $($disks.Count) managed disks" -ForegroundColor Green
        }
        
        # Process storage accounts
        foreach ($storageAccount in $storageAccounts) {
            try {
                $storageContext = $storageAccount.Context
                $accountName = $storageAccount.StorageAccountName
                
                $storageInfo = @{
                    ResourceGroup = $storageAccount.ResourceGroupName
                    Location = $storageAccount.Location
                    Kind = $storageAccount.Kind
                    SkuName = $storageAccount.Sku.Name
                    AccessTier = $storageAccount.AccessTier
                    Tags = $storageAccount.Tags
                    BlobContainerCount = 0
                    BlobSizeGB = 0
                    FileShareCount = 0
                    TableCount = 0
                    QueueCount = 0
                }
                
                # Get blob containers and usage
                try {
                    $containers = Get-AzStorageContainer -Context $storageContext
                    $storageInfo.BlobContainerCount = $containers.Count
                    
                    # Estimate blob storage usage (this is simplified - in real scenarios you might want more detailed metrics)
                    $totalBlobSize = 0
                    foreach ($container in $containers) {
                        try {
                            $blobs = Get-AzStorageBlob -Container $container.Name -Context $storageContext
                            $containerSize = ($blobs | Measure-Object -Property Length -Sum).Sum
                            $totalBlobSize += $containerSize
                        } catch {
                            # Some containers might not be accessible, continue
                            Write-Host "  ⚠ Could not access container: $($container.Name)" -ForegroundColor Yellow
                        }
                    }
                    $storageInfo.BlobSizeGB = [math]::Round($totalBlobSize / 1GB, 2)
                } catch {
                    Write-Host "  ⚠ Could not access blob storage for: $accountName" -ForegroundColor Yellow
                }
                
                # Get file shares
                try {
                    $fileShares = Get-AzStorageShare -Context $storageContext
                    $storageInfo.FileShareCount = $fileShares.Count
                } catch {
                    Write-Host "  ⚠ Could not access file shares for: $accountName" -ForegroundColor Yellow
                }
                
                # Get tables
                try {
                    $tables = Get-AzStorageTable -Context $storageContext
                    $storageInfo.TableCount = $tables.Count
                } catch {
                    Write-Host "  ⚠ Could not access tables for: $accountName" -ForegroundColor Yellow
                }
                
                # Get queues
                try {
                    $queues = Get-AzStorageQueue -Context $storageContext
                    $storageInfo.QueueCount = $queues.Count
                } catch {
                    Write-Host "  ⚠ Could not access queues for: $accountName" -ForegroundColor Yellow
                }
                
                $storageData[$accountName] = $storageInfo
                Write-Host "  ✓ $accountName`: $($storageInfo.BlobContainerCount) containers, $($storageInfo.BlobSizeGB) GB blobs, $($storageInfo.FileShareCount) file shares" -ForegroundColor Gray
                
            } catch {
                Write-Host "  ⚠ Failed to process storage account $($storageAccount.StorageAccountName): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Process managed disks
        foreach ($disk in $disks) {
            $diskInfo = @{
                ResourceGroup = $disk.ResourceGroupName
                Location = $disk.Location
                SizeGB = $disk.DiskSizeGB
                SkuName = $disk.Sku.Name
                DiskState = $disk.DiskState
                OsType = $disk.OsType
                Tags = $disk.Tags
                AttachedToVM = $disk.OwnerId -ne $null
            }
            
            $diskData[$disk.Name] = $diskInfo
        }
        
        Write-Host "✓ Storage specifications populated successfully" -ForegroundColor Green
        Write-Host "  Storage Accounts: $($storageData.Count)" -ForegroundColor Gray
        Write-Host "  Managed Disks: $($diskData.Count)" -ForegroundColor Gray
        
        # Calculate total disk storage
        $totalDiskStorageGB = ($diskData.Values | Measure-Object -Property SizeGB -Sum).Sum
        $totalBlobStorageGB = ($storageData.Values | Measure-Object -Property BlobSizeGB -Sum).Sum
        
        Write-Host "  Total Disk Storage: $totalDiskStorageGB GB" -ForegroundColor Gray
        Write-Host "  Total Blob Storage: $totalBlobStorageGB GB" -ForegroundColor Gray
        
    } catch {
        Write-Host "⚠ Error discovering storage: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Storage discovery will be skipped..." -ForegroundColor Yellow
    }
}

# Discover VMs and populate specifications
Get-VMSpecifications

# Discover Storage resources and populate specifications
Get-StorageSpecifications

# Step 2. Define subscription scope
$scope = "/subscriptions/$SubscriptionId"

# Step 3. Define cost query body (with custom date range)
$aggregation = @{ totalUsage = @{ name = "UsageQuantity"; function = "Sum" } }
$grouping = @(
    @{ name = "ResourceGroup"; type = "Dimension" },
    @{ name = "ResourceTags"; type = "Tag" },
    @{ name = "MeterCategory"; type = "Dimension" },
    @{ name = "MeterSubCategory"; type = "Dimension" },
    @{ name = "ResourceType"; type = "Dimension" },
    @{ name = "ServiceName"; type = "Dimension" }
)
$timePeriod = @{
    from = $StartDate.ToString('yyyy-MM-ddT00:00:00Z')
    to = $EndDate.ToString('yyyy-MM-ddT23:59:59Z')
}

# Add resource group filter if specified
$dataset = @{ granularity = "None"; aggregation = $aggregation; grouping = $grouping }
if ($resourceGroupsFilter.Count -gt 0) {
    $rgFilter = @{
        dimension = @{
            name = "ResourceGroup"
            operator = "In"
            values = $resourceGroupsFilter
        }
    }
    $dataset.filter = $rgFilter
    Write-Host "✓ Added resource group filter to cost query: $($resourceGroupsFilter -join ', ')" -ForegroundColor Green
}

$body = @{ type = "Usage"; timeframe = "Custom"; timePeriod = $timePeriod; dataset = $dataset } | ConvertTo-Json -Depth 10

# Step 4. Get access token (using alternative method for Cost Management)
try {
    # Method 1: Try standard approach
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    $token = $tokenResponse.Token
    Write-Host "✓ Access token acquired successfully" -ForegroundColor Green
    
    # Method 2: If the above fails, try getting token for specific resource
    if ([string]::IsNullOrEmpty($token)) {
        $tokenResponse = Get-AzAccessToken -Resource "https://management.azure.com/"
        $token = $tokenResponse.Token
        Write-Host "✓ Alternative token method worked" -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to get access token: $($_.Exception.Message)"
    Write-Host "Trying to refresh Azure session..." -ForegroundColor Yellow
    try {
        # Force refresh of Azure session
        Disconnect-AzAccount -Confirm:$false
        Connect-AzAccount
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
        $token = $tokenResponse.Token
        Write-Host "✓ Token acquired after session refresh" -ForegroundColor Green
    } catch {
        Write-Error "All token acquisition methods failed. Please check your Azure permissions."
        exit 1
    }
}

# Step 5. Call Cost Management API (with fallback to PowerShell cmdlets)
$uri = "https://management.azure.com$($scope)/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
$useRestAPI = $true

try {
    Write-Host "Calling Cost Management API..." -ForegroundColor Yellow
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers @{Authorization = "Bearer $token"} -Body $body -ContentType "application/json"
    Write-Host "✓ API call successful, received $($response.properties.rows.Count) rows" -ForegroundColor Green
} catch {
    Write-Host "REST API failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host "Error details: $($_.ErrorDetails.Message)" -ForegroundColor Red }
    
    Write-Host "Trying PowerShell cmdlets as fallback..." -ForegroundColor Yellow
    $useRestAPI = $false
    
    try {
        # Fallback to PowerShell cmdlets with custom date range
        Write-Host "Using date range: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
        
        # Try multiple approaches to get usage data
        $usageDetails = $null
        $dataSource = ""
        
        # Method 1: Try Get-AzUsageDetail (newer cmdlet)
        try {
            Write-Host "Attempting Get-AzUsageDetail..." -ForegroundColor Gray
            $usageDetails = Get-AzUsageDetail -StartDate $StartDate -EndDate $EndDate -MaxCount 1000
            
            # Apply resource group filter if specified
            if ($resourceGroupsFilter.Count -gt 0) {
                $allUsageDetails = $usageDetails
                $usageDetails = $usageDetails | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
                Write-Host "✓ Filtered usage details: $($allUsageDetails.Count) -> $($usageDetails.Count) records" -ForegroundColor Green
            }
            
            $dataSource = "Get-AzUsageDetail"
            Write-Host "✓ Get-AzUsageDetail successful" -ForegroundColor Green
        } catch {
            Write-Host "Get-AzUsageDetail failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        
        # Method 2: Try Get-AzBillingAccount and usage details
        if (-not $usageDetails) {
            try {
                Write-Host "Attempting billing-based usage retrieval..." -ForegroundColor Gray
                # This is a more complex approach that might work better
                $usageDetails = Get-AzConsumptionUsageDetail -StartDate $StartDate -EndDate $EndDate
                
                # Apply resource group filter if specified
                if ($resourceGroupsFilter.Count -gt 0) {
                    $allUsageDetails = $usageDetails
                    $usageDetails = $usageDetails | Where-Object { $_.ResourceGroupName -in $resourceGroupsFilter }
                    Write-Host "✓ Filtered consumption details: $($allUsageDetails.Count) -> $($usageDetails.Count) records" -ForegroundColor Green
                }
                
                $dataSource = "Get-AzConsumptionUsageDetail"
                Write-Host "✓ Billing-based retrieval successful" -ForegroundColor Green
            } catch {
                Write-Host "Billing-based retrieval failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Method 3: If usage data is incomplete, estimate based on discovered VMSS
        if (-not $usageDetails -or $usageDetails.Count -eq 0 -or -not $usageDetails[0].MeterCategory) {
            Write-Host "⚠ Usage data incomplete or unavailable. Generating estimated usage based on discovered compute resources..." -ForegroundColor Yellow
            
            $estimatedUsage = @()
            foreach ($resource in $vmInstanceData.GetEnumerator()) {
                $resourceInfo = $resource.Value
                if ($resourceInfo.Type -eq "VMSS") {
                    # Estimate usage for VMSS - assume 720 hours for a full month
                    $hoursInPeriod = [math]::Min(720, ($EndDate - $StartDate).TotalHours)
                    $totalCoreHours = $resourceInfo.TotalCores * $hoursInPeriod
                    
                    $estimatedUsage += [PSCustomObject]@{
                        ResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($resourceInfo.ResourceGroup)/providers/Microsoft.Compute/virtualMachineScaleSets/$($resource.Key)"
                        MeterCategory = "Virtual Machines"
                        MeterSubCategory = $resourceInfo.Size
                        MeterName = "Compute Hours"
                        ResourceType = "Microsoft.Compute/virtualMachineScaleSets"
                        ResourceGroupName = $resourceInfo.ResourceGroup
                        Quantity = $totalCoreHours
                        UnitOfMeasure = "Hours"
                        Tags = $resourceInfo.Tags
                        EstimatedData = $true
                    }
                } elseif ($resourceInfo.Type -eq "VM") {
                    # Estimate usage for standalone VMs
                    $hoursInPeriod = [math]::Min(720, ($EndDate - $StartDate).TotalHours)
                    $coreHours = $resourceInfo.Cores * $hoursInPeriod
                    
                    $estimatedUsage += [PSCustomObject]@{
                        ResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$($resourceInfo.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($resource.Key)"
                        MeterCategory = "Virtual Machines"
                        MeterSubCategory = $resourceInfo.Size
                        MeterName = "Compute Hours"
                        ResourceType = "Microsoft.Compute/virtualMachines"
                        ResourceGroupName = $resourceInfo.ResourceGroup
                        Quantity = $coreHours
                        UnitOfMeasure = "Hours"
                        Tags = $resourceInfo.Tags
                        EstimatedData = $true
                    }
                }
            }
            
            $usageDetails = $estimatedUsage
            $dataSource = "Estimated from discovered resources"
            Write-Host "✓ Generated $($estimatedUsage.Count) estimated usage records" -ForegroundColor Green
        }
        
        Write-Host "✓ PowerShell cmdlets successful, received $($usageDetails.Count) records from: $dataSource" -ForegroundColor Green
        
        # Show data source information
        if ($dataSource -eq "Estimated from discovered resources") {
            Write-Host "ℹ Using estimated usage based on discovered VMSS and VM resources" -ForegroundColor Cyan
        }
        
        # Convert to expected format
        $response = @{
            properties = @{
                rows = $usageDetails | ForEach-Object {
                    if ($UseClientTags) {
                        $clientTag = if ($_.Tags -and $_.Tags.ContainsKey("Client")) { $_.Tags["Client"] } else { "Unknown" }
                    } else {
                        $clientTag = $DefaultClientName
                    }
                    [PSCustomObject]@{
                        ResourceGroup = $_.ResourceGroupName
                        Tag = $clientTag
                        MeterCategory = $_.MeterCategory
                        MeterSubCategory = $_.MeterSubCategory
                        ResourceType = $_.ResourceType
                        ServiceName = $_.MeterName
                        UsageQuantity = [double]$_.Quantity
                    }
                }
            }
        }
    } catch {
        Write-Error "Both REST API and PowerShell cmdlets failed: $($_.Exception.Message)"
        Write-Host "This might be due to insufficient permissions or no billing data available." -ForegroundColor Yellow
        exit 1
    }
}

# Step 6. Parse rows (single line approach with proper handling for both API types)
if ($useRestAPI) {
    $data = $response.properties.rows | ForEach-Object { [PSCustomObject]@{ ResourceGroup = $_[0]; Tag = $_[1]; MeterCategory = $_[2]; MeterSubCategory = $_[3]; ResourceType = $_[4]; ServiceName = $_[5]; UsageQuantity = [double]$_[6] } }
} else {
    $data = $response.properties.rows
}

# Step 7. Aggregate usage per client (enhanced with dynamic VM SKU data and storage)
$clientUsage = @{}
foreach ($row in $data) {
    $clientTag = $row.Tag
    if ([string]::IsNullOrEmpty($clientTag)) { 
        $clientTag = if ($UseClientTags) { "Unknown" } else { $DefaultClientName }
    }
    if (-not $clientUsage.ContainsKey($clientTag)) { 
        $clientUsage[$clientTag] = @{ 
            CoreHours = 0; 
            DataOutGB = 0; 
            DataInGB = 0; 
            DiskStorageGB = 0; 
            BlobStorageGB = 0 
        } 
    }
    
    switch ($row.MeterCategory) {
        "Virtual Machines" { 
            $sku = $row.MeterSubCategory
            # Use dynamic VM SKU data first, then fallback to basic logic
            $cores = if ($vmSkuCores.ContainsKey($sku)) { 
                $vmSkuCores[$sku] 
            } else { 
                # Try to match against discovered VM instances
                $matchingVm = $vmInstanceData.Values | Where-Object { $_.Size -eq $sku } | Select-Object -First 1
                if ($matchingVm) {
                    $matchingVm.Cores
                } else {
                    # Fallback: estimate from name or use default
                    $estimatedCores = Get-CoreCountFromVMName -vmSize $sku
                    Write-Host "  ⚠ Using estimated cores for unknown SKU '$sku': $estimatedCores" -ForegroundColor Yellow
                    $estimatedCores
                }
            }
            $clientUsage[$clientTag].CoreHours += ($row.UsageQuantity * $cores)
        }
        "Storage" { 
            # Handle different storage types
            if ($row.MeterSubCategory -match "Disk|SSD|HDD") {
                $clientUsage[$clientTag].DiskStorageGB += $row.UsageQuantity
            } elseif ($row.MeterSubCategory -match "Blob|Object") {
                $clientUsage[$clientTag].BlobStorageGB += $row.UsageQuantity
            }
        }
        "Networking" { 
            if ($row.MeterSubCategory -match "Data Out") { 
                $clientUsage[$clientTag].DataOutGB += $row.UsageQuantity 
            } elseif ($row.MeterSubCategory -match "Data In") { 
                $clientUsage[$clientTag].DataInGB += $row.UsageQuantity 
            } 
        }
    }
}

# Add discovered storage usage to aggregated data
Write-Host "`n=== Adding Discovered Storage Usage ===" -ForegroundColor Yellow

# Add storage account usage by client tag or default
foreach ($storageAccount in $storageData.GetEnumerator()) {
    $storageInfo = $storageAccount.Value
    $clientTag = if ($UseClientTags -and $storageInfo.Tags -and $storageInfo.Tags.ContainsKey("Client")) { 
        $storageInfo.Tags["Client"] 
    } else { 
        $DefaultClientName 
    }
    
    if (-not $clientUsage.ContainsKey($clientTag)) { 
        $clientUsage[$clientTag] = @{ 
            CoreHours = 0; 
            DataOutGB = 0; 
            DataInGB = 0; 
            DiskStorageGB = 0; 
            BlobStorageGB = 0 
        } 
    }
    
    $clientUsage[$clientTag].BlobStorageGB += $storageInfo.BlobSizeGB
    Write-Host "  ✓ Added blob storage for $($storageAccount.Key): $($storageInfo.BlobSizeGB) GB -> $clientTag" -ForegroundColor Gray
}

# Add managed disk usage by client tag or default
foreach ($disk in $diskData.GetEnumerator()) {
    $diskInfo = $disk.Value
    $clientTag = if ($UseClientTags -and $diskInfo.Tags -and $diskInfo.Tags.ContainsKey("Client")) { 
        $diskInfo.Tags["Client"] 
    } else { 
        $DefaultClientName 
    }
    
    if (-not $clientUsage.ContainsKey($clientTag)) { 
        $clientUsage[$clientTag] = @{ 
            CoreHours = 0; 
            DataOutGB = 0; 
            DataInGB = 0; 
            DiskStorageGB = 0; 
            BlobStorageGB = 0 
        } 
    }
    
    $clientUsage[$clientTag].DiskStorageGB += $diskInfo.SizeGB
    Write-Host "  ✓ Added disk storage for $($disk.Key): $($diskInfo.SizeGB) GB -> $clientTag" -ForegroundColor Gray
}

# Step 8. Compare with quotas (enhanced with storage metrics)
$reports = foreach ($client in $clientUsage.Keys) {
    $usage = $clientUsage[$client]; $quota = $quotas[$client]
    
    # If not using client tags and no quota defined, create a usage-only report
    if (-not $UseClientTags -and $null -eq $quota) {
        [PSCustomObject]@{ 
            Client = $client; 
            CoreHours = [math]::Round($usage.CoreHours,2); 
            DataOutGB = [math]::Round($usage.DataOutGB,2); 
            DataInGB = [math]::Round($usage.DataInGB,2);
            DiskStorageGB = [math]::Round($usage.DiskStorageGB,2);
            BlobStorageGB = [math]::Round($usage.BlobStorageGB,2);
            Mode = "Usage Only (No Quota Defined)"
        }
    } elseif ($null -ne $quota) {
        [PSCustomObject]@{ 
            Client = $client; 
            CoreHours = "$([math]::Round($usage.CoreHours,2)) / $($quota.CoreHours)"; 
            CoreRemain = [math]::Round($quota.CoreHours - $usage.CoreHours,2); 
            DataOutGB = "$([math]::Round($usage.DataOutGB,2)) / $($quota.DataOutGB)"; 
            DataOutRemain = [math]::Round($quota.DataOutGB - $usage.DataOutGB,2); 
            DataInGB = "$([math]::Round($usage.DataInGB,2)) / $($quota.DataInGB)"; 
            DataInRemain = [math]::Round($quota.DataInGB - $usage.DataInGB,2);
            DiskStorageGB = "$([math]::Round($usage.DiskStorageGB,2)) / $($quota.DiskStorageGB)";
            DiskRemain = [math]::Round($quota.DiskStorageGB - $usage.DiskStorageGB,2);
            BlobStorageGB = "$([math]::Round($usage.BlobStorageGB,2)) / $($quota.BlobStorageGB)";
            BlobRemain = [math]::Round($quota.BlobStorageGB - $usage.BlobStorageGB,2);
            Mode = "Usage vs Quota"
        }
    } elseif ($UseClientTags) {
        [PSCustomObject]@{ 
            Client = $client; 
            CoreHours = [math]::Round($usage.CoreHours,2); 
            DataOutGB = [math]::Round($usage.DataOutGB,2); 
            DataInGB = [math]::Round($usage.DataInGB,2);
            DiskStorageGB = [math]::Round($usage.DiskStorageGB,2);
            BlobStorageGB = [math]::Round($usage.BlobStorageGB,2);
            Mode = "Usage Only (No Quota for Client)"
        }
    }
}

# Step 9. Show final report
if ($reports) {
    if ($UseClientTags) {
        Write-Host "`n=== AZURE USAGE vs QUOTA REPORT (Client Tag Mode) ===" -ForegroundColor Cyan
    } else {
        Write-Host "`n=== AZURE OVERALL SUBSCRIPTION USAGE REPORT ===" -ForegroundColor Cyan
    }
    $reports | Format-Table -AutoSize
    
    # Show summary statistics
    if ($clientUsage.Keys.Count -gt 0) {
        Write-Host "`n=== SUMMARY ===" -ForegroundColor Green
        $totalCoreHours = ($clientUsage.Values | Measure-Object -Property CoreHours -Sum).Sum
        $totalDataOut = ($clientUsage.Values | Measure-Object -Property DataOutGB -Sum).Sum
        $totalDataIn = ($clientUsage.Values | Measure-Object -Property DataInGB -Sum).Sum
        $totalDiskStorage = ($clientUsage.Values | Measure-Object -Property DiskStorageGB -Sum).Sum
        $totalBlobStorage = ($clientUsage.Values | Measure-Object -Property BlobStorageGB -Sum).Sum
        
        Write-Host "Total Core Hours: $([math]::Round($totalCoreHours,2))" -ForegroundColor White
        Write-Host "Total Data Out (GB): $([math]::Round($totalDataOut,2))" -ForegroundColor White
        Write-Host "Total Data In (GB): $([math]::Round($totalDataIn,2))" -ForegroundColor White
        Write-Host "Total Disk Storage (GB): $([math]::Round($totalDiskStorage,2))" -ForegroundColor White
        Write-Host "Total Blob Storage (GB): $([math]::Round($totalBlobStorage,2))" -ForegroundColor White
        Write-Host "Analysis Period: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd')) ($daySpan days)" -ForegroundColor Yellow
        
        # Show detailed breakdown if requested
        if ($ShowDetailedBreakdown) {
            Write-Host "`n=== DETAILED BREAKDOWN BY SERVICE ===" -ForegroundColor Magenta
            $serviceBreakdown = $data | Group-Object MeterCategory | ForEach-Object {
                $category = $_.Name
                $records = $_.Group
                $totalUsage = ($records | Measure-Object -Property UsageQuantity -Sum).Sum
                [PSCustomObject]@{
                    ServiceCategory = $category
                    TotalUsage = [math]::Round($totalUsage, 2)
                    ResourceCount = $records.Count
                    TopResources = ($records | Group-Object ServiceName | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ", "
                }
            } | Sort-Object TotalUsage -Descending
            
            $serviceBreakdown | Format-Table -AutoSize
        }
        
        # Show VM discovery information
        if ($vmInstanceData.Count -gt 0) {
            Write-Host "`n=== COMPUTE RESOURCES DISCOVERY SUMMARY ===" -ForegroundColor Cyan
            $vmCount = ($vmInstanceData.Values | Where-Object { $_.Type -eq "VM" }).Count
            $vmssCount = ($vmInstanceData.Values | Where-Object { $_.Type -eq "VMSS" }).Count
            $totalCores = ($vmInstanceData.Values | ForEach-Object { if ($_.Type -eq "VMSS") { $_.TotalCores } else { $_.Cores } } | Measure-Object -Sum).Sum
            
            Write-Host "Standalone VMs: $vmCount" -ForegroundColor White
            Write-Host "Virtual Machine Scale Sets: $vmssCount" -ForegroundColor White
            Write-Host "Total Compute Resources: $($vmInstanceData.Count)" -ForegroundColor White
            Write-Host "SKU Types: $($vmSkuCores.Keys.Count)" -ForegroundColor White
            Write-Host "Total Cores Available: $totalCores" -ForegroundColor White
            
            if ($vmInstanceData.Count -le 15) {
                # Show all resources if 15 or fewer
                $resourceSummary = $vmInstanceData.GetEnumerator() | ForEach-Object {
                    $resource = $_.Value
                    [PSCustomObject]@{
                        Name = $_.Key
                        Type = $resource.Type
                        Size = $resource.Size
                        Cores = if ($resource.Type -eq "VMSS") { "$($resource.Cores) x $($resource.Capacity) = $($resource.TotalCores)" } else { $resource.Cores }
                        Status = $resource.Status
                        ResourceGroup = $resource.ResourceGroup
                        ClientTag = if ($resource.Tags -and $resource.Tags.ContainsKey("Client")) { $resource.Tags["Client"] } else { "None" }
                    }
                } | Sort-Object Type, Name
                $resourceSummary | Format-Table -AutoSize
            } else {
                # Show summary by SKU type
                $skuSummary = $vmSkuCores.GetEnumerator() | ForEach-Object {
                    $sku = $_.Key
                    $cores = $_.Value
                    $vmCount = ($vmInstanceData.Values | Where-Object { $_.Size -eq $sku -and $_.Type -eq "VM" }).Count
                    $vmssData = $vmInstanceData.Values | Where-Object { $_.Size -eq $sku -and $_.Type -eq "VMSS" }
                    $vmssCount = $vmssData.Count
                    $vmssTotalCores = ($vmssData | ForEach-Object { $_.TotalCores } | Measure-Object -Sum).Sum
                    $totalCores = ($vmCount * $cores) + $vmssTotalCores
                    
                    [PSCustomObject]@{
                        SKU = $sku
                        CoresPerInstance = $cores
                        VMs = $vmCount
                        VMSS = $vmssCount
                        TotalCores = $totalCores
                    }
                } | Sort-Object TotalCores -Descending
                $skuSummary | Format-Table -AutoSize
            }
        }
        
        # Show storage resources summary
        if ($storageData.Count -gt 0 -or $diskData.Count -gt 0) {
            Write-Host "`n=== STORAGE RESOURCES DISCOVERY SUMMARY ===" -ForegroundColor Cyan
            $storageAccountCount = $storageData.Count
            $diskCount = $diskData.Count
            $totalBlobContainers = ($storageData.Values | Measure-Object -Property BlobContainerCount -Sum).Sum
            $totalFileShares = ($storageData.Values | Measure-Object -Property FileShareCount -Sum).Sum
            $totalBlobStorage = ($storageData.Values | Measure-Object -Property BlobSizeGB -Sum).Sum
            $totalDiskStorage = ($diskData.Values | Measure-Object -Property SizeGB -Sum).Sum
            
            Write-Host "Storage Accounts: $storageAccountCount" -ForegroundColor White
            Write-Host "Managed Disks: $diskCount" -ForegroundColor White
            Write-Host "Total Blob Containers: $totalBlobContainers" -ForegroundColor White
            Write-Host "Total File Shares: $totalFileShares" -ForegroundColor White
            Write-Host "Total Blob Storage: $([math]::Round($totalBlobStorage, 2)) GB" -ForegroundColor White
            Write-Host "Total Disk Storage: $([math]::Round($totalDiskStorage, 2)) GB" -ForegroundColor White
            
            if ($storageAccountCount -le 10) {
                # Show all storage accounts if 10 or fewer
                Write-Host "`nStorage Account Details:" -ForegroundColor Gray
                $storageSummary = $storageData.GetEnumerator() | ForEach-Object {
                    $storage = $_.Value
                    [PSCustomObject]@{
                        Name = $_.Key
                        ResourceGroup = $storage.ResourceGroup
                        Kind = $storage.Kind
                        SKU = $storage.SkuName
                        Containers = $storage.BlobContainerCount
                        "BlobSize(GB)" = [math]::Round($storage.BlobSizeGB, 2)
                        FileShares = $storage.FileShareCount
                        ClientTag = if ($storage.Tags -and $storage.Tags.ContainsKey("Client")) { $storage.Tags["Client"] } else { "None" }
                    }
                } | Sort-Object "BlobSize(GB)" -Descending
                $storageSummary | Format-Table -AutoSize
            } else {
                # Show summary by SKU type
                Write-Host "`nStorage SKU Summary:" -ForegroundColor Gray
                $skuSummary = $storageData.Values | Group-Object SkuName | ForEach-Object {
                    $sku = $_.Name
                    $accounts = $_.Group
                    $totalBlob = ($accounts | Measure-Object -Property BlobSizeGB -Sum).Sum
                    
                    [PSCustomObject]@{
                        SKU = $sku
                        AccountCount = $accounts.Count
                        "TotalBlobStorage(GB)" = [math]::Round($totalBlob, 2)
                    }
                } | Sort-Object "TotalBlobStorage(GB)" -Descending
                $skuSummary | Format-Table -AutoSize
            }
            
            if ($diskCount -le 15) {
                # Show disk summary
                Write-Host "`nManaged Disk Details:" -ForegroundColor Gray
                $diskSummary = $diskData.GetEnumerator() | ForEach-Object {
                    $disk = $_.Value
                    [PSCustomObject]@{
                        Name = $_.Key
                        ResourceGroup = $disk.ResourceGroup
                        "Size(GB)" = $disk.SizeGB
                        SKU = $disk.SkuName
                        State = $disk.DiskState
                        Attached = $disk.AttachedToVM
                        ClientTag = if ($disk.Tags -and $disk.Tags.ContainsKey("Client")) { $disk.Tags["Client"] } else { "None" }
                    }
                } | Sort-Object "Size(GB)" -Descending
                $diskSummary | Format-Table -AutoSize
            } else {
                # Show disk summary by SKU
                Write-Host "`nDisk SKU Summary:" -ForegroundColor Gray
                $diskSkuSummary = $diskData.Values | Group-Object SkuName | ForEach-Object {
                    $sku = $_.Name
                    $disks = $_.Group
                    $totalSize = ($disks | Measure-Object -Property SizeGB -Sum).Sum
                    
                    [PSCustomObject]@{
                        SKU = $sku
                        DiskCount = $disks.Count
                        "TotalStorage(GB)" = $totalSize
                    }
                } | Sort-Object "TotalStorage(GB)" -Descending
                $diskSkuSummary | Format-Table -AutoSize
            }
        }
    }
} else {
    Write-Warning "No report generated. This could be because:"
    Write-Host "1. No usage data found for this month" -ForegroundColor Yellow
    Write-Host "2. Resources don't have matching client tags (if using -UseClientTags)" -ForegroundColor Yellow
    Write-Host "3. Client tags don't match predefined quotas" -ForegroundColor Yellow
    if ($clientUsage.Keys.Count -gt 0) {
        Write-Host "`nClients found in usage data: $($clientUsage.Keys -join ', ')" -ForegroundColor White
        Write-Host "Configured quota clients: $($quotas.Keys -join ', ')" -ForegroundColor White
        if (-not $UseClientTags) {
            Write-Host "`nTip: The script is in 'Overall Subscription' mode. Use -UseClientTags for client-specific analysis." -ForegroundColor Cyan
        }
    }
}
