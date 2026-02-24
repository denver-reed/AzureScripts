# miscSripts

This folder contains miscellaneous Azure administration scripts for managing role assignments, WAF policy exceptions, and custom role validation.

---

## Remove-UserRoleAssignments.ps1

### What it does

Safely removes all direct Azure role assignments for a specified user across one or more subscriptions. Key features:

- **Dry-run mode** (default): Lists all role assignments that *would* be removed without making any changes.
- **Execute mode**: Prompts for explicit confirmation before removing assignments.
- Searches across management groups, all accessible subscriptions, resource groups, and individual resources.
- Deduplicates assignments discovered across multiple subscription contexts.
- Reports a per-run summary of successful and failed removals.

### Prerequisites

- [Azure PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) (`Az` module)
- `User Access Administrator` or `Global Administrator` role on the target scope(s)
- Authenticated Azure session (`Connect-AzAccount`)

### Configuration

Before running, update the following variables inside the script:

| Variable | Default | Description |
|---|---|---|
| `$userPrincipalName` | `"<user@upn.com>"` | UPN of the user whose assignments will be removed |
| `$subscriptionId` | `""` | Specific subscription ID to limit scope; leave empty to search all accessible subscriptions |
| `$executeRemoval` | `$false` | Set to `$true` to actually remove assignments; `$false` runs in dry-run mode |

### How to execute

```powershell
# Connect to Azure (if not already connected)
Connect-AzAccount

# Step 1 – Dry run (review what would be removed)
# Ensure $executeRemoval = $false in the script
.\Remove-UserRoleAssignments.ps1

# Step 2 – Execute removal
# Set $executeRemoval = $true in the script, then run again
.\Remove-UserRoleAssignments.ps1
# You will be prompted: type 'YES' to confirm before any changes are made
```

> **Tip:** Always perform a dry run first to verify the scope of changes before executing actual removals.

---

## appGatewayWAF.sh

### What it does

A Bash reference script containing Azure CLI commands to manage **WAF (Web Application Firewall) policy exceptions** on an Azure Application Gateway. Specifically, it adds exceptions to the OWASP 3.2 rule set to allow traffic that would otherwise be blocked by SQL injection detection rules (rule group `REQUEST-942-APPLICATION-ATTACK-SQLI`).

The script includes:

- **Add exception (rule group scope)** – Excludes a specific request URI from all rules in the `REQUEST-942-APPLICATION-ATTACK-SQLI` rule group.
- **Add exception (specific rule)** – Excludes a specific URI from a single rule within the rule group (e.g., rule ID `942420`).
- **List exceptions** – Lists all current exceptions defined on the WAF policy.

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and available on `PATH`
- `Contributor` or `Network Contributor` role on the target Application Gateway / WAF policy resource
- Authenticated Azure CLI session (`az login`)

### Configuration

Update the following values in the commands to match your environment:

| Placeholder | Description |
|---|---|
| `EBSAPP-GATEWAY` | Resource group containing the Application Gateway |
| `EBS-WAFPolicy` | Name of the WAF policy |
| `app/modules/ajaxgrid/ajaxgridactions.ashx` | Request URI path to exclude |

### How to execute

```bash
# Authenticate (if not already logged in)
az login

# Add a WAF exception for a URI path (rule-group scope)
az network application-gateway waf-policy managed-rule exception add \
  --resource-group <resource-group> \
  --policy-name <waf-policy-name> \
  --match-variable RequestURI \
  --value-operator Contains \
  --values "<uri-path>" \
  --rule-sets '[{
    "ruleSetType": "OWASP",
    "ruleSetVersion": "3.2",
    "ruleGroups": [{"ruleGroupName": "REQUEST-942-APPLICATION-ATTACK-SQLI"}]
  }]'

# List all current exceptions
az network application-gateway waf-policy managed-rule exception list \
  --policy-name <waf-policy-name> \
  --resource-group <resource-group>
```

---

## checkCustomRoleActions.ps1

### What it does

Validates that the actions defined in Azure custom role definitions are still valid (i.e., still exist as registered Azure provider operations). Azure provider operations can be retired or renamed over time, and this script helps identify stale entries before they cause issues.

For each role checked, the script:

1. Loads all Azure provider operations once into a cache for performance.
2. Checks `Actions`, `NotActions`, `DataActions`, and `NotDataActions` against the cache.
3. Supports exact matches and wildcard patterns (e.g., `Microsoft.Compute/*`, `Microsoft.Storage/storageAccounts*`).
4. Reports valid and invalid actions per role, with an overall summary.

### Prerequisites

- [Azure PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) (`Az` module)
- `Reader` role (or equivalent) on the subscription/management group where custom roles are defined
- Authenticated Azure session (`Connect-AzAccount`)

### Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-RoleName` | String | One of `-RoleName` or `-AllCustomRoles` is required | Name of a specific custom role to check |
| `-AllCustomRoles` | Switch | One of `-RoleName` or `-AllCustomRoles` is required | Check all custom roles in the current subscription |
| `-ShowDetails` | Switch | No | Print each individual action result (valid/invalid) instead of just counts |

### How to execute

```powershell
# Connect to Azure (if not already connected)
Connect-AzAccount

# Check a single custom role
.\checkCustomRoleActions.ps1 -RoleName "My Custom Role"

# Check all custom roles in the current subscription
.\checkCustomRoleActions.ps1 -AllCustomRoles

# Check all custom roles with detailed per-action output
.\checkCustomRoleActions.ps1 -AllCustomRoles -ShowDetails
```

The script exits with a summary listing any roles that contain invalid actions and recommends reviewing and updating them.
