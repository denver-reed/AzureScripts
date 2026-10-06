#requires -Version 7.0
Set-StrictMode -Version 3.0

function Get-Field {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Keys -contains $Name) { return $Object[$Name] }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function ConvertTo-CompactJson {
    param($Value)
    ConvertTo-Json -InputObject $Value -Depth 80 -Compress
}

function New-InventoryClient {
    param($Context, [string]$ArmEndpoint, [string]$QueryEndpoint, [string]$QueryAudience,
          [int]$MaxRetries = 5, [int]$TimeoutSeconds = 180)
    [pscustomobject]@{
        Context = $Context; ArmEndpoint = $ArmEndpoint.TrimEnd('/')
        QueryEndpoint = $QueryEndpoint.TrimEnd('/'); QueryAudience = $QueryAudience
        MaxRetries = $MaxRetries; TimeoutSeconds = $TimeoutSeconds
        Tokens = @{}; Transport = $null; Sleep = { param($Seconds) Start-Sleep -Seconds $Seconds }
    }
}

function Invoke-InventoryHttp {
    param($Client, [ValidateSet('GET','POST')][string]$Method = 'GET',
          [string]$Uri, $Body = $null, [switch]$Query)
    $base = if ($Query) { $Client.QueryEndpoint } else { $Client.ArmEndpoint }
    $target = [uri]$Uri
    $allowed = [uri]$base
    if ($target.Scheme -ne 'https' -or $target.Authority -ne $allowed.Authority -or
        $target.UserInfo -or $target.Fragment) {
        return [pscustomobject]@{ Ok = $false; Status = 0; Code = 'UntrustedEndpoint'; Body = $null }
    }
    # The sole allowed POST is a read-only Log Analytics query.
    if ($Method -eq 'POST' -and (-not $Query -or $target.AbsolutePath -notmatch '^/v1/workspaces/[0-9a-f-]+/query$')) {
        throw 'Refusing a non-query POST.'
    }
    $audience = if ($Query) { $Client.QueryAudience } else { $Client.ArmEndpoint + '/' }
    for ($attempt = 0; $attempt -le $Client.MaxRetries; $attempt++) {
        $headers = @{}
        $status = 0
        $response = $null
        $code = 'TransportOrAuthenticationFailure'
        try {
            if ($null -ne $Client.Transport) {
                $mock = & $Client.Transport $Method $Uri $Body
                $status = $mock.Status
                $response = $mock.Body
                $headers = Get-Field $mock 'Headers' @{}
            } else {
                $cached = $Client.Tokens[$audience]
                if ($null -eq $cached -or $cached.ExpiresOn -le [datetimeoffset]::UtcNow.AddMinutes(5)) {
                    $cached = Get-AzAccessToken -ResourceUrl $audience -DefaultProfile $Client.Context -ErrorAction Stop
                    $Client.Tokens[$audience] = $cached
                }
                $token = if ($cached.Token -is [securestring]) {
                    [System.Net.NetworkCredential]::new('', $cached.Token).Password
                } else { [string]$cached.Token }
                $request = @{
                    Uri = $Uri; Method = $Method; Headers = @{ Authorization = "Bearer $token" }
                    TimeoutSec = $Client.TimeoutSeconds; SkipHttpErrorCheck = $true
                    StatusCodeVariable = 'status'; ResponseHeadersVariable = 'headers'
                    ErrorAction = 'Stop'; MaximumRedirection = 0
                }
                if ($null -ne $Body) {
                    $request.Body = ConvertTo-CompactJson $Body
                    $request.ContentType = 'application/json'
                }
                try { $response = Invoke-RestMethod @request }
                finally { $token = $null; $request.Headers.Clear() }
            }
            $errorObject = Get-Field $response 'error'
            if ($null -ne $errorObject) { $code = [string](Get-Field $errorObject 'code' 'ServiceError') }
            elseif ($status -ge 200 -and $status -lt 300) { $code = 'OK' }
            else { $code = "HTTP$status" }
            if ($status -ge 200 -and $status -lt 300) {
                return [pscustomobject]@{ Ok = $true; Status = $status; Code = $code; Body = $response }
            }
        } catch {
            # Exception/response messages can contain query text or identifiers; never export them.
            $code = 'TransportOrAuthenticationFailure'
        }
        if ($status -eq 401) { $Client.Tokens.Remove($audience) }
        $retryable = $status -in @(0,401,408,429,500,502,503,504)
        if (-not $retryable -or $attempt -eq $Client.MaxRetries) { break }
        $delay = [math]::Min(60, [math]::Pow(2, $attempt) + (Get-Random -Minimum 0 -Maximum 1000) / 1000)
        $retryAfter = Get-Field $headers 'Retry-After'
        if ($null -ne $retryAfter) {
            $seconds = 0
            $date = [datetimeoffset]::MinValue
            $value = [string](@($retryAfter)[0])
            if ([int]::TryParse($value, [ref]$seconds)) { $delay = [math]::Max($delay, $seconds) }
            elseif ([datetimeoffset]::TryParse($value, [ref]$date)) {
                $delay = [math]::Max($delay, ($date - [datetimeoffset]::UtcNow).TotalSeconds)
            }
        }
        & $Client.Sleep ([math]::Min(300, $delay))
    }
    [pscustomobject]@{ Ok = $false; Status = $status; Code = $code; Body = $null }
}

function Get-InventoryList {
    param($Client, [string]$Path)
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $uri = if ($Path.StartsWith('https://')) { $Path } else { $Client.ArmEndpoint + $Path }
    while ($uri) {
        if (-not $seen.Add($uri)) {
            return [pscustomobject]@{ Items = $items.ToArray(); Complete = $false; Status = 0; Code = 'PaginationCycle' }
        }
        $r = Invoke-InventoryHttp $Client -Uri $uri
        if (-not $r.Ok) {
            return [pscustomobject]@{ Items = $items.ToArray(); Complete = $false; Status = $r.Status; Code = $r.Code }
        }
        $values = Get-Field $r.Body 'value'
        if ($null -eq $r.Body -or $null -eq $r.Body.PSObject.Properties['value']) {
            return [pscustomobject]@{ Items = $items.ToArray(); Complete = $false; Status = $r.Status; Code = 'UnexpectedListEnvelope' }
        }
        foreach ($item in $values) { $items.Add($item) }
        $next = [string](Get-Field $r.Body 'nextLink' '')
        if (-not $next) { $next = [string](Get-Field $r.Body '@odata.nextLink' '') }
        $uri = if ($next.StartsWith('/')) { $Client.ArmEndpoint + $next } else { $next }
    }
    [pscustomobject]@{ Items = $items.ToArray(); Complete = $true; Status = 200; Code = 'OK' }
}

function Get-InventoryObject {
    param($Client, [string]$Path)
    Invoke-InventoryHttp $Client -Uri ($Client.ArmEndpoint + $Path)
}

function Invoke-InventoryQuery {
    param($Client, [string]$WorkspaceGuid, [string]$Kql, [int]$Days, [int]$RowLimit,
          [string]$Timespan = '')
    if (-not $Timespan) { $Timespan = "P${Days}D" }
    $r = Invoke-InventoryHttp $Client -Method POST -Query `
        -Uri "$($Client.QueryEndpoint)/v1/workspaces/$WorkspaceGuid/query" `
        -Body @{ query = $Kql; timespan = $Timespan }
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $r.Ok) {
        return [pscustomobject]@{ Rows = @(); Complete = $false; Status = $r.Status; Code = $r.Code }
    }
    $tables = @(Get-Field $r.Body 'tables' @())
    $primary = @($tables | Where-Object { (Get-Field $_ 'name') -eq 'PrimaryResult' })
    $complete = $null -eq (Get-Field $r.Body 'error')
    $code = if ($complete) { 'OK' } else { [string](Get-Field (Get-Field $r.Body 'error') 'code' 'PartialError') }
    if ($primary.Count -ne 1) { $complete = $false; $code = 'MissingPrimaryResult' }
    else {
        foreach ($row in $primary[0].rows) {
            $record = [ordered]@{}
            for ($i = 0; $i -lt $primary[0].columns.Count; $i++) { $record[$primary[0].columns[$i].name] = $row[$i] }
            $rows.Add([pscustomobject]$record)
        }
        if ($rows.Count -gt $RowLimit) {
            $complete = $false
            $code = if ($code -eq 'OK') { 'AggregateRowLimitExceeded' } else { "$code;AggregateRowLimitExceeded" }
        }
    }
    # Some API versions return query-status tables as well as a top-level partial error.
    foreach ($table in $tables) {
        if ((Get-Field $table 'name' '') -match '(?i)status|error') {
            $complete = $false
            $code = "$code;QueryStatusTableRequiresReview"
        }
    }
    [pscustomobject]@{
        Rows = @($rows | Select-Object -First $RowLimit)
        Complete = $complete; Status = $r.Status; Code = $code
    }
}

function New-SourceKql {
    param([string]$Table, [datetime]$Start, [datetime]$End, [int]$RowLimit)
    if ($Table -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid table identifier.' }
    $startText = $Start.ToUniversalTime().ToString('o')
    $endText = $End.ToUniversalTime().ToString('o')
    $take = $RowLimit + 1
    @"
['$Table']
| where TimeGenerated >= datetime($startText) and TimeGenerated < datetime($endText)
| extend ResourceId=tostring(column_ifexists('_ResourceId','')),
         SubscriptionId=tostring(column_ifexists('_SubscriptionId','')),
         Host=tostring(column_ifexists('Computer','')),
         Received=todatetime(column_ifexists('_TimeReceived',datetime(null))),
         Billable=tobool(column_ifexists('_IsBillable','')),
         BilledBytes=toreal(column_ifexists('_BilledSize',real(null)))
| extend IdentityStatus=iff(isempty(ResourceId) and isempty(SubscriptionId) and isempty(Host),'Unknown','AttributedRecord')
| summarize RecordCount=count(), LastEventUtc=max(TimeGenerated), LastArrivalUtc=max(Received),
            ArrivalKnownRecords=countif(isnotnull(Received)),
            BillabilityKnownRecords=countif(isnotnull(Billable)),
            BilledSizeKnownRecords=countif(isnotnull(BilledBytes)),
            BillableRecords=countif(Billable == true),
            KnownBillableBytes=sumif(BilledBytes, Billable == true and isnotnull(BilledBytes)),
            BillableBytesUnknownRecords=countif(Billable == true and isnull(BilledBytes))
    by ResourceId, SubscriptionId, Host, IdentityStatus
| order by RecordCount desc
| take $take
"@
}

function New-UsageKql {
    param([datetime]$Start, [datetime]$End, [int]$RowLimit)
    $startText = $Start.ToUniversalTime().ToString('o')
    $endText = $End.ToUniversalTime().ToString('o')
    $take = $RowLimit + 1
    @"
Usage
| where TimeGenerated >= datetime($startText) and TimeGenerated < datetime($endText)
| where StartTime < datetime($endText) and EndTime > datetime($startText)
| summarize Quantity=sum(Quantity), FirstBucketStartUtc=min(StartTime),
            LastBucketEndUtc=max(EndTime), BucketRecords=count()
    by DataType, Solution, IsBillable, QuantityUnit
| order by Quantity desc
| take $take
"@
}

function Get-PrioritizedInventoryTables {
    param([object[]]$Tables, [object[]]$UsageRows = @(), [string[]]$RequestedTables = @())
    $active = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $UsageRows) {
        $name = [string](Get-Field $row 'DataType')
        if ($name) { $null = $active.Add($name) }
    }
    $requested = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $RequestedTables) { if ($name) { $null = $requested.Add($name) } }
    @($Tables | Sort-Object `
        @{Expression={ if ($requested.Contains([string]$_.name)) { 0 } elseif ($active.Contains([string]$_.name)) { 1 } else { 2 } }}, `
        @{Expression={ [string]$_.name }})
}

function Get-WorkspaceReferences {
    param($Value, [object[]]$Workspaces, [string]$Path = '$', [int]$Depth = 0)
    if ($null -eq $Value -or $Depth -gt 50) { return }
    if ($Value -is [string]) {
        foreach ($w in $Workspaces) {
            $id = [string]$w.ResourceId
            $guid = [string]$w.CustomerId
            if (($id -and $Value.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($guid -and $Value.IndexOf($guid, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                [pscustomobject]@{ WorkspaceId = $id; Path = $Path; Exact = ($Value -ieq $id -or $Value -ieq $guid) }
            }
        }
    } elseif ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-WorkspaceReferences $Value[$key] $Workspaces "$Path.$key" ($Depth + 1) }
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $Value) { Get-WorkspaceReferences $item $Workspaces "$Path[$i]" ($Depth + 1); $i++ }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            Get-WorkspaceReferences $property.Value $Workspaces "$Path.$($property.Name)" ($Depth + 1)
        }
    }
}

function New-WorkspaceSummary {
    param(
        [object[]]$Workspaces,
        [object[]]$Usage = @(),
        [object[]]$Sources = @(),
        [object[]]$Dcrs = @(),
        [object[]]$Diagnostics = @(),
        [object[]]$ApplicationInsights = @(),
        [object[]]$WorkspaceLinks = @(),
        [object[]]$Dependencies = @(),
        [object[]]$Coverage = @(),
        [bool]$ControlPlaneOnly = $false
    )
    foreach ($workspace in $Workspaces) {
        $workspaceId = [string]$workspace.ResourceId
        $workspaceUsage = @($Usage | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceSources = @($Sources | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceDcrs = @($Dcrs | Where-Object {
            @((Get-Field $_ 'Destinations' @()) | Where-Object { [string](Get-Field $_ 'workspaceResourceId') -ieq $workspaceId }).Count -gt 0
        })
        $workspaceDiagnostics = @($Diagnostics | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceApps = @($ApplicationInsights | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceLinksForId = @($WorkspaceLinks | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceDependencies = @($Dependencies | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })
        $workspaceCoverage = @($Coverage | Where-Object {
            ([string]$_.Scope).StartsWith($workspaceId, [StringComparison]::OrdinalIgnoreCase)
        })
        $purpose = [System.Collections.Generic.List[string]]::new()
        if (@($workspaceLinksForId | Where-Object { (Get-Field $_ 'Kind') -eq 'SentinelOnboarding' }).Count) { $purpose.Add('Microsoft Sentinel') }
        if ($workspaceApps.Count) { $purpose.Add('Application Insights') }
        $solutionNames = @($workspaceDependencies | Where-Object { (Get-Field $_ 'Kind') -eq 'Solution' } | ForEach-Object Name | Sort-Object -Unique)
        foreach ($solutionName in $solutionNames) { $purpose.Add("Solution: $solutionName") }
        if ($workspaceDcrs.Count) { $purpose.Add('Azure Monitor Agent / DCR') }
        if ($workspaceDiagnostics.Count) { $purpose.Add('Azure diagnostics') }
        if (-not $purpose.Count) { $purpose.Add('No purpose identified from discovered configuration') }

        $topUsage = @($workspaceUsage | Sort-Object { [double](Get-Field $_ 'Quantity' 0) } -Descending | Select-Object -First 10)
        $activeTables = @($topUsage | ForEach-Object DataType | Where-Object { $_ } | Sort-Object -Unique)
        $activeSolutions = @($workspaceUsage | ForEach-Object Solution | Where-Object { $_ } | Sort-Object -Unique)
        $observedResources = @($workspaceSources | ForEach-Object ResourceId | Where-Object { $_ } | Sort-Object -Unique)
        $observedHosts = @($workspaceSources | ForEach-Object Host | Where-Object { $_ } | Sort-Object -Unique)
        $lastEvent = @($workspaceSources | ForEach-Object LastEventUtc | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
        $queryGaps = @($workspaceCoverage | Where-Object {
            $_.Operation -in @('UsageQuery','SourceQuery') -and $_.Status -in @('Unknown','Partial')
        })
        $dataStatus = if ($ControlPlaneOnly) { 'Not collected (control-plane-only run)' }
            elseif ($queryGaps.Count) { 'Partial or unknown; review coverage' }
            else { 'Collected' }
        $confidence = if ($ControlPlaneOnly) { 'Configuration only' }
            elseif ($queryGaps.Count) { 'Limited by query coverage' }
            elseif ($workspaceSources.Count) { 'Configured and observed attribution; sender identity not proven' }
            else { 'No observed source rows in the selected window' }

        [pscustomobject]@{
            WorkspaceName=$workspace.Name; WorkspaceId=$workspaceId; SubscriptionId=$workspace.SubscriptionId
            Location=$workspace.Location; RetentionInDays=$workspace.RetentionInDays
            Purpose=($purpose -join '; '); DataStatus=$dataStatus
            ActiveTables=($activeTables -join '; '); UsageSolutions=($activeSolutions -join '; ')
            ObservedResourceCount=$observedResources.Count; ObservedHostCount=$observedHosts.Count
            LastEventUtc=($lastEvent -join ''); DiagnosticSettingCount=$workspaceDiagnostics.Count
            DcrCount=$workspaceDcrs.Count; ApplicationInsightsCount=$workspaceApps.Count
            ConfiguredSenderCount=($workspaceDiagnostics.Count + $workspaceDcrs.Count + $workspaceApps.Count)
            DependencyCount=$workspaceDependencies.Count; QueryCoverageGapCount=$queryGaps.Count
            Confidence=$confidence
        }
    }
}

function Get-RecordCountSum {
    param([object[]]$Rows)
    [long]$total = 0
    foreach ($row in $Rows) { $total += [long](Get-Field $row 'RecordCount' 0) }
    $total
}

function New-WorkspaceSenderSummary {
    param(
        [object[]]$Workspaces,
        [object[]]$Sources = @(),
        [object[]]$Dcrs = @(),
        [object[]]$Associations = @(),
        [object[]]$Diagnostics = @(),
        [object[]]$ApplicationInsights = @()
    )
    foreach ($workspace in $Workspaces) {
        $workspaceId = [string]$workspace.ResourceId
        foreach ($setting in @($Diagnostics | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })) {
            $matched = @($Sources | Where-Object {
                [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId -and
                [string](Get-Field $_ 'ResourceId') -ieq [string](Get-Field $setting 'SourceResourceId')
            })
            [pscustomobject]@{
                WorkspaceName=$workspace.Name; WorkspaceId=$workspaceId; SenderType='Diagnostic setting'
                SenderName=([string]$setting.ResourceId -split '/')[-1]
                SourceResourceId=$setting.SourceResourceId; ConfigurationResourceId=$setting.ResourceId
                Tables=(@($matched | ForEach-Object Table | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
                RecordCount=(Get-RecordCountSum $matched)
                LastEventUtc=(@($matched | ForEach-Object LastEventUtc | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1) -join '')
                Evidence=$(if ($matched.Count) {'Configured destination + matching resource attribution'} else {'Configured destination only'})
                Confidence=$(if ($matched.Count) {'Likely relationship; not writer proof'} else {'Configuration only'})
                Review='Confirm enabled categories and whether this configuration is still required.'
            }
        }
        foreach ($rule in @($Dcrs | Where-Object {
            @((Get-Field $_ 'Destinations' @()) | Where-Object { [string](Get-Field $_ 'workspaceResourceId') -ieq $workspaceId }).Count -gt 0
        })) {
            $ruleAssociations = @($Associations |
                Where-Object { [string](Get-Field $_ 'DcrId') -ieq [string]$rule.ResourceId } |
                Group-Object { [string](Get-Field $_ 'AssociatedResourceId') } |
                ForEach-Object { $_.Group[0] })
            if (-not $ruleAssociations.Count) { $ruleAssociations = @([pscustomobject]@{AssociatedResourceId=''}) }
            foreach ($association in $ruleAssociations) {
                $sourceId = [string]$association.AssociatedResourceId
                $matched = @($Sources | Where-Object {
                    [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId -and $sourceId -and
                    [string](Get-Field $_ 'ResourceId') -ieq $sourceId
                })
                [pscustomobject]@{
                    WorkspaceName=$workspace.Name; WorkspaceId=$workspaceId; SenderType='Data collection rule'
                    SenderName=$rule.Name; SourceResourceId=$sourceId; ConfigurationResourceId=$rule.ResourceId
                    Tables=(@($matched | ForEach-Object Table | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
                    RecordCount=(Get-RecordCountSum $matched)
                    LastEventUtc=(@($matched | ForEach-Object LastEventUtc | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1) -join '')
                    Evidence=$(if ($matched.Count) {'Configured DCR association + matching resource attribution'} elseif ($sourceId) {'Configured DCR association only'} else {'Configured DCR destination; no association discovered'})
                    Confidence=$(if ($matched.Count) {'Likely relationship; not writer proof'} else {'Configuration only; direct API use can have no association'})
                    Review='Validate streams, transforms, associations, and direct Logs Ingestion API callers.'
                }
            }
        }
        foreach ($app in @($ApplicationInsights | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId })) {
            $matched = @($Sources | Where-Object {
                [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId -and
                [string](Get-Field $_ 'ResourceId') -ieq [string]$app.ResourceId
            })
            [pscustomobject]@{
                WorkspaceName=$workspace.Name; WorkspaceId=$workspaceId; SenderType='Application Insights'
                SenderName=([string]$app.ResourceId -split '/')[-1]
                SourceResourceId=$app.ResourceId; ConfigurationResourceId=$app.ResourceId
                Tables=(@($matched | ForEach-Object Table | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
                RecordCount=(Get-RecordCountSum $matched)
                LastEventUtc=(@($matched | ForEach-Object LastEventUtc | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1) -join '')
                Evidence=$(if ($matched.Count) {'Workspace link + matching resource attribution'} else {'Workspace link only'})
                Confidence=$(if ($matched.Count) {'Likely relationship; not SDK writer proof'} else {'Configuration only'})
                Review='Confirm the application owner and SDK connection configuration.'
            }
        }
        foreach ($group in @($Sources | Where-Object { [string](Get-Field $_ 'WorkspaceId') -ieq $workspaceId } | Group-Object ResourceId,SubscriptionId,Host)) {
            $sample = $group.Group[0]
            [pscustomobject]@{
                WorkspaceName=$workspace.Name; WorkspaceId=$workspaceId; SenderType='Observed attribution'
                SenderName=$(if ($sample.Host) {$sample.Host} elseif ($sample.ResourceId) {([string]$sample.ResourceId -split '/')[-1]} else {'Unknown identity'})
                SourceResourceId=$sample.ResourceId; ConfigurationResourceId=''
                Tables=(@($group.Group | ForEach-Object Table | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
                RecordCount=(Get-RecordCountSum $group.Group)
                LastEventUtc=(@($group.Group | ForEach-Object LastEventUtc | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1) -join '')
                Evidence='Observed record attribution'
                Confidence='Activity observed; attributed resource or host is not necessarily the authenticated writer'
                Review='Correlate with configured rows and confirm the owning team or external/API producer.'
            }
        }
    }
}

function Export-WorkspaceAssessmentHtml {
    param(
        [string]$Path,
        [object[]]$WorkspaceSummary,
        [object[]]$WorkspaceSenders = @(),
        [object[]]$Usage = @(),
        [object[]]$Coverage = @(),
        [datetime]$WindowStartUtc,
        [datetime]$WindowEndUtc,
        [string[]]$SubscriptionIds = @(),
        [bool]$ControlPlaneOnly = $false
    )
    function ConvertTo-AssessmentHtmlText($Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    $summaryRows = foreach ($workspace in $WorkspaceSummary) {
        $dataClass = if ($workspace.DataStatus -eq 'Collected') { 'good' } elseif ($ControlPlaneOnly) { 'neutral' } else { 'warn' }
        @"
<tr data-filter-row><td><strong>$(ConvertTo-AssessmentHtmlText $workspace.WorkspaceName)</strong><span class="sub">$(ConvertTo-AssessmentHtmlText $workspace.Location)</span></td><td>$(ConvertTo-AssessmentHtmlText $workspace.Purpose)</td><td><span class="status $dataClass">$(ConvertTo-AssessmentHtmlText $workspace.DataStatus)</span></td><td class="num">$(ConvertTo-AssessmentHtmlText $workspace.ConfiguredSenderCount)</td><td class="num">$(ConvertTo-AssessmentHtmlText $workspace.ObservedResourceCount)</td><td>$(ConvertTo-AssessmentHtmlText $workspace.LastEventUtc)</td><td>$(ConvertTo-AssessmentHtmlText $workspace.Confidence)</td></tr>
"@
    }
    $workspaceSections = foreach ($workspace in $WorkspaceSummary) {
        $workspaceId = [string]$workspace.WorkspaceId
        $senders = @($WorkspaceSenders | Where-Object WorkspaceId -IEQ $workspaceId)
        $workspaceUsage = @($Usage | Where-Object WorkspaceId -IEQ $workspaceId | Sort-Object { [double](Get-Field $_ 'Quantity' 0) } -Descending)
        $senderRows = if ($senders.Count) { foreach ($sender in $senders) {
            @"
<tr data-filter-row><td><span class="kind">$(ConvertTo-AssessmentHtmlText $sender.SenderType)</span></td><td><strong>$(ConvertTo-AssessmentHtmlText $sender.SenderName)</strong><span class="sub path">$(ConvertTo-AssessmentHtmlText $sender.SourceResourceId)</span></td><td>$(ConvertTo-AssessmentHtmlText $sender.Tables)</td><td class="num">$(ConvertTo-AssessmentHtmlText $sender.RecordCount)</td><td>$(ConvertTo-AssessmentHtmlText $sender.LastEventUtc)</td><td>$(ConvertTo-AssessmentHtmlText $sender.Evidence)<span class="sub">$(ConvertTo-AssessmentHtmlText $sender.Confidence)</span></td><td>$(ConvertTo-AssessmentHtmlText $sender.Review)</td></tr>
"@
        } } else { '<tr><td colspan="7" class="empty">No configured or observed sender rows were returned.</td></tr>' }
        $usageRows = if ($workspaceUsage.Count) { foreach ($usageRow in $workspaceUsage) {
            @"
<tr data-filter-row><td><strong>$(ConvertTo-AssessmentHtmlText $usageRow.DataType)</strong></td><td>$(ConvertTo-AssessmentHtmlText $usageRow.Solution)</td><td>$(ConvertTo-AssessmentHtmlText $usageRow.IsBillable)</td><td class="num">$(ConvertTo-AssessmentHtmlText ([math]::Round([double]$usageRow.Quantity, 3)))</td><td>$(ConvertTo-AssessmentHtmlText $usageRow.QuantityUnit)</td><td>$(ConvertTo-AssessmentHtmlText $usageRow.Coverage)</td></tr>
"@
        } } else { '<tr><td colspan="6" class="empty">No Usage rows were returned for this workspace.</td></tr>' }
        @"
<article class="workspace" data-workspace-section>
    <div class="workspace-head"><div><h2>$(ConvertTo-AssessmentHtmlText $workspace.WorkspaceName)</h2><p>$(ConvertTo-AssessmentHtmlText $workspace.Purpose)</p></div><div class="workspace-meta">$(ConvertTo-AssessmentHtmlText $workspace.Location) · $(ConvertTo-AssessmentHtmlText $workspace.RetentionInDays) day retention</div></div>
    <div class="metrics"><div><span>Configured senders</span><strong>$(ConvertTo-AssessmentHtmlText $workspace.ConfiguredSenderCount)</strong></div><div><span>Observed resources</span><strong>$(ConvertTo-AssessmentHtmlText $workspace.ObservedResourceCount)</strong></div><div><span>Observed hosts</span><strong>$(ConvertTo-AssessmentHtmlText $workspace.ObservedHostCount)</strong></div><div><span>Query gaps</span><strong>$(ConvertTo-AssessmentHtmlText $workspace.QueryCoverageGapCount)</strong></div></div>
  <h3>Sender evidence</h3><div class="table-wrap"><table><thead><tr><th>Type</th><th>Sender or source</th><th>Tables</th><th>Records</th><th>Last event</th><th>Evidence</th><th>Review</th></tr></thead><tbody>$($senderRows -join '')</tbody></table></div>
  <h3>Recent usage</h3><div class="table-wrap"><table><thead><tr><th>Table</th><th>Solution</th><th>Billable</th><th>Quantity</th><th>Unit</th><th>Coverage</th></tr></thead><tbody>$($usageRows -join '')</tbody></table></div>
</article>
"@
    }
    $mode = if ($ControlPlaneOnly) { 'Configuration-only preview' } else { 'Configuration and recent activity' }
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Log Analytics Workspace Assessment</title>
<style>
:root{--ink:#17211b;--muted:#5c6a61;--paper:#f5f7f3;--surface:#fff;--line:#d7ddd8;--green:#176b4b;--green-soft:#e4f2eb;--amber:#8a5800;--amber-soft:#fff1d5;--blue:#205b88;--blue-soft:#e7f1f8;--red:#9b2c2c}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:14px/1.45 "Aptos","Segoe UI",sans-serif;letter-spacing:0}header{background:#183e31;color:#fff;padding:32px max(24px,calc((100vw - 1440px)/2)) 28px;border-bottom:5px solid #cf9f3e}header h1{font:700 30px/1.1 Georgia,serif;margin:0 0 9px;letter-spacing:0}header p{margin:0;color:#d7e8df;max-width:900px}.meta-line{display:flex;gap:20px;flex-wrap:wrap;margin-top:18px;font-size:13px}main{max-width:1440px;margin:0 auto;padding:24px}.toolbar{display:flex;align-items:center;gap:12px;margin-bottom:22px}.toolbar label{font-weight:700}.toolbar input{width:min(460px,100%);padding:10px 12px;border:1px solid #aeb8b0;background:#fff;border-radius:4px;font:inherit}.kpis{display:grid;grid-template-columns:repeat(5,minmax(140px,1fr));gap:12px;margin-bottom:28px}.kpi{background:var(--surface);border:1px solid var(--line);border-top:4px solid var(--green);padding:15px}.kpi span,.metrics span{display:block;color:var(--muted);font-size:12px;text-transform:uppercase;font-weight:700}.kpi strong{display:block;font:700 27px/1.2 Georgia,serif;margin-top:5px}.section{margin:30px 0}.section-title{display:flex;justify-content:space-between;align-items:end;border-bottom:2px solid var(--ink);padding-bottom:8px;margin-bottom:12px}.section-title h2{margin:0;font:700 22px Georgia,serif}.section-title p{margin:0;color:var(--muted)}.workspace{background:var(--surface);border:1px solid var(--line);border-left:5px solid var(--blue);padding:20px;margin:18px 0}.workspace-head{display:flex;justify-content:space-between;gap:18px;border-bottom:1px solid var(--line);padding-bottom:12px}.workspace h2{font:700 21px Georgia,serif;margin:0}.workspace-head p{margin:4px 0 0;color:var(--muted)}.workspace-meta{color:var(--muted);white-space:nowrap}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line);margin:15px 0}.metrics div{background:#f9faf8;padding:10px 12px}.metrics strong{font-size:20px}.workspace h3{font-size:14px;margin:20px 0 7px;text-transform:uppercase}.table-wrap{overflow:auto;border:1px solid var(--line)}table{border-collapse:collapse;width:100%;background:#fff}th{background:#edf1ed;color:#334139;text-align:left;font-size:12px;text-transform:uppercase;position:sticky;top:0}th,td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:#f8faf8}.num{text-align:right;font-variant-numeric:tabular-nums}.sub{display:block;color:var(--muted);font-size:12px;margin-top:3px}.path{max-width:420px;overflow-wrap:anywhere}.status,.kind{display:inline-block;padding:2px 7px;border-radius:3px;background:var(--blue-soft);color:var(--blue);font-size:12px;font-weight:700}.status.good{background:var(--green-soft);color:var(--green)}.status.warn{background:var(--amber-soft);color:var(--amber)}.status.neutral{background:#ecefec;color:#59635d}.empty{color:var(--muted);font-style:italic;text-align:center;padding:20px}.coverage-grid{display:grid;grid-template-columns:minmax(240px,1fr) minmax(540px,3fr);gap:18px}.note{border-left:4px solid #cf9f3e;background:#fff8e8;padding:12px 15px;margin:14px 0;color:#57431c}footer{max-width:1440px;margin:30px auto;padding:20px 24px 40px;color:var(--muted);border-top:1px solid var(--line)}[hidden]{display:none!important}@media(max-width:850px){header{padding:24px}main{padding:15px}.kpis{grid-template-columns:repeat(2,1fr)}.coverage-grid{grid-template-columns:1fr}.workspace-head{display:block}.workspace-meta{margin-top:8px}.metrics{grid-template-columns:repeat(2,1fr)}}@media print{body{background:#fff}.toolbar{display:none}.workspace{break-inside:avoid}.table-wrap{overflow:visible}header{background:#fff;color:#000;border-bottom:3px solid #000;padding:20px 0}header p,.meta-line{color:#333}main,footer{max-width:none;padding-left:0;padding-right:0}}
</style></head><body><header><h1>Log Analytics Workspace Assessment</h1><p>Customer-readable inventory of workspace purpose, configured data paths, recent activity, and collection gaps. Attribution identifies likely relationships; it does not prove the authenticated writer.</p><div class="meta-line"><span><strong>Mode:</strong> $(ConvertTo-AssessmentHtmlText $mode)</span><span><strong>Window:</strong> $(ConvertTo-AssessmentHtmlText $WindowStartUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) to $(ConvertTo-AssessmentHtmlText $WindowEndUtc.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC</span><span><strong>Subscriptions:</strong> $(ConvertTo-AssessmentHtmlText $SubscriptionIds.Count)</span></div></header><main>
<div class="toolbar"><label for="filter">Filter report</label><input id="filter" type="search" placeholder="Workspace, sender, table, solution, status…"></div>
<section class="section"><div class="section-title"><h2>Workspace overview</h2><p>Purpose is inferred from discovered configuration.</p></div><div class="table-wrap"><table><thead><tr><th>Workspace</th><th>Likely purpose</th><th>Data status</th><th>Senders</th><th>Observed resources</th><th>Last event</th><th>Confidence</th></tr></thead><tbody>$($summaryRows -join '')</tbody></table></div></section>
<section class="section"><div class="section-title"><h2>Workspace detail</h2><p>Configured relationships and observed evidence are shown separately.</p></div><div class="note"><strong>Interpretation:</strong> A configured destination can be inactive. An observed resource or host can describe record attribution without identifying the authenticated producer. Confirm owners before changing ingestion.</div>$($workspaceSections -join '')</section>
</main><footer>Generated locally by the Log Analytics Workspace Centralization Toolkit. This report contains resource names and operational metadata; handle it according to customer data policy.</footer>
<script>const q=document.getElementById('filter');q.addEventListener('input',()=>{const term=q.value.trim().toLowerCase();document.querySelectorAll('[data-filter-row]').forEach(row=>row.hidden=term&&!row.textContent.toLowerCase().includes(term));document.querySelectorAll('[data-workspace-section]').forEach(section=>{section.hidden=term&&!section.textContent.toLowerCase().includes(term)});});</script></body></html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding utf8
}

function Export-InventoryDataset {
    param([string]$Directory, [string]$Name, [object[]]$Rows, [string[]]$Columns)
    $jsonPath = Join-Path $Directory "$Name.json"
    ConvertTo-Json -InputObject @($Rows) -Depth 80 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $csvPath = Join-Path $Directory "$Name.csv"
    if (@($Rows).Count) {
        $flat = foreach ($row in $Rows) {
            $record = [ordered]@{}
            foreach ($column in $Columns) {
                $value = Get-Field $row $column
                if ($null -ne $value -and $value -isnot [string] -and $value -isnot [ValueType]) {
                    $value = ConvertTo-CompactJson $value
                }
                # Preserve exact strings in JSON; prevent formula execution when CSV is opened in Excel.
                if ($value -is [string] -and $value -match '^[\s]*[=+@\-\t\r]') { $value = "'" + $value }
                $record[$column] = $value
            }
            [pscustomobject]$record
        }
        $flat | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    } else {
        ($Columns | ForEach-Object { '"' + $_.Replace('"','""') + '"' }) -join ',' |
            Set-Content -LiteralPath $csvPath -Encoding utf8
    }
}

Export-ModuleMember -Function Get-Field,ConvertTo-CompactJson,New-InventoryClient,Invoke-InventoryHttp,`
    Get-InventoryList,Get-InventoryObject,Invoke-InventoryQuery,New-SourceKql,New-UsageKql,`
    Get-PrioritizedInventoryTables,Get-WorkspaceReferences,New-WorkspaceSummary,New-WorkspaceSenderSummary,`
    Export-WorkspaceAssessmentHtml,Export-InventoryDataset
