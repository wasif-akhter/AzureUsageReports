# Azure Costs & Usage Reports Script

## Purpose

This PowerShell script generates detailed Azure resource usage and quota reports for your subscription. It supports both overall subscription analysis and client tag-based breakdowns, and now includes comprehensive tracking of Azure Storage resources (blob, disk, etc.).

## Features

- Aggregates usage for compute, networking, and storage resources

- Tracks usage vs. quotas for each client or overall subscription

- Supports filtering by resource groups

- Tracks Azure Storage usage (blob, disk, file shares, tables, queues)

- Client tag-based analysis for multi-tenant scenarios

- Customizable date range and subscription ID

- Detailed breakdowns by service category

## Prerequisites

- Windows PowerShell 5.1 or PowerShell Core

- Azure PowerShell module (`Az`)

- Access to an Azure subscription with Cost Management permissions

- Logged in to Azure (`Connect-AzAccount`)

## Installation

1. Install the Azure PowerShell module (if not already installed):

  ```powershell

  Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force

  ```

2. Clone or download this repository.

3. Open a PowerShell terminal in the script directory.

## Usage

Run the script with desired parameters:

- **Overall usage report (default for May 2025):**

  ```powershell

  .\AzureCostsReports.ps1

  ```

- **Client tag-based analysis:**

  ```powershell

  .\AzureCostsReports.ps1 -UseClientTags

  ```

- **Custom date range:**

  ```powershell

  .\AzureCostsReports.ps1 -StartDate "2025-06-01" -EndDate "2025-06-30"

  ```

- **Filter by resource groups:**

  ```powershell

  .\AzureCostsReports.ps1 -ResourceGroups "rg-prod,rg-test"

  ```

- **Specify subscription ID:**

  ```powershell

  .\AzureCostsReports.ps1 -SubscriptionId "<your-sub-id>"

  ```

- **Show detailed breakdown:**

  ```powershell

  .\AzureCostsReports.ps1 -ShowDetailedBreakdown

  ```

- **Show help:**

  ```powershell

  .\AzureCostsReports.ps1 -Help

  ```

## Output

- Tabular report of usage vs. quota for each client or overall subscription

- Summary statistics for core hours, data transfer, disk and blob storage

- Detailed breakdowns by service category and resource type

- Discovery summaries for compute and storage resources

## Example

```

=== AZURE USAGE vs QUOTA REPORT (Client Tag Mode) ===

Client         CoreHours      DataOutGB      DataInGB      DiskStorageGB   BlobStorageGB   Mode

ClientA-Prod   9500 / 10000  80 / 100       400 / 500     900 / 1000      450 / 500       Usage vs Quota

...existing output...

```

## License

MIT

## Author

Wasif Akhter
