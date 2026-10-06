#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}

# Parse, but NEVER execute, the Azure inventory entry point.
foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1','.psm1'))) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $messages = @($errors | ForEach-Object Message) -join '; '
    Assert-True ($errors.Count -eq 0) ("PowerShell parser: " + $file.Name + ' ' + $messages)
}
Import-Module (Join-Path $PSScriptRoot 'LAInventory.Common.psm1') -Force
$client = New-InventoryClient $null 'https://management.azure.com' 'https://api.loganalytics.azure.com' 'https://api.loganalytics.io' 2 30
$client.Sleep = { param($Seconds) }

$state = [pscustomobject]@{ Count=0 }
$client.Transport = {
    param($Method,$Uri,$Body)
    $state.Count++
    if ($state.Count -eq 1) {
        [pscustomobject]@{Status=200; Body=('{"value":[{"id":"one"}],"nextLink":"https://management.azure.com/page2"}' | ConvertFrom-Json)}
    } else {
        [pscustomobject]@{Status=200; Body=('{"value":[{"id":"two"}]}' | ConvertFrom-Json)}
    }
}.GetNewClosure()
$r = Get-InventoryList $client '/page1'
Assert-True ($r.Complete -and $r.Items.Count -eq 2 -and $state.Count -eq 2) 'Paginate all list pages'

$client.Transport = { param($Method,$Uri,$Body) [pscustomobject]@{Status=200; Body=('{"value":[]}' | ConvertFrom-Json)} }
$r = Get-InventoryList $client '/empty'
Assert-True ($r.Complete -and $r.Items.Count -eq 0) 'Empty list is a successful zero, not an unknown envelope'

$state = [pscustomobject]@{ Count=0 }
$client.Transport = {
    param($Method,$Uri,$Body)
    $state.Count++
    if ($state.Count -eq 1) {
        [pscustomobject]@{Status=429; Headers=@{'Retry-After'='0'}; Body=('{"error":{"code":"Throttled"}}' | ConvertFrom-Json)}
    } else { [pscustomobject]@{Status=200; Body=('{"value":[]}' | ConvertFrom-Json)} }
}.GetNewClosure()
$r = Get-InventoryList $client '/retry'
Assert-True ($r.Complete -and $state.Count -eq 2) 'Retry 429'

$state = [pscustomobject]@{ Count=0 }
$client.Transport = {
    param($Method,$Uri,$Body)
    $state.Count++
    [pscustomobject]@{Status=403; Body=('{"error":{"code":"Forbidden"}}' | ConvertFrom-Json)}
}.GetNewClosure()
$r = Get-InventoryList $client '/denied'
Assert-True (-not $r.Complete -and $r.Status -eq 403 -and $state.Count -eq 1) '403 is unknown, never an empty success or retry loop'

$state = [pscustomobject]@{ Count=0 }
$client.Transport = {
    param($Method,$Uri,$Body)
    $state.Count++
    if ($state.Count -eq 1) {
        [pscustomobject]@{Status=200; Body=('{"value":[{"id":"retained"}],"nextLink":"/denied"}' | ConvertFrom-Json)}
    } else { [pscustomobject]@{Status=403; Body=('{"error":{"code":"Forbidden"}}' | ConvertFrom-Json)} }
}.GetNewClosure()
$r = Get-InventoryList $client '/partial'
Assert-True (-not $r.Complete -and $r.Items.Count -eq 1 -and $r.Items[0].id -eq 'retained') 'Keep earlier pages when a later page fails'

$state = [pscustomobject]@{ Count=0 }
$client.Transport = {
    param($Method,$Uri,$Body)
    $state.Count++
    [pscustomobject]@{Status=200; Body=('{"value":[],"nextLink":"https://untrusted.invalid/page"}' | ConvertFrom-Json)}
}.GetNewClosure()
$r = Get-InventoryList $client '/untrusted-next'
Assert-True (-not $r.Complete -and $r.Code -eq 'UntrustedEndpoint' -and $state.Count -eq 1) 'Never forward a token to a different nextLink host'

$client.Transport = {
    param($Method,$Uri,$Body)
    [pscustomobject]@{Status=200; Body=('{"value":[],"nextLink":"https://management.azure.com/cycle"}' | ConvertFrom-Json)}
}
$r = Get-InventoryList $client '/cycle'
Assert-True (-not $r.Complete -and $r.Code -eq 'PaginationCycle') 'Detect pagination cycles'

$client.Transport = {
    param($Method,$Uri,$Body)
    [pscustomobject]@{Status=200; Body=('{"tables":[{"name":"PrimaryResult","columns":[{"name":"RecordCount","type":"long"}],"rows":[[4]]}],"error":{"code":"PartialError","message":"Not exported"}}' | ConvertFrom-Json)}
}
$r = Invoke-InventoryQuery $client '00000000-0000-0000-0000-000000000001' 'Heartbeat | count' 7 10
Assert-True (-not $r.Complete -and $r.Rows.Count -eq 1 -and $r.Code -eq 'PartialError') 'HTTP 200 partial query retains aggregates but is not complete'

$client.Transport = {
    param($Method,$Uri,$Body)
    [pscustomobject]@{Status=200; Body=('{"tables":[{"name":"PrimaryResult","columns":[{"name":"RecordCount","type":"long"}],"rows":[[4],[3],[2]]}]}' | ConvertFrom-Json)}
}
$r = Invoke-InventoryQuery $client '00000000-0000-0000-0000-000000000001' 'Heartbeat | count' 7 2
Assert-True (-not $r.Complete -and $r.Rows.Count -eq 2 -and $r.Code -eq 'AggregateRowLimitExceeded') 'Sentinel extra aggregate detects result cap'

$blocked = $false
try { $null = Invoke-InventoryHttp $client -Method POST -Uri 'https://management.azure.com/not-a-query' }
catch { $blocked = $true }
Assert-True $blocked 'Non-query POST is refused'

$from = [datetime]'2026-09-10T00:00:00Z'
$to = [datetime]'2026-09-17T00:00:00Z'
$kql = New-SourceKql 'Heartbeat' $from $to 100
Assert-True ($kql -match 'take 101' -and $kql -notmatch '\bunion\b' -and $kql -match '_TimeReceived' -and $kql -match 'Unknown') 'Per-table bounded aggregate uses explicit unknown and optional arrival'
Assert-True ($kql -match 'BillabilityKnownRecords' -and $kql -match 'BillableBytesUnknownRecords') 'Missing billing metadata is measurable'
$blocked = $false
try { $null = New-SourceKql "Heartbeat']; union * //" $from $to 100 }
catch { $blocked = $true }
Assert-True $blocked 'Reject table-name KQL injection'
$usage = New-UsageKql $from $to 100
Assert-True ($usage -match 'sum\(Quantity\)' -and $usage -match 'QuantityUnit' -and $usage -notmatch 'Computer') 'Usage is bucket volume, not host inventory'
$orderedTables = @(Get-PrioritizedInventoryTables `
    @([pscustomobject]@{name='AInactive'},[pscustomobject]@{name='Heartbeat'},[pscustomobject]@{name='ZZRequested'}) `
    @([pscustomobject]@{DataType='Heartbeat'}) @('ZZRequested'))
Assert-True (($orderedTables.name -join ',') -eq 'ZZRequested,Heartbeat,AInactive') `
    'Requested and active Usage tables are queried before alphabetical fallback'

$summary = @(New-WorkspaceSummary `
    @([pscustomobject]@{ResourceId='/subscriptions/test/workspaces/main';Name='main';SubscriptionId='test';Location='eastus';RetentionInDays=30}) `
    @([pscustomobject]@{WorkspaceId='/subscriptions/test/workspaces/main';DataType='Heartbeat';Solution='LogManagement';Quantity=12}) `
    @([pscustomobject]@{WorkspaceId='/subscriptions/test/workspaces/main';ResourceId='/subscriptions/test/vm/a';Host='vm-a';LastEventUtc='2026-09-16T00:00:00Z'}) `
    @([pscustomobject]@{Destinations=@([pscustomobject]@{workspaceResourceId='/subscriptions/test/workspaces/main'})}) `
    @([pscustomobject]@{WorkspaceId='/subscriptions/test/workspaces/main'}) @() @() @() `
    @([pscustomobject]@{Scope='/subscriptions/test/workspaces/main';Operation='UsageQuery';Status='Complete'}))
Assert-True ($summary.Count -eq 1 -and $summary[0].Purpose -match 'DCR' -and
    $summary[0].Purpose -match 'diagnostics' -and $summary[0].ActiveTables -eq 'Heartbeat' -and
    $summary[0].ConfiguredSenderCount -eq 2 -and $summary[0].ObservedResourceCount -eq 1 -and
    $summary[0].DataStatus -eq 'Collected') 'Customer summary joins purpose, senders, usage and observed attribution'
$senders = @(New-WorkspaceSenderSummary `
    @([pscustomobject]@{ResourceId='/subscriptions/test/workspaces/main';Name='main'}) `
    @([pscustomobject]@{WorkspaceId='/subscriptions/test/workspaces/main';ResourceId='/subscriptions/test/vm/a';SubscriptionId='test';Host='vm-a';Table='Heartbeat';RecordCount=4;LastEventUtc='2026-09-16T00:00:00Z'}) `
    @([pscustomobject]@{ResourceId='/subscriptions/test/dcr/main';Name='main-dcr';Destinations=@([pscustomobject]@{workspaceResourceId='/subscriptions/test/workspaces/main'})}) `
    @([pscustomobject]@{DcrId='/subscriptions/test/dcr/main';AssociatedResourceId='/subscriptions/test/vm/a'}) @() @())
Assert-True (@($senders | Where-Object SenderType -EQ 'Data collection rule').Count -eq 1 -and
    @($senders | Where-Object SenderType -EQ 'Observed attribution').Count -eq 1 -and
    @($senders | Where-Object SenderType -EQ 'Data collection rule')[0].RecordCount -eq 4) `
    'Customer sender view separates configured relationships from observed attribution'

$workspace = [pscustomobject]@{
    ResourceId='/subscriptions/test/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/w'
    CustomerId='00000000-0000-0000-0000-000000000001'
}
$refs = @(Get-WorkspaceReferences ([pscustomobject]@{scopes=@($workspace.ResourceId); text="workspace('$($workspace.CustomerId)') | count"}) @($workspace))
Assert-True ($refs.Count -eq 2 -and @($refs | Where-Object Exact).Count -eq 1) 'Match exact and embedded references with paths'

$exportPath = Join-Path $PSScriptRoot ('selftest-output-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $exportPath
try {
    Export-InventoryDataset $exportPath 'empty' @() @('Name','Metadata')
    Assert-True ((Get-Content (Join-Path $exportPath 'empty.csv') -Raw).Trim() -eq '"Name","Metadata"') 'Empty CSV retains headers'
    Export-InventoryDataset $exportPath 'sample' @([pscustomobject]@{Name='=example'; Metadata=@{a=1}}) @('Name','Metadata')
    $csv = Import-Csv (Join-Path $exportPath 'sample.csv')
    $json = Get-Content (Join-Path $exportPath 'sample.json') -Raw | ConvertFrom-Json
    Assert-True ($csv.Name -eq "'=example" -and $json[0].Name -eq '=example') 'CSV formulas neutralized; JSON preserves exact original'
    $htmlPath = Join-Path $exportPath 'WorkspaceAssessment.html'
    Export-WorkspaceAssessmentHtml $htmlPath `
        @([pscustomobject]@{WorkspaceName='<main>';WorkspaceId='/workspaces/main';SubscriptionId='test';Location='eastus';RetentionInDays=30;Purpose='Diagnostics';DataStatus='Collected';ActiveTables='Heartbeat';UsageSolutions='LogManagement';ObservedResourceCount=1;ObservedHostCount=1;LastEventUtc='2026-09-16';DiagnosticSettingCount=1;DcrCount=0;ApplicationInsightsCount=0;ConfiguredSenderCount=1;DependencyCount=0;QueryCoverageGapCount=0;Confidence='Configured and observed'}) `
        @() @() @([pscustomobject]@{Status='Complete';Code='OK';Operation='UsageQuery'}) $from $to @('test') $false
    $html = Get-Content $htmlPath -Raw
    Assert-True ($html -match '<title>Log Analytics Workspace Assessment</title>' -and
        $html -match '&lt;main&gt;' -and $html -notmatch '<strong><main></strong>') `
        'HTML assessment is generated and Azure-derived text is encoded'
} finally { Remove-Item -LiteralPath $exportPath -Recurse -Force }
Write-Host "PASS: $passed offline assertions. No Azure calls made. No tenant integration testing."
