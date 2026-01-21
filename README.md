# AzureScripts

This folder contains PowerShell scripts and Azure policy definitions for managing Azure resources and compliance.

## Folder Structure

### AzurePolicy/
Contains Azure Policy definitions and compliance reporting scripts for governance and security enforcement.

**Files:**
- `Get-InitiativeComplianceReport.ps1` - Generates compliance reports for Azure Policy initiatives across multiple subscriptions
- `AzureDefenderEmailNotifications.json` - Azure Policy definition for deploying Microsoft Defender email notification configurations

### miscPowershellSripts/
Contains miscellaneous PowerShell utility scripts for Azure administration tasks.

**Files:**
- `Remove-UserRoleAssignments.ps1` - Script to remove role assignments for a specific user across Azure subscriptions (with dry-run capability)

## Usage

Before running any PowerShell scripts, ensure you have:
1. Azure PowerShell module installed (`Install-Module -Name Az`)
2. Appropriate permissions for the Azure resources you're managing
3. Authenticated to Azure (`Connect-AzAccount`)

## Security Notes

- All scripts should be reviewed and tested in a non-production environment first
- Scripts that modify resources (like role assignments) include dry-run modes for safe testing
- Update subscription IDs and user principal names as needed for your environment