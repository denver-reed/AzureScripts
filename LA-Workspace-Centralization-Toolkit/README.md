# Log Analytics Workspace Assessment

This read-only PowerShell toolkit inventories Log Analytics workspaces across a list of Azure subscriptions. Its main output is `WorkspaceAssessment.html`, which shows:

- A workspace overview
- Likely workspace purpose
- Recent active tables and usage
- Configured and observed data senders
- Workspace details and confidence notes

The toolkit does not migrate, repoint, or delete Azure resources.

## Requirements

- PowerShell 7 (`pwsh`)
- The `Az.Accounts` PowerShell module
- An existing Azure login with access to the selected subscriptions and workspaces
- Reader access to the subscriptions
- Log Analytics Reader access to the workspaces

Keep these files together:

- `Export-LAWorkspaceInventory.ps1`
- `LAInventory.Common.psm1`
- `Test-LAInventoryOffline.ps1`

## Run the assessment

Open a PowerShell 7 terminal and go to the toolkit directory:

```powershell
Set-Location 'C:\Path\To\LA-Workspace-Centralization-Toolkit'
```

If needed, sign in to Azure:

```powershell
Connect-AzAccount
```

Run the offline validation:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-LAInventoryOffline.ps1
```

Enter the subscription IDs to assess:

```powershell
$subs = [guid[]]@(
    '11111111-1111-1111-1111-111111111111'
    '22222222-2222-2222-2222-222222222222'
)
```

Run the inventory with a new timestamped output directory:

```powershell
$output = ".\la-customer-inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

& .\Export-LAWorkspaceInventory.ps1 `
    -SubscriptionId $subs `
    -OutputDirectory $output
```

The run can take several minutes and may remain quiet until it finishes.

## Open the report

When the run finishes, open the main customer report:

```powershell
Invoke-Item "$output\WorkspaceAssessment.html"
```

`WorkspaceAssessment.html` is self-contained and can be opened locally without a web server or internet connection.

## Other output files

The output directory also contains CSV and JSON evidence. The most useful supporting files are:

- `workspaceSummary.csv` — one row per workspace
- `workspaceSenders.csv` — configured and observed sender candidates
- `coverage.csv` — detailed collection and API results for troubleshooting

## Important notes

- Always use a new output directory.
- The default activity window is the previous seven days.
- The script performs read-only discovery and aggregate Log Analytics queries.
- Resource and host attribution indicates likely relationships, not definitive proof of the authenticated writer.
- Protect the output because it contains Azure resource names, IDs, host names, and operational metadata.
