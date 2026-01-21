<#
.SYNOPSIS
    Automated Azure Policy remediation script for policy initiatives

.DESCRIPTION
    This script processes Azure Policy initiative assignments and automatically creates 
    remediation tasks for non-compliant resources. It handles multiple policies within 
    an initiative and manages existing remediations intelligently.

.PARAMETER InitiativeAssignmentIds
    Array of policy assignment IDs to process for remediation

.PARAMETER managementGroupName  
    The management group name/ID where the policies are assigned

.EXAMPLE
    .\Start-PolicyRemediation.ps1
    Runs the script with the configured assignment IDs and management group

.NOTES
    Prerequisites:
    - Azure PowerShell module
    - Policy Contributor permissions on target management group
    - Connected to Azure (Connect-AzAccount)
    
    Author: Azure Policy Team
    Version: 1.0
#>

$InitiativeAssignmentIds = @(
    "/providers/microsoft.management/managementgroups/test-id/providers/microsoft.authorization/policyassignments/2e2b11fc3f764434a646cfff"
)
$managementGroupName = "test-id"

foreach ($assignmentId in $InitiativeAssignmentIds) {

    Write-Output "Processing initiative assignment ID: $assignmentId"

    # Get the policy assignment object by ID
    $initiativeAssignment = Get-AzPolicyAssignment -Id $assignmentId

    if (-not $initiativeAssignment) {
        Write-Warning "Policy assignment with ID '$assignmentId' not found; skipping"
        continue
    }

    $policyDefinitionId = $initiativeAssignment.PolicyDefinitionId
    
    # Try to get the policy set definition - first try by ID (for built-in policies)
    $policySetDefinition = $null
    try {
        $policySetDefinition = Get-AzPolicySetDefinition -Id $policyDefinitionId -ErrorAction SilentlyContinue
    }
    catch {
        # If that fails, try by name in the management group (for custom policies)
        $policySetName = $policyDefinitionId.Split('/')[-1]
        $policySetDefinition = Get-AzPolicySetDefinition -ManagementGroupName $managementGroupName -Name $policySetName -ErrorAction SilentlyContinue
    }

    if (-not $policySetDefinition) {
        Write-Warning "Policy set definition '$policyDefinitionId' not found for assignment '$assignmentId'; skipping"
        continue
    }

    Write-Output "Filtering policy states for assignment ID: $assignmentId"

    # Get policy states for the specific assignment and management group
    $policyStates = Get-AzPolicyState -ManagementGroupName $managementGroupName | Where-Object { $_.PolicyAssignmentId -eq $assignmentId }

    Write-Output "Total policy states found: $($policyStates.Count)"


    $uniquePolicyRefs = $policyStates | Select-Object -ExpandProperty PolicyDefinitionReferenceId -Unique

    Write-Output "Unique policy reference IDs found: $($uniquePolicyRefs.Count)"

    foreach ($policyRefId in $uniquePolicyRefs) {

        $remediationName = "rem." + $policyRefId.ToLower()

        # Check for current non-compliant resources for this specific policy
        $currentNonCompliantResources = $policyStates | Where-Object { 
            $_.PolicyDefinitionReferenceId -eq $policyRefId -and 
            $_.ComplianceState -eq "NonCompliant" 
        }

        if ($currentNonCompliantResources.Count -eq 0) {
            Write-Output "No non-compliant resources found for policy '$policyRefId'. Skipping remediation..."
            continue
        }

        Write-Output "Found $($currentNonCompliantResources.Count) non-compliant resources for policy '$policyRefId'"

        # Check for existing remediation in the management group scope
        $existingRemediation = Get-AzPolicyRemediation -ManagementGroupName $managementGroupName -Name $remediationName -ErrorAction SilentlyContinue

        if ($existingRemediation) {
            $state = $existingRemediation.ProvisioningState
            if ($state -eq 'Accepted' -or $state -eq 'Running' -or $state -eq 'Evaluating') {
                Write-Output "Remediation '$remediationName' already active (state: $state). Skipping..."
                continue
            }
            elseif ($state -eq 'Succeeded') {
                Write-Output "Previous remediation '$remediationName' succeeded, but new non-compliant resources found. Creating new remediation with timestamp..."
                # Add timestamp to make the name unique for new remediation
                $timestamp = Get-Date -Format "yyyyMMddHHmmss"
                $remediationName = "rem." + $policyRefId.ToLower() + "-" + $timestamp
            }
            else {
                Write-Output "Remediation '$remediationName' found with state '$state'. Creating new remediation with timestamp..."
                # Add timestamp to make the name unique
                $timestamp = Get-Date -Format "yyyyMMddHHmmss"
                $remediationName = "rem." + $policyRefId.ToLower() + "-" + $timestamp
            }
        }

        Write-Output "Starting remediation: $remediationName"

        Start-AzPolicyRemediation -ManagementGroupName $managementGroupName `
                                 -Name $remediationName `
                                 -PolicyAssignmentId $assignmentId `
                                 -PolicyDefinitionReferenceId $policyRefId
    }

}