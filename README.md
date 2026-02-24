# AzureScripts

This repository contains PowerShell scripts, Bash scripts, and Azure Policy definitions for managing Azure resources, governance, and compliance.

## Folder Structure

### [AzurePolicy/](./AzurePolicy/README.md)
Contains Azure Policy definitions and scripts for governance, compliance reporting, and automated remediation.

| File | Description |
|---|---|
| `Get-InitiativeComplianceReport.ps1` | Generates a CSV compliance report for an Azure Policy initiative across multiple subscriptions |
| `Start-PolicyRemediation.ps1` | Automatically creates remediation tasks for non-compliant resources in policy initiative assignments |
| `AzureDefenderEmailNotifications.json` | Azure Policy definition that deploys Microsoft Defender email notification security contacts |

See [AzurePolicy/README.md](./AzurePolicy/README.md) for detailed usage instructions.

### [miscSripts/](./miscSripts/README.md)
Contains miscellaneous Azure administration scripts for role management, WAF configuration, and custom role validation.

| File | Description |
|---|---|
| `Remove-UserRoleAssignments.ps1` | Removes all role assignments for a specified user across Azure subscriptions (with dry-run capability) |
| `appGatewayWAF.sh` | Azure CLI commands to add WAF policy exceptions on an Azure Application Gateway |
| `checkCustomRoleActions.ps1` | Validates that actions defined in custom Azure role definitions are still valid provider operations |

See [miscSripts/README.md](./miscSripts/README.md) for detailed usage instructions.

## Usage

Before running any PowerShell scripts, ensure you have:
1. Azure PowerShell module installed (`Install-Module -Name Az`)
2. Appropriate permissions for the Azure resources you're managing
3. Authenticated to Azure (`Connect-AzAccount`)

Before running any Bash/Azure CLI scripts, ensure you have:
1. [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
2. Appropriate permissions for the Azure resources you're managing
3. Authenticated to Azure (`az login`)

## Security Notes

- All scripts should be reviewed and tested in a non-production environment first
- Scripts that modify resources (like role assignments) include dry-run modes for safe testing
- Update subscription IDs, user principal names, and resource names as needed for your environment