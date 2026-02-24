# AzurePolicy

This folder contains Azure Policy definitions and PowerShell scripts for managing Azure governance, compliance reporting, and automated remediation.

---

## Get-InitiativeComplianceReport.ps1

### What it does

Generates a detailed compliance report for an Azure Policy initiative assignment across multiple subscriptions and exports the results to a CSV file. The report includes:

- Resource ID, subscription, and resource group
- Policy assignment and definition details (name, display name, description)
- Compliance state and timestamp for each resource

The script retrieves all policy states for the specified assignment from a management group, optionally filters to a subset of subscriptions, enriches each record with human-readable policy definition metadata, and writes the final report to `PolicyComplianceReport.csv`.

### Prerequisites

- [Azure PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) (`Az` module)
- `Microsoft.PolicyInsights/policyStates/read` permission on the target management group
- `Microsoft.Authorization/policyDefinitions/read` permission for policy definition lookups
- Authenticated Azure session (`Connect-AzAccount`)

### Configuration

Before running, update the following variables inside the script:

| Variable | Description |
|---|---|
| `$assignmentId` | The full resource ID of the policy initiative assignment |
| `$subscriptionFilter` | Array of subscription IDs to include in the report (empty array = all subscriptions) |

### How to execute

```powershell
# Connect to Azure (if not already connected)
Connect-AzAccount

# Run the script
.\Get-InitiativeComplianceReport.ps1
```

The CSV report is saved to `PolicyComplianceReport.csv` in the current working directory.

---

## Start-PolicyRemediation.ps1

### What it does

Automatically creates Azure Policy remediation tasks for non-compliant resources within one or more policy initiative assignments. For each unique policy reference ID that has non-compliant resources, the script:

1. Retrieves the policy assignment and its associated policy set definition.
2. Queries current policy states scoped to the management group.
3. Checks whether an active remediation task already exists for each policy reference.
4. Skips policies with no non-compliant resources.
5. Creates a new remediation task (appending a timestamp to the name if a previous task exists) using `Start-AzPolicyRemediation`.

### Prerequisites

- [Azure PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) (`Az` module)
- `Policy Contributor` role (or equivalent) on the target management group
- Authenticated Azure session (`Connect-AzAccount`)

### Configuration

Before running, update the following variables inside the script:

| Variable | Description |
|---|---|
| `$InitiativeAssignmentIds` | Array of policy initiative assignment resource IDs to remediate |
| `$managementGroupName` | The management group name/ID where the assignments live |

### How to execute

```powershell
# Connect to Azure (if not already connected)
Connect-AzAccount

# Run the script
.\Start-PolicyRemediation.ps1
```

The script outputs progress and status messages to the console as each policy reference is processed.

---

## AzureDefenderEmailNotifications.json

### What it does

An Azure Policy definition (JSON) that uses the `deployIfNotExists` effect to ensure every Azure subscription has a Microsoft Defender for Cloud security contact configured with the specified email address, alert severity threshold, attack-path risk level, and notification roles.

The policy:

1. **Evaluates** each subscription to check whether a `Microsoft.Security/securityContacts` resource exists with the expected configuration.
2. **Deploys** the security contact (via a subscription-scoped ARM template) if it is absent or misconfigured.

### Parameters

| Parameter | Type | Allowed values | Default | Description |
|---|---|---|---|---|
| `securityEmail` | String | Any valid email(s) | *(required)* | Security contact email address; separate multiple addresses with `;` |
| `alertSeverity` | String | `High`, `Medium`, `Low` | `High` | Minimum Defender alert severity that triggers an email notification |
| `attackPathSeverity` | String | `Critical`, `High`, `Medium`, `Low` | `Critical` | Minimum attack-path risk level that triggers an email notification |
| `notificationRoles` | Array | `Owner`, `AccountAdmin`, `ServiceAdmin`, `Contributor` | `["Owner"]` | Azure roles that receive email notifications |

### How to deploy

#### Azure Portal

1. Navigate to **Azure Policy** → **Definitions** → **+ Policy definition**.
2. Set the definition location (management group or subscription).
3. Paste the contents of `AzureDefenderEmailNotifications.json` into the **Policy rule** editor.
4. Fill in the display name and description, then **Save**.
5. Create an assignment from the new definition and supply parameter values.

#### Azure CLI

```bash
# Create the policy definition
az policy definition create \
  --name "deploy-defender-email-notifications" \
  --display-name "Deploy Microsoft Defender Email Notifications" \
  --description "Ensures Defender email notifications are configured on subscriptions" \
  --rules AzureDefenderEmailNotifications.json \
  --mode All

# Assign the policy (example at management group scope)
az policy assignment create \
  --name "defender-email-assignment" \
  --policy "deploy-defender-email-notifications" \
  --scope "/providers/Microsoft.Management/managementGroups/<management-group-id>" \
  --params '{"securityEmail":{"value":"security@example.com"},"alertSeverity":{"value":"High"},"attackPathSeverity":{"value":"Critical"},"notificationRoles":{"value":["Owner"]}}'
```

#### Azure PowerShell

```powershell
# Connect to Azure (if not already connected)
Connect-AzAccount

# Create the policy definition at management group scope
$definition = New-AzPolicyDefinition `
  -Name "deploy-defender-email-notifications" `
  -DisplayName "Deploy Microsoft Defender Email Notifications" `
  -Policy ".\AzureDefenderEmailNotifications.json" `
  -ManagementGroupName "<management-group-id>" `
  -Mode All

# Assign the policy
$params = @{
    securityEmail       = @{ value = "security@example.com" }
    alertSeverity       = @{ value = "High" }
    attackPathSeverity  = @{ value = "Critical" }
    notificationRoles   = @{ value = @("Owner") }
}
New-AzPolicyAssignment `
  -Name "defender-email-assignment" `
  -PolicyDefinition $definition `
  -Scope "/providers/Microsoft.Management/managementGroups/<management-group-id>" `
  -PolicyParameterObject $params
```
