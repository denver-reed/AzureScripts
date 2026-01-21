
# Script to check if custom role actions are still valid
# Actions can be retired or changed over time in Azure

param(
    [Parameter(Mandatory=$false)]
    [string]$RoleName,
    
    [Parameter(Mandatory=$false)]
    [switch]$AllCustomRoles,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowDetails
)

# Cache for all provider operations (loaded once)
$script:AllProviderOperations = $null

# Function to get and cache all provider operations
function Get-CachedProviderOperations {
    if ($script:AllProviderOperations -eq $null) {
        Write-Host "Loading all Azure provider operations (one-time cache)..." -ForegroundColor Yellow
        $script:AllProviderOperations = @{}
        
        # Get all provider operations in one call
        $allOps = Get-AzProviderOperation
        foreach ($op in $allOps) {
            $script:AllProviderOperations[$op.Operation] = $op
        }
        Write-Host "Cached $($script:AllProviderOperations.Count) provider operations" -ForegroundColor Green
    }
    return $script:AllProviderOperations
}

# Function to check if an action is valid using cached data
function Test-ActionValidity {
    param(
        [string]$Action,
        [hashtable]$ProviderOperations
    )
    
    # Check for exact match first
    if ($ProviderOperations.ContainsKey($Action)) {
        return $true
    }
    
    # Handle wildcard actions
    if ($Action.EndsWith("/*")) {
        $prefix = $Action.Substring(0, $Action.Length - 2)  # Remove "/*"
        
        # Check if any operations start with this prefix
        foreach ($operation in $ProviderOperations.Keys) {
            if ($operation.StartsWith($prefix + "/")) {
                return $true
            }
        }
    }
    
    # Handle resource provider wildcards
    if ($Action.EndsWith("*") -and -not $Action.EndsWith("/*")) {
        $prefix = $Action.Substring(0, $Action.Length - 1)  # Remove "*"
        
        # Check if any operations start with this prefix
        foreach ($operation in $ProviderOperations.Keys) {
            if ($operation.StartsWith($prefix)) {
                return $true
            }
        }
    }
    
    return $false
}

# Function to check actions for a specific role
function Test-RoleActions {
    param(
        [Parameter(Mandatory=$true)]
        $RoleDefinition,
        [Parameter(Mandatory=$true)]
        [hashtable]$ProviderOperations
    )
    
    Write-Host "Checking role: $($RoleDefinition.Name)" -ForegroundColor Cyan
    Write-Host "Role ID: $($RoleDefinition.Id)" -ForegroundColor Gray
    
    $invalidActions = @()
    $validActions = @()
    
    # Check Actions
    if ($RoleDefinition.Actions) {
        Write-Host "`nChecking $($RoleDefinition.Actions.Count) Actions..." -ForegroundColor Yellow
        
        foreach ($action in $RoleDefinition.Actions) {
            if (Test-ActionValidity -Action $action -ProviderOperations $ProviderOperations) {
                $validActions += $action
                if ($ShowDetails) {
                    Write-Host "  VALID: $action" -ForegroundColor Green
                }
            } else {
                $invalidActions += $action
                Write-Warning "  INVALID: $action"
            }
        }
        
        if (-not $ShowDetails) {
            Write-Host "  Found $($validActions.Count) valid actions" -ForegroundColor Green
            if ($invalidActions.Count -gt 0) {
                Write-Host "  Found $($invalidActions.Count) invalid actions" -ForegroundColor Red
            }
        }
    }
    
    # Check NotActions
    if ($RoleDefinition.NotActions) {
        Write-Host "`nChecking $($RoleDefinition.NotActions.Count) NotActions..." -ForegroundColor Yellow
        
        $invalidNotActions = @()
        foreach ($notAction in $RoleDefinition.NotActions) {
            if (Test-ActionValidity -Action $notAction -ProviderOperations $ProviderOperations) {
                if ($ShowDetails) {
                    Write-Host "  VALID NotAction: $notAction" -ForegroundColor Green
                }
            } else {
                $invalidNotActions += $notAction
                Write-Warning "  INVALID NotAction: $notAction"
            }
        }
        
        if (-not $ShowDetails -and $invalidNotActions.Count -eq 0) {
            Write-Host "  All NotActions are valid" -ForegroundColor Green
        }
    }
    
    # Summary for this role
    Write-Host "`nSummary for $($RoleDefinition.Name):" -ForegroundColor Magenta
    Write-Host "  Valid Actions: $($validActions.Count)" -ForegroundColor Green
    Write-Host "  Invalid Actions: $($invalidActions.Count)" -ForegroundColor Red
    
    if ($invalidActions.Count -gt 0) {
        Write-Host "  Invalid actions found:" -ForegroundColor Red
        $invalidActions | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }
    
    Write-Host ("=" * 80)
    
    return @{
        RoleName = $RoleDefinition.Name
        RoleId = $RoleDefinition.Id
        ValidActions = $validActions
        InvalidActions = $invalidActions
    }
}

# Main execution
try {
    # Check if user is connected to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Not connected to Azure. Please run Connect-AzAccount first."
        exit 1
    }
    
    Write-Host "Connected to Azure subscription: $($context.Subscription.Name)" -ForegroundColor Green
    
    # Load and cache all provider operations once
    $providerOperations = Get-CachedProviderOperations
    
    Write-Host ("=" * 80)
    
    $results = @()
    
    if ($AllCustomRoles) {
        # Check all custom roles
        Write-Host "Retrieving all custom role definitions..." -ForegroundColor Cyan
        $customRoles = Get-AzRoleDefinition | Where-Object { $_.IsCustom -eq $true }
        
        if ($customRoles.Count -eq 0) {
            Write-Warning "No custom roles found in this subscription."
            exit 0
        }
        
        Write-Host "Found $($customRoles.Count) custom role(s)" -ForegroundColor Green
        Write-Host ("=" * 80)
        
        $roleCount = 0
        foreach ($role in $customRoles) {
            $roleCount++
            Write-Host "Processing role $roleCount of $($customRoles.Count)..." -ForegroundColor Gray
            $result = Test-RoleActions -RoleDefinition $role -ProviderOperations $providerOperations
            $results += $result
        }
    }
    elseif ($RoleName) {
        # Check specific role
        Write-Host "Retrieving role definition for: $RoleName" -ForegroundColor Cyan
        $roleDefinition = Get-AzRoleDefinition -Name $RoleName -ErrorAction SilentlyContinue
        
        if (-not $roleDefinition) {
            Write-Error "Role '$RoleName' not found."
            exit 1
        }
        
        $result = Test-RoleActions -RoleDefinition $roleDefinition -ProviderOperations $providerOperations
        $results += $result
    }
    else {
        Write-Host "Please specify either -RoleName or -AllCustomRoles parameter." -ForegroundColor Yellow
        Write-Host "Examples:" -ForegroundColor Yellow
        Write-Host "  .\checkCustomRoleActions.ps1 -RoleName 'My Custom Role'" -ForegroundColor Yellow
        Write-Host "  .\checkCustomRoleActions.ps1 -AllCustomRoles" -ForegroundColor Yellow
        Write-Host "  .\checkCustomRoleActions.ps1 -AllCustomRoles -ShowDetails" -ForegroundColor Yellow
        exit 0
    }
    
    # Overall summary
    Write-Host "`nOVERALL SUMMARY:" -ForegroundColor Magenta
    $totalInvalid = ($results | ForEach-Object { $_.InvalidActions.Count } | Measure-Object -Sum).Sum
    $totalRoles = $results.Count
    
    Write-Host "Roles checked: $totalRoles" -ForegroundColor Cyan
    Write-Host "Total invalid actions found: $totalInvalid" -ForegroundColor $(if ($totalInvalid -gt 0) { 'Red' } else { 'Green' })
    
    if ($totalInvalid -gt 0) {
        Write-Host "`nROLES WITH INVALID ACTIONS:" -ForegroundColor Red
        $results | Where-Object { $_.InvalidActions.Count -gt 0 } | ForEach-Object {
            Write-Host "  - $($_.RoleName) ($($_.InvalidActions.Count) invalid actions)" -ForegroundColor Red
        }
        
        Write-Host "`nRECOMMENDATION: Review and update these custom roles to remove invalid actions." -ForegroundColor Yellow
    } else {
        Write-Host "All role actions are valid! ✓" -ForegroundColor Green
    }
}
catch {
    Write-Error "Error occurred: $($_.Exception.Message)"
    exit 1
}
