<#
.SYNOPSIS
    Removes all role assignments for a specified user across Azure subscriptions.

.DESCRIPTION
    This script safely removes Azure role assignments for a user across one or more 
    subscriptions. It includes a dry-run mode for testing before actual removal and 
    provides detailed logging of all operations. The script can target a specific 
    subscription or search across all accessible subscriptions.

.PARAMETER userPrincipalName
    The UPN (User Principal Name) of the user whose role assignments will be removed

.PARAMETER subscriptionId
    Optional subscription ID to limit the scope. Leave empty to search all accessible subscriptions

.PARAMETER executeRemoval
    Set to $true to actually remove assignments; $false for dry-run mode (default)

.EXAMPLE
    .\Remove-UserRoleAssignments.ps1
    Performs a dry run showing what role assignments would be removed

.EXAMPLE
    # Set executeRemoval = $true in script
    .\Remove-UserRoleAssignments.ps1
    Actually removes the role assignments after confirmation

.NOTES
    Requires Azure PowerShell module and Global Administrator or User Access Administrator
    permissions. Always test with dry-run mode first before executing actual removals.
#>

# UPN of the user to remove role assignments from
$userPrincipalName = "<user@upn.com>"

# Optional: Specific subscription ID to limit scope (leave empty to search all accessible subscriptions)
$subscriptionId = ""

# Set to $true to actually remove assignments; $false for dry run
$executeRemoval = $false

function Get-UserObjectId {
    param([string]$upn)
    
    try {
        $user = Get-AzADUser -UserPrincipalName $upn
        if ($user) {
            return $user.Id
        } else {
            throw "User not found: $upn"
        }
    }
    catch {
        throw "Failed to get user object ID: $($_.Exception.Message)"
    }
}

function Remove-RoleAssignmentSafe {
    param(
        [object]$roleAssignment,
        [bool]$execute
    )
    
    $scope = $roleAssignment.Scope
    $roleName = $roleAssignment.RoleDefinitionName
    $assignmentId = $roleAssignment.RoleAssignmentId
    
    if ($execute) {
        try {
            Remove-AzRoleAssignment -ObjectId $roleAssignment.ObjectId -RoleDefinitionName $roleName -Scope $scope
            Write-Host "✓ REMOVED: $roleName at scope: $scope" -ForegroundColor Red
            return $true
        }
        catch {
            Write-Warning "Failed to remove assignment $assignmentId : $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Host "DRY RUN: Would remove assignment:" -ForegroundColor Yellow
        Write-Host "  Role: $roleName" -ForegroundColor Cyan
        Write-Host "  Scope: $scope" -ForegroundColor Gray
        Write-Host "  Assignment ID: $assignmentId" -ForegroundColor DarkGray
        Write-Host ""
        return $true
    }
}

try {
    Write-Host "Starting role assignment removal for user: $userPrincipalName" -ForegroundColor Green
    
    if (-not $executeRemoval) {
        Write-Host "*** DRY RUN MODE - No changes will be made ***" -ForegroundColor Magenta
    }
    
    Write-Host "Looking up user object ID..." -ForegroundColor Yellow
    $userObjectId = Get-UserObjectId -upn $userPrincipalName
    Write-Host "Found user with Object ID: $userObjectId" -ForegroundColor Green
    
    if ($subscriptionId) {
        Write-Host "Setting subscription context to: $subscriptionId" -ForegroundColor Yellow
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
        $searchScope = "subscription"
    } else {
        $searchScope = "all accessible subscriptions"
    }
    
    Write-Host "Searching for role assignments across $searchScope..." -ForegroundColor Yellow
    
    $roleAssignments = @()
    
    if ($subscriptionId) {
        # Search within specific subscription only
        $roleAssignments = Get-AzRoleAssignment -ObjectId $userObjectId
    } else {
        # Search across all scopes: management groups, subscriptions, resource groups, resources
        
        Write-Host "Searching management groups and root scope..." -ForegroundColor Cyan
        try {
            $rootAndMgAssignments = Get-AzRoleAssignment -ObjectId $userObjectId -ErrorAction SilentlyContinue
            if ($rootAndMgAssignments) {
                $roleAssignments += $rootAndMgAssignments
                # Write-Host "Found $($rootAndMgAssignments.Count) assignments at management group/root level" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Could not search root/management group scope: $($_.Exception.Message)"
        }
        
        $subscriptions = Get-AzSubscription
        Write-Host "Found $($subscriptions.Count) accessible subscriptions to search..." -ForegroundColor Cyan
        
        foreach ($sub in $subscriptions) {
            Write-Progress -Activity "Searching Subscriptions" -Status "Checking $($sub.Name)" -PercentComplete (($subscriptions.IndexOf($sub) / $subscriptions.Count) * 100)
            
            try {
                Set-AzContext -SubscriptionId $sub.Id | Out-Null
                $subAssignments = Get-AzRoleAssignment -ObjectId $userObjectId -ErrorAction SilentlyContinue
                if ($subAssignments) {
                    $newAssignments = $subAssignments | Where-Object { 
                        $assignmentId = $_.RoleAssignmentId
                        -not ($roleAssignments | Where-Object { $_.RoleAssignmentId -eq $assignmentId })
                    }
                    if ($newAssignments) {
                        $roleAssignments += $newAssignments
                    }
                }
            }
            catch {
                Write-Warning "Could not search subscription $($sub.Name): $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity "Searching Subscriptions" -Completed
    }
    
    $directAssignments = $roleAssignments | Where-Object { 
        $_.ObjectId -eq $userObjectId -and $_.ObjectType -eq "User" 
    }
    
    Write-Host "`n=== ROLE ASSIGNMENT SUMMARY ===" -ForegroundColor Magenta
    Write-Host "User: $userPrincipalName ($userObjectId)" -ForegroundColor White
    Write-Host "Total direct role assignments found: $($directAssignments.Count)" -ForegroundColor White
    
    if ($directAssignments.Count -eq 0) {
        Write-Host "No direct role assignments found for this user." -ForegroundColor Green
        return
    }
    
    Write-Host "`n=== ASSIGNMENTS TO BE REMOVED ===" -ForegroundColor Magenta
    foreach ($assignment in $directAssignments) {
        $scopeType = switch -Regex ($assignment.Scope) {
            "^/$" { "Root" }
            "^/providers/Microsoft.Management/managementGroups/" { "Management Group" }
            "^/subscriptions/[^/]+$" { "Subscription" }
            "^/subscriptions/[^/]+/resourceGroups/[^/]+$" { "Resource Group" }
            default { "Resource" }
        }
        
        Write-Host "- Role: $($assignment.RoleDefinitionName)" -ForegroundColor Cyan
        Write-Host "  Scope: $($assignment.Scope)" -ForegroundColor Gray
        Write-Host "  Type: $scopeType" -ForegroundColor Gray
        Write-Host ""
    }
    
    if ($executeRemoval) {
        $confirmation = Read-Host "Are you sure you want to remove ALL $($directAssignments.Count) role assignments for this user? (Type 'YES' to confirm)"
        if ($confirmation -ne "YES") {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            return
        }
    }
    
    Write-Host "Processing role assignment removals..." -ForegroundColor Yellow
    $successCount = 0
    $failCount = 0
    
    foreach ($assignment in $directAssignments) {
        if (Remove-RoleAssignmentSafe -roleAssignment $assignment -execute $executeRemoval) {
            $successCount++
        } else {
            $failCount++
        }
    }
    
    Write-Host "`n=== REMOVAL SUMMARY ===" -ForegroundColor Magenta
    if ($executeRemoval) {
        Write-Host "Successfully removed: $successCount assignments" -ForegroundColor Green
        Write-Host "Failed to remove: $failCount assignments" -ForegroundColor Red
    } else {
        Write-Host "Dry run completed - $($directAssignments.Count) assignments would be removed" -ForegroundColor Yellow
        Write-Host "Set `$executeRemoval = `$true to actually remove assignments" -ForegroundColor Cyan
    }
}
catch {
    Write-Error "Error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}