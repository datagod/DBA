#Requires -Version 5.1
<#
.SYNOPSIS
  Run a SQL query with a SQL login, process the result set, and post a summary to Microsoft Teams.

.DESCRIPTION
  Intended for a workstation that can reach SQL Server and the Teams Workflows webhook URL
  (HTTPS). Does not use Database Mail / SMTP, so it still works when outbound mail is broken.

  Edit the CONFIG values below (SQLServerInstance, Database, UserId, WebhookUrl). PowerShell
  requires param() before any other code, so CONFIG sits immediately under the param block.
  Command-line parameters override CONFIG when supplied.

  Create the webhook in Teams: channel ... -> Workflows -> "Send webhook alerts to a channel"
  (or "Post to a channel when a webhook request is received"). Copy the URL.

  Default query checks EmailQueue backlog and Database Mail unsent/failed items. Pass -Query
  (or -QueryFile) for any other check. By default a Teams message is posted only when the
  result set has at least one row (use -AlwaysPost to send even when empty).

.EXAMPLE
  # After filling CONFIG below:
  .\QueryAndPostToTeams.ps1

.EXAMPLE
  .\QueryAndPostToTeams.ps1 -QueryFile 'C:\Alerts\CheckBlocked.sql' -AlwaysPost

.NOTES
  Author: Bill McEvoy
  Date:   September 11, 2026
  Revised: September 11, 2026 — CONFIG defaults at top (SQLServerInstance, UserId, WebhookUrl)
  Requires: System.Data.SqlClient (built into Windows PowerShell 5.1 / .NET Framework)
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string] $ServerInstance,

    [Parameter(Mandatory = $false)]
    [string] $Database,

    [Parameter(Mandatory = $false)]
    [string] $SqlLogin,

    [Parameter(Mandatory = $false)]
    [SecureString] $SqlPassword,

    [Parameter(Mandatory = $false)]
    [string] $TeamsWebhookUrl,

    [Parameter(Mandatory = $false)]
    [string] $Query,

    [Parameter(Mandatory = $false)]
    [string] $QueryFile,

    [Parameter(Mandatory = $false)]
    [switch] $AlwaysPost
)

#==============================================================================
# CONFIG — edit these on the workstation. Do not commit real secrets to git.
# Parameters override these when you pass them on the command line.
#==============================================================================
$SQLServerInstance = 'YOUR_SQL_INSTANCE'   # e.g. SQLPROD01 or SQLPROD01\INST1
$DatabaseName      = 'DBA'                 # tool database / query context
$UserId            = 'YOUR_SQL_LOGIN'      # SQL authentication login
$WebhookUrl        = ''                    # Teams Workflows webhook URL (or set TEAMS_WEBHOOK_URL)
# Leave password unset here; you will be prompted unless -SqlPassword is passed.
#==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Apply CONFIG when a parameter was omitted / blank
if ([string]::IsNullOrWhiteSpace($ServerInstance)) {
    $ServerInstance = $SQLServerInstance
}
if ([string]::IsNullOrWhiteSpace($Database)) {
    $Database = $DatabaseName
}
if ([string]::IsNullOrWhiteSpace($SqlLogin)) {
    $SqlLogin = $UserId
}
if ([string]::IsNullOrWhiteSpace($TeamsWebhookUrl)) {
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        $TeamsWebhookUrl = $WebhookUrl
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:TEAMS_WEBHOOK_URL)) {
        $TeamsWebhookUrl = $env:TEAMS_WEBHOOK_URL
    }
}

if ([string]::IsNullOrWhiteSpace($ServerInstance) -or $ServerInstance -eq 'YOUR_SQL_INSTANCE') {
    throw 'Set $SQLServerInstance in the CONFIG block (or pass -ServerInstance).'
}
if ([string]::IsNullOrWhiteSpace($SqlLogin) -or $SqlLogin -eq 'YOUR_SQL_LOGIN') {
    throw 'Set $UserId in the CONFIG block (or pass -SqlLogin).'
}
if ($null -eq $SqlPassword) {
    $SqlPassword = Read-Host -AsSecureString -Prompt "SQL password for $SqlLogin"
}

#------------------------------------------------------------------------------
# Default query: mail backlog / stuck Database Mail (tool DB + msdb)
# Customize thresholds in the WHERE clause as needed.
#------------------------------------------------------------------------------
$DefaultMailHealthQuery = @"
SET NOCOUNT ON;

DECLARE @QueuedBacklogThreshold int = 100;
DECLARE @UnsentThreshold        int = 50;
DECLARE @FailedLastHours        int = 1;
DECLARE @FailedThreshold        int = 10;
DECLARE @StuckProcessingMinutes int = 30;
DECLARE @Now                    datetime = GETDATE();

;WITH Signals AS
(
    -- Custom EmailQueue: queued
    SELECT
        Finding   = N'QUEUE_BACKLOG',
        Severity  = CASE WHEN COUNT(*) >= 10000 THEN N'CRITICAL'
                         WHEN COUNT(*) >= 1000  THEN N'HIGH'
                         ELSE N'MEDIUM' END,
        Detail    = N'EmailQueue StatusID=0 (queued) count = '
                    + CONVERT(nvarchar(20), COUNT(*)),
        Metric    = COUNT(*)
      FROM dbo.EmailQueue WITH (NOLOCK)
     WHERE StatusID = 0
     HAVING COUNT(*) >= @QueuedBacklogThreshold

    UNION ALL

    -- Custom EmailQueue: stuck processing
    SELECT
        Finding   = N'QUEUE_STUCK_PROCESSING',
        Severity  = N'HIGH',
        Detail    = N'EmailQueue StatusID=1 older than '
                    + CONVERT(nvarchar(10), @StuckProcessingMinutes)
                    + N' minutes: '
                    + CONVERT(nvarchar(20), COUNT(*)),
        Metric    = COUNT(*)
      FROM dbo.EmailQueue WITH (NOLOCK)
     WHERE StatusID = 1
       AND ISNULL(DateUpdated, DateCreated) < DATEADD(MINUTE, -@StuckProcessingMinutes, @Now)
     HAVING COUNT(*) > 0

    UNION ALL

    -- Database Mail unsent
    SELECT
        Finding   = N'DBMAIL_UNSENT',
        Severity  = CASE WHEN COUNT(*) >= 1000 THEN N'CRITICAL'
                         WHEN COUNT(*) >= 100  THEN N'HIGH'
                         ELSE N'MEDIUM' END,
        Detail    = N'sysmail_unsentitems count = '
                    + CONVERT(nvarchar(20), COUNT(*)),
        Metric    = COUNT(*)
      FROM msdb.dbo.sysmail_unsentitems WITH (NOLOCK)
     HAVING COUNT(*) >= @UnsentThreshold

    UNION ALL

    -- Database Mail failed recently
    SELECT
        Finding   = N'DBMAIL_FAILED',
        Severity  = N'HIGH',
        Detail    = N'sysmail_faileditems in last '
                    + CONVERT(nvarchar(10), @FailedLastHours)
                    + N' hour(s) = '
                    + CONVERT(nvarchar(20), COUNT(*)),
        Metric    = COUNT(*)
      FROM msdb.dbo.sysmail_faileditems WITH (NOLOCK)
     WHERE send_request_date >= DATEADD(HOUR, -@FailedLastHours, @Now)
     HAVING COUNT(*) >= @FailedThreshold

    UNION ALL

    -- Flatline: backlog exists but nothing sent recently
    SELECT
        Finding   = N'SEND_FLATLINE',
        Severity  = N'CRITICAL',
        Detail    = N'Queued EmailQueue > 0 and no StatusID=2 (sent) in last 30 minutes',
        Metric    = (SELECT COUNT(*) FROM dbo.EmailQueue WITH (NOLOCK) WHERE StatusID = 0)
      FROM (SELECT 1 AS x) AS d
     WHERE EXISTS (SELECT 1 FROM dbo.EmailQueue WITH (NOLOCK) WHERE StatusID = 0)
       AND NOT EXISTS (
             SELECT 1
               FROM dbo.EmailQueue WITH (NOLOCK)
              WHERE StatusID = 2
                AND ISNULL(DateUpdated, DateCreated) >= DATEADD(MINUTE, -30, @Now)
           )
)
SELECT Finding, Severity, Detail, Metric
  FROM Signals
 ORDER BY
    CASE Severity
        WHEN N'CRITICAL' THEN 1
        WHEN N'HIGH'     THEN 2
        WHEN N'MEDIUM'   THEN 3
        ELSE 4
    END,
    Metric DESC;
"@

function Get-PlainPassword {
    param([SecureString] $SecurePassword)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-SqlQueryText {
    if ($QueryFile) {
        if (-not (Test-Path -LiteralPath $QueryFile)) {
            throw "Query file not found: $QueryFile"
        }
        return Get-Content -LiteralPath $QueryFile -Raw -Encoding UTF8
    }
    if ($Query) {
        return $Query
    }
    return $DefaultMailHealthQuery
}

function Invoke-SqlQuery {
    param(
        [string] $Server,
        [string] $Db,
        [string] $User,
        [string] $Password,
        [string] $SqlText
    )

    Add-Type -AssemblyName System.Data | Out-Null

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source']              = $Server
    $builder['Initial Catalog']          = $Db
    $builder['User ID']                  = $User
    $builder['Password']                 = $Password
    $builder['Encrypt']                  = $true
    $builder['TrustServerCertificate']   = $true
    $builder['Connect Timeout']          = 30
    $builder['Application Name']         = 'QueryAndPostToTeams'

    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $command    = $connection.CreateCommand()
    $command.CommandText    = $SqlText
    $command.CommandTimeout = 120

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table   = New-Object System.Data.DataTable

    try {
        $connection.Open()
        [void]$adapter.Fill($table)
    }
    finally {
        if ($connection.State -ne 'Closed') { $connection.Close() }
        $connection.Dispose()
        $command.Dispose()
        $adapter.Dispose()
    }

    return $table
}

function Format-TeamsText {
    param(
        [System.Data.DataTable] $Table,
        [string] $Server,
        [string] $Db
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SQL alert from workstation")
    $lines.Add("Server: $Server")
    $lines.Add("Database: $Db")
    $lines.Add("Time: $stamp")
    $lines.Add("")

    if ($Table.Rows.Count -eq 0) {
        $lines.Add("Query returned 0 rows (no findings).")
        return ($lines -join "`n")
    }

    $lines.Add("Findings: $($Table.Rows.Count)")
    $lines.Add("")

    $colNames = @($Table.Columns | ForEach-Object { $_.ColumnName })
    $i = 0
    foreach ($row in $Table.Rows) {
        $i++
        $parts = foreach ($c in $colNames) {
            $val = $row[$c]
            if ($null -eq $val -or [DBNull]::Value.Equals($val)) { $val = '' }
            "${c}=$val"
        }
        $lines.Add("$i. " + ($parts -join ' | '))
    }

    return ($lines -join "`n")
}

function Send-TeamsWebhook {
    param(
        [string] $WebhookUrl,
        [string] $Text
    )

    # Workflows "Send webhook alerts to a channel" accepts MessageCard-style or simple text.
    # Use a MessageCard payload that works with both classic and Workflows webhooks.
    $payload = @{
        '@type'      = 'MessageCard'
        '@context'   = 'http://schema.org/extensions'
        summary      = 'SQL Server alert'
        themeColor   = 'FF0000'
        title        = 'SQL Server alert'
        text         = $Text
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress

    $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
    return $response
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($TeamsWebhookUrl) -and -not $WhatIfPreference) {
    throw 'Set \$WebhookUrl in the CONFIG block (or pass -TeamsWebhookUrl / TEAMS_WEBHOOK_URL).'
}

$sqlText = Get-SqlQueryText
Write-Host "Connecting to $ServerInstance / $Database as $SqlLogin ..."

$plain = Get-PlainPassword -SecurePassword $SqlPassword
try {
    $results = Invoke-SqlQuery -Server $ServerInstance -Db $Database -User $SqlLogin -Password $plain -SqlText $sqlText
}
finally {
    $plain = $null
}

Write-Host "Rows returned: $($results.Rows.Count)"

if ($results.Rows.Count -eq 0 -and -not $AlwaysPost) {
    Write-Host 'No findings and -AlwaysPost not set. Skipping Teams post.'
    return
}

$messageText = Format-TeamsText -Table $results -Server $ServerInstance -Db $Database
Write-Host "----- Teams message -----"
Write-Host $messageText
Write-Host "-------------------------"

if ($WhatIfPreference) {
    Write-Host 'WhatIf: not posting to Teams.'
    return
}

if ($PSCmdlet.ShouldProcess($TeamsWebhookUrl, 'POST Teams webhook')) {
    $null = Send-TeamsWebhook -WebhookUrl $TeamsWebhookUrl -Text $messageText
    Write-Host 'Posted to Teams.'
}
