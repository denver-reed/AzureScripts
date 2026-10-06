#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][guid[]]$SubscriptionId,
    [string[]]$WorkspaceResourceId = @(),
    [string[]]$ExtraResourceId = @(),
    [ValidateRange(1,365)][int]$LookbackDays = 7,
    [switch]$AllowExpensiveScan,
    [ValidateRange(1,10000)][int]$MaxSourceGroups = 2000,
    [ValidateRange(1,100000)][int]$MaxTableQueries = 100,
    [string[]]$TableName = @(),
    [switch]$ControlPlaneOnly,
    [ValidateRange(0,10)][int]$MaxRetries = 5,
    [ValidateRange(30,600)][int]$QueryTimeoutSeconds = 180,
    [string]$QueryEndpoint,
    [string]$QueryAudience,
    [string]$OutputDirectory = (Join-Path (Get-Location) ("la-inventory-" + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'LAInventory.Common.psm1') -Force
if ($LookbackDays -gt 7 -and -not $AllowExpensiveScan) {
    throw 'LookbackDays above 7 requires -AllowExpensiveScan; wider event scans can incur substantial cost.'
}
if (-not (Get-Module -ListAvailable Az.Accounts)) { throw 'Install Az.Accounts separately; this toolkit never installs modules or logs in.' }
Import-Module Az.Accounts -ErrorAction Stop
$initialContext = Get-AzContext -ErrorAction Stop
if ($null -eq $initialContext -or $null -eq $initialContext.Account) { throw 'An existing Az login is required.' }
$environment = Get-AzEnvironment -Name $initialContext.Environment.Name -ErrorAction Stop
$arm = $environment.ResourceManagerUrl.TrimEnd('/')
if ([bool]$QueryEndpoint -ne [bool]$QueryAudience) { throw 'Specify both QueryEndpoint and QueryAudience, or neither.' }
if (-not $QueryEndpoint) {
    switch ($environment.Name) {
        'AzureCloud' { $QueryEndpoint = 'https://api.loganalytics.azure.com'; $QueryAudience = 'https://api.loganalytics.io' }
        'AzureUSGovernment' { $QueryEndpoint = 'https://api.loganalytics.us'; $QueryAudience = 'https://api.loganalytics.us' }
        default { throw 'This cloud needs explicit QueryEndpoint and QueryAudience verified by its administrator.' }
    }
}
foreach ($endpoint in @($arm, $QueryEndpoint, $QueryAudience)) {
    $u = [uri]$endpoint
    if (-not $u.IsAbsoluteUri -or $u.Scheme -ne 'https' -or $u.UserInfo -or $u.Query -or $u.Fragment) {
        throw 'Endpoints must be absolute HTTPS URLs without credentials, query, or fragment.'
    }
}
$subscriptions = @($SubscriptionId | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
foreach ($id in @($ExtraResourceId) + @($WorkspaceResourceId)) {
    if ($id -notmatch '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/[^/]+/.+' -or
        $Matches[1] -notin $subscriptions -or $id -match '[?#]') {
        throw "An explicit resource ID is invalid or outside SubscriptionId: $id"
    }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory already exists. Choose a new directory to avoid mixing runs.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory
$end = [datetime]::UtcNow
$start = $end.AddDays(-$LookbackDays)
$timespan = "$($start.ToString('o'))/$($end.ToString('o'))"
$data = @{}
$columns = [ordered]@{
    workspaceSummary = @('WorkspaceName','WorkspaceId','SubscriptionId','Location','RetentionInDays','Purpose','DataStatus','ActiveTables','UsageSolutions','ObservedResourceCount','ObservedHostCount','LastEventUtc','DiagnosticSettingCount','DcrCount','ApplicationInsightsCount','ConfiguredSenderCount','DependencyCount','QueryCoverageGapCount','Confidence')
    workspaceSenders = @('WorkspaceName','WorkspaceId','SenderType','SenderName','SourceResourceId','ConfigurationResourceId','Tables','RecordCount','LastEventUtc','Evidence','Confidence','Review')
    workspaces = @('ResourceId','CustomerId','Name','SubscriptionId','Location','Sku','RetentionInDays','WorkspaceCapping','PublicNetworkAccessForIngestion','PublicNetworkAccessForQuery','DefaultDataCollectionRuleResourceId','Features')
    tables = @('WorkspaceId','ResourceId','Name','Plan','RetentionInDays','TotalRetentionInDays','ArchiveRetentionInDays','Schema','ManagementProperties')
    usage = @('WorkspaceId','DataType','Solution','IsBillable','QuantityUnit','Quantity','FirstBucketStartUtc','LastBucketEndUtc','BucketRecords','Coverage')
    sources = @('WorkspaceId','Table','ResourceId','SubscriptionId','Host','IdentityStatus','RecordCount','LastEventUtc','LastArrivalUtc','ArrivalKnownRecords','BillabilityKnownRecords','BilledSizeKnownRecords','BillableRecords','KnownBillableBytes','BillableBytesUnknownRecords','Coverage')
    dcrs = @('ResourceId','Name','SubscriptionId','Kind','ImmutableId','DataCollectionEndpointId','DataSources','StreamDeclarations','Destinations','DataFlows','AssociationCount','AssociationCoverage')
    associations = @('ResourceId','DcrId','AssociatedResourceId','DataCollectionEndpointId','AssociatedResourceInScope')
    diagnostics = @('ResourceId','SourceResourceId','WorkspaceId','Logs','Metrics','LogAnalyticsDestinationType','StorageAccountId','EventHubAuthorizationRuleId','EventHubName')
    applicationInsights = @('ResourceId','WorkspaceId','ApplicationType','IngestionMode')
    workspaceLinks = @('WorkspaceId','ResourceId','Kind','Metadata')
    dependencies = @('ResourceId','Kind','Name','WorkspaceId','ReferencePath','Match','Enabled')
    repointMap = @('WorkspaceId','ConfigResourceId','ConfigKind','ReferencePath','Action','Evidence','ObservedResourceGroups','ObservationScope','Owner','Review')
    coverage = @('Scope','Operation','Status','HttpStatus','Code','Items','Note')
}
foreach ($name in $columns.Keys) { $data[$name] = [System.Collections.Generic.List[object]]::new() }
$clients = @{}
$resources = [System.Collections.Generic.List[object]]::new()
$associationIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Add-Coverage {
    param([string]$Scope,[string]$Operation,[string]$Status,[int]$HttpStatus = 0,[string]$Code = '',[int]$Items = 0,[string]$Note = '')
    $data.coverage.Add([pscustomobject]@{
        Scope=$Scope; Operation=$Operation; Status=$Status; HttpStatus=$HttpStatus; Code=$Code; Items=$Items; Note=$Note
    })
}
function Read-List {
    param($Client,[string]$Path,[string]$Operation,[string]$Scope)
    $r = Get-InventoryList $Client $Path
    $status = if ($r.Complete) { 'Complete' } elseif ($r.Items.Count) { 'Partial' } else { 'Unknown' }
    Add-Coverage $Scope $Operation $status $r.Status $r.Code $r.Items.Count
    return $r
}
function Read-Object {
    param($Client,[string]$Path,[string]$Operation,[string]$Scope)
    $r = Get-InventoryObject $Client $Path
    Add-Coverage $Scope $Operation $(if ($r.Ok) {'Complete'} else {'Unknown'}) $r.Status $r.Code $(if ($r.Ok) {1} else {0})
    return $r
}
function Add-Repoint {
    param([string]$Workspace,[string]$Config,[string]$Kind,[string]$Path,[string]$Action,[string]$Review,[string]$Evidence='Configured')
    if (-not $Workspace) { return }
    $data.repointMap.Add([pscustomobject]@{
        WorkspaceId=$Workspace; ConfigResourceId=$Config; ConfigKind=$Kind; ReferencePath=$Path
        Action=$Action; Evidence=$Evidence; ObservedResourceGroups=0
        ObservationScope='Configured link is not writer proof; see sources and coverage'
        Owner='UNASSIGNED - customer to assign'; Review=$Review
    })
}
function Export-All {
    foreach ($name in $columns.Keys) {
        Export-InventoryDataset $OutputDirectory $name $data[$name].ToArray() $columns[$name]
    }
}
function Add-Association {
    param($Association)
    if (-not $associationIds.Add($Association.id)) { return }
    $p = $Association.properties
    $resource = $Association.id -replace '(?i)/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$',''
    $resourceSub = if ($resource -match '^/subscriptions/([^/]+)') { $Matches[1] } else { '' }
    $data.associations.Add([pscustomobject]@{
        ResourceId=$Association.id; DcrId=(Get-Field $p 'dataCollectionRuleId')
        AssociatedResourceId=$resource; DataCollectionEndpointId=(Get-Field $p 'dataCollectionEndpointId')
        AssociatedResourceInScope=($resourceSub -in $subscriptions)
    })
}

try {
    foreach ($sub in $subscriptions) {
        try {
            # Context is process-local. Use an existing login; do not change persistent defaults.
            $context = Set-AzContext -SubscriptionId $sub -Scope Process -ErrorAction Stop
            if ($context.Environment.Name -ne $environment.Name) { throw 'Mixed clouds are not supported in one run.' }
            $client = New-InventoryClient $context $arm $QueryEndpoint $QueryAudience $MaxRetries $QueryTimeoutSeconds
            $clients[$sub] = $client
        } catch {
            Add-Coverage $sub 'SubscriptionContext' 'Unknown' 0 'ContextUnavailable' 0 'No discovery or queries for this subscription.'
            continue
        }
        $ws = Read-List $client "/subscriptions/$sub/providers/Microsoft.OperationalInsights/workspaces?api-version=2023-09-01" 'Workspaces' $sub
        foreach ($w in $ws.Items) {
            if ($WorkspaceResourceId.Count -and $w.id -notin $WorkspaceResourceId) { continue }
            $p = $w.properties
            $data.workspaces.Add([pscustomobject]@{
                ResourceId=$w.id; CustomerId=(Get-Field $p 'customerId'); Name=$w.name; SubscriptionId=$sub
                Location=$w.location; Sku=(Get-Field (Get-Field $p 'sku') 'name')
                RetentionInDays=(Get-Field $p 'retentionInDays'); WorkspaceCapping=(Get-Field $p 'workspaceCapping')
                PublicNetworkAccessForIngestion=(Get-Field $p 'publicNetworkAccessForIngestion')
                PublicNetworkAccessForQuery=(Get-Field $p 'publicNetworkAccessForQuery')
                DefaultDataCollectionRuleResourceId=(Get-Field $p 'defaultDataCollectionRuleResourceId')
                Features=(Get-Field $p 'features')
            })
        }
        $list = Read-List $client "/subscriptions/$sub/resources?api-version=2021-04-01" 'Resources' $sub
        foreach ($resource in $list.Items) { $resources.Add($resource) }
    }
    foreach ($requested in $WorkspaceResourceId) {
        if ($requested -notin @($data.workspaces | ForEach-Object ResourceId)) {
            Add-Coverage $requested 'RequestedWorkspace' 'Unknown' 0 'NotDiscovered' 0 'Not evidence that the workspace does not exist.'
        }
    }
    foreach ($w in $data.workspaces) {
        $client = $clients[$w.SubscriptionId]
        $wid = $w.ResourceId
        if ($w.DefaultDataCollectionRuleResourceId) {
            Add-Repoint $wid $wid 'WorkspaceTransformationLink' '$.properties.defaultDataCollectionRuleResourceId' `
                'Review workspace-transformation DCR and corresponding central workspace configuration' `
                "Current DCR: $($w.DefaultDataCollectionRuleResourceId). Not an external writer destination; validate schema/transform effects."
        }
        $tableList = Read-List $client "$wid/tables?api-version=2022-10-01" 'WorkspaceTables' $wid
        foreach ($t in $tableList.Items) {
            $p = $t.properties
            $management = [ordered]@{}
            foreach ($key in @('plan','retentionInDays','totalRetentionInDays','archiveRetentionInDays',
                'retentionInDaysAsDefault','totalRetentionInDaysAsDefault','lastPlanModifiedDate',
                'provisioningState','restoredLogs','resultStatistics','protectionLevel')) {
                $v = Get-Field $p $key
                if ($null -ne $v) { $management[$key] = $v }
            }
            $data.tables.Add([pscustomobject]@{
                WorkspaceId=$wid; ResourceId=$t.id; Name=$t.name; Plan=(Get-Field $p 'plan' 'Unknown')
                RetentionInDays=(Get-Field $p 'retentionInDays'); TotalRetentionInDays=(Get-Field $p 'totalRetentionInDays')
                ArchiveRetentionInDays=(Get-Field $p 'archiveRetentionInDays')
                Schema=(Get-Field $p 'schema'); ManagementProperties=$management
            })
        }
        if ($ControlPlaneOnly) {
            Add-Coverage $wid 'UsageQuery' 'Skipped' 0 'ControlPlaneOnly'
        } elseif (-not $w.CustomerId) {
            Add-Coverage $wid 'UsageQuery' 'Unknown' 0 'MissingWorkspaceGuid'
        } else {
            $q = Invoke-InventoryQuery $client $w.CustomerId (New-UsageKql $start $end $MaxSourceGroups) $LookbackDays $MaxSourceGroups -Timespan $timespan
            $quality = if ($q.Complete) {'Complete'} elseif ($q.Rows.Count) {'Partial'} else {'Unknown'}
            Add-Coverage $wid 'UsageQuery' $quality $q.Status $q.Code $q.Rows.Count 'Quantity is in QuantityUnit (normally MB); bucket aggregates, not host telemetry.'
            foreach ($row in $q.Rows) {
                $row | Add-Member NoteProperty WorkspaceId $wid
                $row | Add-Member NoteProperty Coverage $quality
                $data.usage.Add($row)
            }
        }
        $queried = 0
        foreach ($requestedTable in $TableName) {
            if ($requestedTable -notin @($tableList.Items | ForEach-Object name)) {
                Add-Coverage "$wid/tables/$requestedTable" 'SourceQuery' 'Unknown' 0 'RequestedTableNotDiscovered'
            }
        }
        $workspaceUsage = @($data.usage | Where-Object WorkspaceId -IEQ $wid)
        foreach ($table in (Get-PrioritizedInventoryTables $tableList.Items $workspaceUsage $TableName)) {
            $name = $table.name
            $plan = [string](Get-Field $table.properties 'plan' 'Unknown')
            $scope = "$wid/tables/$name"
            $skip = if ($ControlPlaneOnly) {'ControlPlaneOnly'}
                elseif (-not $w.CustomerId) {'MissingWorkspaceGuid'}
                elseif ($TableName.Count -and $name -notin $TableName) {'TableFilter'}
                elseif ($plan -ne 'Analytics') {"UnsupportedOrUnknownPlan:$plan"}
                elseif ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {'UnsupportedTableIdentifier'}
                elseif ($queried -ge $MaxTableQueries -and -not $AllowExpensiveScan) {'TableQueryBudget'}
                else {''}
            if ($skip) { Add-Coverage $scope 'SourceQuery' 'Skipped' 0 $skip; continue }
            $queried++
            $q = Invoke-InventoryQuery $client $w.CustomerId (New-SourceKql $name $start $end $MaxSourceGroups) $LookbackDays $MaxSourceGroups -Timespan $timespan
            $quality = if ($q.Complete) {'Complete'} elseif ($q.Rows.Count) {'Partial'} else {'Unknown'}
            Add-Coverage $scope 'SourceQuery' $quality $q.Status $q.Code $q.Rows.Count 'Event-time bounded aggregate; not an arrival-time completeness or writer-provenance guarantee.'
            foreach ($row in $q.Rows) {
                $row | Add-Member NoteProperty WorkspaceId $wid
                $row | Add-Member NoteProperty Table $name
                $row | Add-Member NoteProperty Coverage $quality
                $data.sources.Add($row)
            }
        }
        # Workspace children: deliberately selected management metadata, never raw configuration blobs.
        $children = @(
            @{ Kind='LinkedServices'; Segment='linkedServices'; Version='2020-08-01' },
            @{ Kind='LinkedStorageAccounts'; Segment='linkedStorageAccounts'; Version='2020-08-01' },
            @{ Kind='LegacyDataSources'; Segment='dataSources'; Version='2020-08-01' },
            @{ Kind='SavedSearches'; Segment='savedSearches'; Version='2020-08-01' },
            @{ Kind='SentinelOnboarding'; Segment='providers/Microsoft.SecurityInsights/onboardingStates'; Version='2024-03-01' },
            @{ Kind='SentinelAlertRules'; Segment='providers/Microsoft.SecurityInsights/alertRules'; Version='2024-03-01' }
        )
        foreach ($child in $children) {
            $result = Read-List $client "$wid/$($child.Segment)?api-version=$($child.Version)" $child.Kind $wid
            foreach ($item in $result.Items) {
                $p = Get-Field $item 'properties'
                $meta = [ordered]@{}
                foreach ($key in @('resourceId','writeAccessResourceId','storageAccountIds','dataSourceType','category','displayName','enabled','customerManagedKey')) {
                    $value = Get-Field $p $key
                    if ($null -ne $value) { $meta[$key] = $value }
                }
                $meta['kind'] = Get-Field $item 'kind'
                $data.workspaceLinks.Add([pscustomobject]@{ WorkspaceId=$wid; ResourceId=$item.id; Kind=$child.Kind; Metadata=$meta })
                $action = if ($child.Kind -in @('SavedSearches','SentinelAlertRules')) {'Recreate/review workspace-scoped dependency; update workspace references'}
                    else {'Review/recreate workspace-scoped configuration; not a destination field swap'}
                Add-Repoint $wid $item.id $child.Kind '$ (workspace-scoped resource parent)' $action 'Manual owner review; definitions and secret-bearing connector settings are not exported.'
            }
        }
        Add-Coverage $wid 'SentinelConnectorConfiguration' 'NotAttempted' 0 'ManualReviewRequired' 0 'Review connectors, automation rules/playbooks, content hub and onboarding separately; credential-bearing connector configurations are not requested.'
    }
    foreach ($sub in $subscriptions) {
        if (-not $clients.ContainsKey($sub)) { continue }
        $client = $clients[$sub]
        $rules = Read-List $client "/subscriptions/$sub/providers/Microsoft.Insights/dataCollectionRules?api-version=2024-03-11" 'DCRs' $sub
        foreach ($rule in $rules.Items) {
            $p = $rule.properties
            $associations = Read-List $client "$($rule.id)/associations?api-version=2024-03-11" 'DCRAssociations' $rule.id
            foreach ($association in $associations.Items) {
                Add-Association $association
            }
            $sourceMetadata = [System.Collections.Generic.List[object]]::new()
            $ds = Get-Field $p 'dataSources'
            if ($null -ne $ds) {
                foreach ($sourceType in $ds.PSObject.Properties) {
                    foreach ($source in @($sourceType.Value)) {
                        $entry = [ordered]@{ Type=$sourceType.Name; Name=(Get-Field $source 'name'); Streams=(Get-Field $source 'streams') }
                        foreach ($key in @('samplingFrequencyInSeconds','counterSpecifiers','xPathQueries','facilityNames','logLevels','filePatterns','format','extensionName','inputDataSources','eventHubResourceId')) {
                            $v = Get-Field $source $key
                            if ($null -ne $v) { $entry[$key] = $v }
                        }
                        $sourceMetadata.Add([pscustomobject]$entry)
                    }
                }
            }
            $destination = @(Get-Field (Get-Field $p 'destinations') 'logAnalytics' @())
            $data.dcrs.Add([pscustomobject]@{
                ResourceId=$rule.id; Name=$rule.name; SubscriptionId=$sub; Kind=(Get-Field $rule 'kind')
                ImmutableId=(Get-Field $p 'immutableId'); DataCollectionEndpointId=(Get-Field $p 'dataCollectionEndpointId')
                DataSources=$sourceMetadata.ToArray(); StreamDeclarations=(Get-Field $p 'streamDeclarations')
                Destinations=$destination; DataFlows=(Get-Field $p 'dataFlows')
                AssociationCount=$associations.Items.Count
                AssociationCoverage=$(if ($associations.Complete) {'Complete'} else {'UnknownOrPartial'})
            })
            for ($i = 0; $i -lt $destination.Count; $i++) {
                $dest = $destination[$i]
                Add-Repoint $dest.workspaceResourceId $rule.id 'DCR' "$.properties.destinations.logAnalytics[$i].workspaceResourceId" `
                    'Review replacement destination and dataFlows; repoint only through a separately approved change' `
                    'Validate destination name, streams, outputStream, transforms, schemas and all DCRAs. Zero associations does not mean unused: direct Logs Ingestion API rules have none.'
            }
        }
        $sourceIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $null = $sourceIds.Add("/subscriptions/$sub")
        foreach ($r in $resources) { if ($r.id.StartsWith("/subscriptions/$sub/",[StringComparison]::OrdinalIgnoreCase)) { $null = $sourceIds.Add($r.id) } }
        foreach ($id in $ExtraResourceId) { if ($id.StartsWith("/subscriptions/$sub/",[StringComparison]::OrdinalIgnoreCase)) { $null = $sourceIds.Add($id) } }
        foreach ($id in $sourceIds) {
            if ($id -ine "/subscriptions/$sub") {
                $resourceAssociations = Read-List $client "$id/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2024-03-11" 'ResourceDCRAssociations' $id
                foreach ($association in $resourceAssociations.Items) { Add-Association $association }
            }
            $diag = Read-List $client "$id/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" 'DiagnosticSettings' $id
            foreach ($setting in $diag.Items) {
                $p = $setting.properties
                $logs = @(Get-Field $p 'logs' @() | ForEach-Object {
                    [pscustomobject]@{ Category=(Get-Field $_ 'category'); CategoryGroup=(Get-Field $_ 'categoryGroup'); Enabled=(Get-Field $_ 'enabled'); RetentionPolicy=(Get-Field $_ 'retentionPolicy') }
                })
                $metrics = @(Get-Field $p 'metrics' @() | ForEach-Object {
                    [pscustomobject]@{ Category=(Get-Field $_ 'category'); Enabled=(Get-Field $_ 'enabled'); TimeGrain=(Get-Field $_ 'timeGrain'); RetentionPolicy=(Get-Field $_ 'retentionPolicy') }
                })
                $workspace = [string](Get-Field $p 'workspaceId' '')
                $data.diagnostics.Add([pscustomobject]@{
                    ResourceId=$setting.id; SourceResourceId=$id; WorkspaceId=$workspace
                    Logs=$logs; Metrics=$metrics; LogAnalyticsDestinationType=(Get-Field $p 'logAnalyticsDestinationType')
                    StorageAccountId=(Get-Field $p 'storageAccountId'); EventHubAuthorizationRuleId=(Get-Field $p 'eventHubAuthorizationRuleId'); EventHubName=(Get-Field $p 'eventHubName')
                })
                $enabled = @($logs + $metrics | Where-Object Enabled).Count -gt 0
                Add-Repoint $workspace $setting.id 'DiagnosticSetting' '$.properties.workspaceId' `
                    'Review destination workspaceId and retain intended enabled categories/categoryGroups and metrics' `
                    "Any category enabled: $enabled. Resource and subscription Activity Log settings are distinct; verify category support and duplicate ingestion."
            }
        }
        $apps = Read-List $client "/subscriptions/$sub/providers/Microsoft.Insights/components?api-version=2020-02-02" 'ApplicationInsights' $sub
        foreach ($app in $apps.Items) {
            $p = $app.properties
            $workspace = [string](Get-Field $p 'WorkspaceResourceId' '')
            $data.applicationInsights.Add([pscustomobject]@{
                ResourceId=$app.id; WorkspaceId=$workspace; ApplicationType=(Get-Field $p 'Application_Type'); IngestionMode=(Get-Field $p 'IngestionMode')
            })
            Add-Repoint $workspace $app.id 'ApplicationInsights' '$.properties.WorkspaceResourceId' `
                'Review workspace-based Application Insights link; preserve component and validate supported workspace change' `
                'This link is not app writer proof. Instrumentation keys and connection strings are not exported; SDK/external app configuration remains owner review.'
            if (-not $workspace) { Add-Coverage $app.id 'ApplicationInsightsWorkspaceLink' 'Unknown' 200 'NoWorkspaceLink' 0 'Classic or unlinked component; manual migration review.' }
        }
        $dependencyLists = @(
            @{Kind='ScheduledQueryRule'; Type='Microsoft.Insights/scheduledQueryRules'; Version='2023-12-01'},
            @{Kind='MetricAlert'; Type='Microsoft.Insights/metricAlerts'; Version='2018-03-01'},
            @{Kind='Workbook'; Type='Microsoft.Insights/workbooks'; Version='2022-04-01'},
            @{Kind='Solution'; Type='Microsoft.OperationsManagement/solutions'; Version='2015-11-01-preview'}
        )
        foreach ($dependency in $dependencyLists) {
            $dependencyPath = "/subscriptions/$sub/providers/$($dependency.Type)?api-version=$($dependency.Version)"
            if ($dependency.Kind -eq 'Workbook') { $dependencyPath += '&kind=shared' }
            $list = Read-List $client $dependencyPath $dependency.Kind $sub
            foreach ($item in $list.Items) {
                $full = $item
                if ($dependency.Kind -eq 'Workbook') {
                    $detail = Read-Object $client "$($item.id)?api-version=$($dependency.Version)&canFetchContent=true" 'WorkbookContentReferences' $item.id
                    if ($detail.Ok) { $full = $detail.Body } else { continue }
                }
                $refs = @(Get-WorkspaceReferences (Get-Field $full 'properties') $data.workspaces.ToArray() '$.properties')
                if (-not $refs.Count) {
                    $data.dependencies.Add([pscustomobject]@{
                        ResourceId=$full.id; Kind=$dependency.Kind; Name=$full.name; WorkspaceId=''
                        ReferencePath=''; Match='No literal selected-workspace ID/GUID found; NOT proof of independence'; Enabled=(Get-Field $full.properties 'enabled')
                    })
                }
                foreach ($ref in $refs) {
                    $data.dependencies.Add([pscustomobject]@{
                        ResourceId=$full.id; Kind=$dependency.Kind; Name=$full.name; WorkspaceId=$ref.WorkspaceId
                        ReferencePath=$ref.Path; Match=$(if ($ref.Exact) {'ExactValue'} else {'EmbeddedLiteral'})
                        Enabled=(Get-Field $full.properties 'enabled')
                    })
                    Add-Repoint $ref.WorkspaceId $full.id $dependency.Kind $ref.Path `
                        'Review/recreate dependent configuration and update scope/query/workbook references as appropriate' `
                        'Dependency, not ingestion writer. Serialized workbook content needs manual parsing/editing. Names, parameters, functions and dynamic references can be missed.'
                }
            }
        }
    }
    $knownRuleIds = @($data.dcrs | ForEach-Object ResourceId)
    foreach ($association in $data.associations) {
        if ($association.DcrId -and $association.DcrId -notin $knownRuleIds) {
            Add-Coverage $association.DcrId 'AssociatedDCRDefinition' 'Unknown' 0 'DCRNotDiscovered' 0 `
                'Association found, but rule definition/destination was inaccessible or outside selected subscriptions; obtain owner review.'
        }
    }
    # Add resource-level evidence without promoting resource attribution into producer identity.
    $configuredPairs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($map in $data.repointMap) {
        $candidateIds = @()
        if ($map.ConfigKind -eq 'DiagnosticSetting') {
            $candidateIds = @($data.diagnostics | Where-Object ResourceId -EQ $map.ConfigResourceId | ForEach-Object SourceResourceId)
        } elseif ($map.ConfigKind -eq 'DCR') {
            $candidateIds = @($data.associations | Where-Object DcrId -EQ $map.ConfigResourceId | ForEach-Object AssociatedResourceId)
        } elseif ($map.ConfigKind -eq 'ApplicationInsights') { $candidateIds = @($map.ConfigResourceId) }
        foreach ($candidateId in $candidateIds) {
            if ($candidateId) { $null = $configuredPairs.Add("$($map.WorkspaceId)|$candidateId") }
        }
        $matched = @($data.sources | Where-Object { $_.WorkspaceId -ieq $map.WorkspaceId -and $_.ResourceId -in $candidateIds })
        $map.ObservedResourceGroups = $matched.Count
        if ($matched.Count) {
            $map.Evidence = 'Configured + observed resource attribution (not writer proof)'
        } else {
            $map.ObservationScope = 'No matching returned resource aggregate; may be inactive, identity-missing, excluded, partial, inaccessible or externally pushed'
        }
    }
    foreach ($group in ($data.sources | Group-Object WorkspaceId,ResourceId,SubscriptionId,Host)) {
        $row = $group.Group[0]
        if (-not $row.ResourceId -or -not $configuredPairs.Contains("$($row.WorkspaceId)|$($row.ResourceId)")) {
            Add-Repoint $row.WorkspaceId '' 'UnresolvedObservedSource' '' `
                'Identify producer and owner before selecting an exact configuration object; no destination change inferred' `
                "ResourceId=$($row.ResourceId); SubscriptionId=$($row.SubscriptionId); Computer=$($row.Host). Could be external/API/agent or outside discovery scope." 'Observed attribution only; configuration unknown'
        }
    }
    Add-Coverage 'All' 'ScopeLimitations' 'NotAttempted' 0 'ManualReviewRequired' 0 `
        'External push writers, Entra tenant diagnostics, unlisted child resources, inaccessible/out-of-scope subscriptions, resource-context/dynamic queries, legacy agent machine settings, private links, Sentinel connectors and automation require separate owner discovery.'
} catch {
    Add-Coverage 'Run' 'UnexpectedFailure' 'Unknown' 0 'RunAborted' 0 'Partial exports preserved. Rerun after local troubleshooting; error messages intentionally omitted.'
    throw
} finally {
    foreach ($row in @(New-WorkspaceSummary $data.workspaces.ToArray() $data.usage.ToArray() $data.sources.ToArray() `
        $data.dcrs.ToArray() $data.diagnostics.ToArray() $data.applicationInsights.ToArray() `
        $data.workspaceLinks.ToArray() $data.dependencies.ToArray() $data.coverage.ToArray() ([bool]$ControlPlaneOnly))) {
        $data.workspaceSummary.Add($row)
    }
    foreach ($row in @(New-WorkspaceSenderSummary $data.workspaces.ToArray() $data.sources.ToArray() `
        $data.dcrs.ToArray() $data.associations.ToArray() $data.diagnostics.ToArray() $data.applicationInsights.ToArray())) {
        $data.workspaceSenders.Add($row)
    }
    Export-All
    Export-WorkspaceAssessmentHtml (Join-Path $OutputDirectory 'WorkspaceAssessment.html') `
        $data.workspaceSummary.ToArray() $data.workspaceSenders.ToArray() $data.usage.ToArray() `
        $data.coverage.ToArray() $start $end $subscriptions ([bool]$ControlPlaneOnly)
    $manifest = [ordered]@{
        ToolkitVersion='1.2.0'; StartedWindowUtc=$start.ToString('o'); EndedWindowUtc=$end.ToString('o')
        ExportedUtc=[datetime]::UtcNow.ToString('o'); SubscriptionIds=$subscriptions
        WorkspaceFilter=$WorkspaceResourceId; ExtraResourceIds=$ExtraResourceId; Environment=$environment.Name
        ArmEndpoint=$arm; QueryEndpoint=$QueryEndpoint; QueryAudience=$QueryAudience
        LookbackDays=$LookbackDays; MaxSourceGroups=$MaxSourceGroups; MaxTableQueriesPerWorkspace=$MaxTableQueries
        AllowExpensiveScan=[bool]$AllowExpensiveScan; ControlPlaneOnly=[bool]$ControlPlaneOnly; TableFilter=$TableName
        Warnings='Read coverage first. Complete means that request completed, not tenant-wide discovery. Configured/observed correlation is not writer proof.'
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDirectory 'manifest.json') -Encoding utf8
    if ($null -ne $initialContext) {
        try { $null = Set-AzContext -Context $initialContext -Scope Process -ErrorAction Stop }
        catch { Write-Warning 'Could not restore the process Az context.' }
    }
}
Write-Host "Read-only inventory exported to $OutputDirectory. Open WorkspaceAssessment.html; use coverage.csv for request-level gaps."
