<#
.SYNOPSIS
    Generates a compliance report for an Azure Policy initiative across multiple subscriptions.

.DESCRIPTION
    This script retrieves policy compliance states for a specified policy assignment ID,
    filters results by subscription IDs if provided, and exports a detailed compliance 
    report to CSV format. It includes policy definition details like display names and 
    descriptions for better report readability.

.PARAMETER assignmentId
    The Azure Policy assignment ID to generate the report for (must be updated in script)

.PARAMETER subscriptionFilter
    Array of subscription IDs to filter the report (must be updated in script)

.EXAMPLE
    .\Get-InitiativeComplianceReport.ps1
    Generates a policy compliance report and exports it to PolicyComplianceReport.csv

.NOTES
    Requires Azure PowerShell module and appropriate permissions to read policy states
    and definitions across the specified management group and subscriptions.
#>

$assignmentId = "<insert assignment ID here>"

$subscriptionFilter = @(
    "c3132b36-4ba4-4c59-ad0b-2e1fc9acec0f",
    "51197638-6639-4693-a9b3-feeef2235f9b",
    "5cdcc8b8-f94b-47c2-a2e6-255db3c6b3ff",
    "28984b23-c838-4935-8f61-9f91bdca091a",
    "5ce65d19-544c-417a-b183-6c055e350ae2",
    "2af76a25-46a2-4947-a0ef-79628e99503e",
    "2156c7df-5d8b-47a5-b1be-6a0bd971a09a",
    "d32ff943-d072-461d-a1f0-14e18d4018c6",
    "371c64f1-e01a-432b-ab5d-882fd907cbda",
    "9654d745-b025-4289-bd21-843952d7961a",
    "99943e0d-fe76-46d7-bce3-7c05a722f221",
    "dae4a5e2-d2c8-4262-b59e-07ffc4fb8597",
    "d8367cea-20b0-43bc-91c4-7e2d966d33d5",
    "2b07d6fc-52cc-48f9-8df8-a1ebf0cbbba6"
)

$managementGroupId = ($assignmentId -split '/')[4]
$assignmentName = ($assignmentId -split '/')[-1]

$policyStates = Get-AzPolicyState -ManagementGroupName $managementGroupId -Filter "PolicyAssignmentName eq '$assignmentName'"

# Filter by subscription IDs if specified
if ($subscriptionFilter.Count -gt 0) {
    Write-Host "Filtering for $($subscriptionFilter.Count) specific subscriptions..." -ForegroundColor Cyan
    $policyStates = $policyStates | Where-Object { $_.SubscriptionId -in $subscriptionFilter }
}

Write-Host "Processing $($policyStates.Count) compliance records..." -ForegroundColor Green

$uniquePolicyIds = $policyStates | Select-Object -ExpandProperty PolicyDefinitionId -Unique
Write-Host "Found $($uniquePolicyIds.Count) unique policies to load..." -ForegroundColor Yellow

$policyDefinitionCache = @{}
$counter = 0
foreach ($policyId in $uniquePolicyIds) {
    $counter++
    Write-Progress -Activity "Loading Policy Definitions" -Status "Policy $counter of $($uniquePolicyIds.Count)" -PercentComplete (($counter / $uniquePolicyIds.Count) * 100)
    
    try {
        $policyDef = Get-AzPolicyDefinition -Id $policyId
        $policyDefinitionCache[$policyId] = @{
            DisplayName = $policyDef.DisplayName
            Description = $policyDef.Description
        }
    }
    catch {
        Write-Warning "Failed to get policy definition for $policyId"
        $policyDefinitionCache[$policyId] = @{
            DisplayName = "Unknown"
            Description = "Unable to retrieve description"
        }
    }
}
Write-Progress -Activity "Loading Policy Definitions" -Completed

Write-Host "Building compliance report..." -ForegroundColor Yellow
$report = foreach ($state in $policyStates) {
    $cachedPolicy = $policyDefinitionCache[$state.PolicyDefinitionId]
    
    [PSCustomObject]@{
        ResourceId = $state.ResourceId
        SubscriptionId = $state.SubscriptionId
        ResourceGroupName = $state.ResourceGroupName
        PolicyAssignmentName = $state.PolicyAssignmentName
        PolicyDefinitionId = $state.PolicyDefinitionId
        PolicyDefinitionDisplayName = $cachedPolicy.DisplayName
        PolicyDefinitionDescription = $cachedPolicy.Description
        ComplianceState = $state.ComplianceState
        TimeStamp = $state.TimeStamp
    }
}


$exportPath = ".\PolicyComplianceReport.csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation

Write-Host "Policy compliance report exported to $exportPath"
