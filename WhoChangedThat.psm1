#Requires -Version 5.1
<#
.SYNOPSIS
    WhoChangedThat module - all business logic for the Who Changed That SQL Server tool.

.DESCRIPTION
    Contains all helper functions, SQL functions, and API route handlers used by
    Start-WhoChangedThat.ps1. Extracted into a module so functions can be unit-tested
    independently with Pester without spinning up the HTTP listener.

.NOTES
    Import in Start-WhoChangedThat.ps1 with:
        Import-Module "$PSScriptRoot\WhoChangedThat.psm1" -Force
#>

# Module-scoped connection - shared across all functions in this module
$script:SqlConnection = $null

# ─── UI Helpers ──────────────────────────────────────────────────────────────
function Write-Banner {
<#
.SYNOPSIS
    Writes the startup banner to the console.
#>
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  Who Changed That — SQL Server Version           ║" -ForegroundColor Cyan
    Write-Host "  ║  Powered by Kovoco Inc                           ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# ─── HTTP Response Helpers ───────────────────────────────────────────────────

function Send-JsonResponse {
    <#
    .SYNOPSIS Writes a JSON response to an HttpListenerResponse. #>
    param(
        $Response,
        $Data,
        [int]$StatusCode = 200
    )
    $json   = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode      = $StatusCode
    $Response.ContentType     = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.Headers.Add('Access-Control-Allow-Origin',  '*')
    $Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Send-HtmlResponse {
    <#
    .SYNOPSIS Writes an HTML response to an HttpListenerResponse. #>
    param(
        $Response,
        [string]$Html
    )
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.StatusCode      = 200
    $Response.ContentType     = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Get-RequestBody {
    <#
    .SYNOPSIS Reads and parses the JSON body from an HttpListenerRequest.
    .OUTPUTS PSCustomObject, or $null if the body is empty. #>
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $body   = $reader.ReadToEnd()
    $reader.Close()
    if ($body) { return $body | ConvertFrom-Json } else { return $null }
}

# ─── SQL Helpers ─────────────────────────────────────────────────────────────

function Invoke-SqlQuery {
    <#
    .SYNOPSIS Executes a SELECT query and returns results as an array of hashtables.
    .THROWS  "Not connected to SQL Server" when no open connection exists. #>
    param(
        [string]$Query,
        [string]$Database = $null
    )
    if (-not $script:SqlConnection -or $script:SqlConnection.State -ne 'Open') {
        throw 'Not connected to SQL Server'
    }
    if ($Database -and $Database -ne $script:SqlConnection.Database) {
        $script:SqlConnection.ChangeDatabase($Database)
    }
    $cmd                = $script:SqlConnection.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = 30
    $adapter            = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dataset            = New-Object System.Data.DataSet
    [void]$adapter.Fill($dataset)
    $results = @()
    if ($dataset.Tables.Count -gt 0) {
        foreach ($row in $dataset.Tables[0].Rows) {
            $obj = @{}
            foreach ($col in $dataset.Tables[0].Columns) {
                $val = $row[$col.ColumnName]
                if ($val -is [DBNull]) { $val = $null }
                $obj[$col.ColumnName] = $val
            }
            $results += $obj
        }
    }
    return $results
}

function Invoke-SqlNonQuery {
    <#
    .SYNOPSIS Executes a non-query SQL statement (CREATE, ALTER, DROP, etc.).
    .THROWS  "Not connected to SQL Server" when no open connection exists. #>
    param(
        [string]$Query,
        [string]$Database = $null
    )
    if (-not $script:SqlConnection -or $script:SqlConnection.State -ne 'Open') {
        throw 'Not connected to SQL Server'
    }
    if ($Database -and $Database -ne $script:SqlConnection.Database) {
        $script:SqlConnection.ChangeDatabase($Database)
    }
    $cmd                = $script:SqlConnection.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = 30
    [void]$cmd.ExecuteNonQuery()
}

# ─── API Route Handlers ───────────────────────────────────────────────────────

function Handle-TestConnection {
    <#
    .SYNOPSIS Opens and immediately closes a test connection. Does not persist it. #>
    param($Body)
    try {
        $connStr = "Server=$($Body.server),$($Body.port);User Id=$($Body.username);Password=$($Body.password);Connection Timeout=10;"
        if ($Body.encrypt)   { $connStr += 'Encrypt=True;' }
        if ($Body.trustCert) { $connStr += 'TrustServerCertificate=True;' }
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        $conn.Close()
        $conn.Dispose()
        return @{ success = $true }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-Connect {
    <#
    .SYNOPSIS Opens a persistent connection stored in $script:SqlConnection. #>
    param($Body)
    try {
        if ($script:SqlConnection -and $script:SqlConnection.State -eq 'Open') {
            $script:SqlConnection.Close()
            $script:SqlConnection.Dispose()
        }
        $db      = if ($Body.database) { $Body.database } else { 'master' }
        $connStr = "Server=$($Body.server),$($Body.port);Database=$db;User Id=$($Body.username);Password=$($Body.password);Connection Timeout=15;"
        if ($Body.encrypt)   { $connStr += 'Encrypt=True;' }
        if ($Body.trustCert) { $connStr += 'TrustServerCertificate=True;' }
        $script:SqlConnection = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $script:SqlConnection.Open()
        Write-Host " [CONNECTED] $($Body.server):$($Body.port) / $db" -ForegroundColor Green
        return @{ success = $true }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-Disconnect {
    <#
    .SYNOPSIS Closes and disposes the persistent connection. Safe to call when not connected. #>
    try {
        if ($script:SqlConnection -and $script:SqlConnection.State -eq 'Open') {
            $script:SqlConnection.Close()
            $script:SqlConnection.Dispose()
            $script:SqlConnection = $null
            Write-Host ' [DISCONNECTED]' -ForegroundColor Yellow
        }
        return @{ success = $true }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-GetDatabases {
    <#
    .SYNOPSIS Returns user database names from sys.databases (excludes system DBs). #>
    try {
        $results = Invoke-SqlQuery -Query @"
SELECT name
FROM   sys.databases
WHERE  state_desc = 'ONLINE'
  AND  name NOT IN ('master','tempdb','model','msdb')
ORDER  BY name
"@
        return @{ success = $true; data = @($results | ForEach-Object { $_.name }) }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-GetObjects {
    <#
    .SYNOPSIS Returns user objects (tables, views, procs, functions, triggers) for a database. #>
    param($Body)
    try {
        $results = Invoke-SqlQuery -Database $Body.database -Query @"
SELECT s.name AS schema_name,
       o.name AS object_name,
       o.type_desc AS object_type,
       s.name + '.' + o.name AS full_name
FROM   sys.objects  o
JOIN   sys.schemas  s ON o.schema_id = s.schema_id
WHERE  o.type IN ('U','V','P','FN','IF','TF','TR')
  AND  o.is_ms_shipped = 0
ORDER  BY o.type_desc, s.name, o.name
"@
        return @{ success = $true; data = $results }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-CreateAudit {
    <#
    .SYNOPSIS Creates a Server Audit and Database Audit Specification for a single object. #>
    param($Body)
    try {
        $db        = $Body.database
        $schema    = $Body.schemaName
        $obj       = $Body.objectName
        $path      = $Body.auditFilePath
        $auditName = "WCM_Audit_${db}_${schema}_${obj}"
        $specName  = "${auditName}_Spec"
        $safePath  = $path -replace "'", "''"

        Invoke-SqlNonQuery -Database 'master' -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName')
BEGIN
    CREATE SERVER AUDIT [$auditName]
    TO FILE (
        FILEPATH = '$safePath',
        MAXSIZE  = 100 MB,
        MAX_ROLLOVER_FILES = 10,
        RESERVE_DISK_SPACE = OFF
    )
    WITH (
        QUEUE_DELAY = 1000,
        ON_FAILURE  = CONTINUE
    );
END
"@

        Invoke-SqlNonQuery -Database 'master' -Query @"
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName' AND status_desc = 'STOPPED')
    ALTER SERVER AUDIT [$auditName] WITH (STATE = ON);
"@

        Invoke-SqlNonQuery -Database $db -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '$specName')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [$specName]
    FOR SERVER AUDIT [$auditName]
        ADD (SCHEMA_OBJECT_CHANGE_GROUP),
        ADD (INSERT  ON OBJECT::[$schema].[$obj] BY [public]),
        ADD (UPDATE  ON OBJECT::[$schema].[$obj] BY [public]),
        ADD (DELETE  ON OBJECT::[$schema].[$obj] BY [public]),
        ADD (SELECT  ON OBJECT::[$schema].[$obj] BY [public]),
        ADD (EXECUTE ON OBJECT::[$schema].[$obj] BY [public])
    WITH (STATE = ON);
END
"@

        Write-Host " [AUDIT CREATED] $auditName -> $path" -ForegroundColor Green
        return @{ success = $true; auditName = $auditName; specName = $specName }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-RemoveAudit {
    <#
    .SYNOPSIS Disables and drops the audit spec and server audit. Tolerates missing objects. #>
    param($Body)
    try {
        $db        = $Body.database
        $schema    = $Body.schemaName
        $obj       = $Body.objectName
        $auditName = "WCM_Audit_${db}_${schema}_${obj}"
        $specName  = "${auditName}_Spec"

        try {
            Invoke-SqlNonQuery -Database $db -Query @"
IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '$specName')
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION [$specName] WITH (STATE = OFF);
    DROP  DATABASE AUDIT SPECIFICATION [$specName];
END
"@
        } catch { <# spec may not exist - continue #> }

        try {
            Invoke-SqlNonQuery -Database 'master' -Query @"
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName')
BEGIN
    ALTER SERVER AUDIT [$auditName] WITH (STATE = OFF);
    DROP  SERVER AUDIT [$auditName];
END
"@
        } catch { <# audit may not exist - continue #> }

        Write-Host " [AUDIT REMOVED] $auditName" -ForegroundColor Yellow
        return @{ success = $true }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-ReadAudit {
    <#
    .SYNOPSIS Reads .sqlaudit files and returns filtered events for a specific object. #>
    param($Body)
    try {
        $schema   = $Body.schemaName
        $obj      = $Body.objectName
        $safePath = ($Body.auditFilePath) -replace "'", "''"

        $results = Invoke-SqlQuery -Database 'master' -Query @"
SELECT event_time,
       action_id,
       CASE action_id
           WHEN 'IN' THEN 'INSERT'
           WHEN 'UP' THEN 'UPDATE'
           WHEN 'DL' THEN 'DELETE'
           WHEN 'SL' THEN 'SELECT'
           WHEN 'EX' THEN 'EXECUTE'
           WHEN 'AL' THEN 'ALTER'
           WHEN 'CR' THEN 'CREATE'
           WHEN 'DR' THEN 'DROP'
           ELSE RTRIM(action_id)
       END AS action_name,
       succeeded,
       server_principal_name,
       database_principal_name,
       server_instance_name,
       database_name,
       schema_name,
       object_name,
       [statement],
       client_ip,
       application_name,
       host_name,
       session_id,
       transaction_id,
       class_type
FROM   sys.fn_get_audit_file('$safePath\*.sqlaudit', DEFAULT, DEFAULT)
WHERE  (
           (object_name = '$obj' AND schema_name = '$schema')
        OR (class_type IN ('OB','SC') AND [statement] LIKE '%$obj%')
       )
ORDER  BY event_time DESC
"@

        # Convert DateTimes to ISO 8601 strings so ConvertTo-Json doesn't mangle them
        $cleaned = @()
        foreach ($r in $results) {
            if ($r.event_time -is [DateTime]) {
                $r.event_time = $r.event_time.ToString('o')
            }
            $cleaned += $r
        }

        Write-Host " [AUDIT READ] $($cleaned.Count) events found" -ForegroundColor Cyan
        return @{ success = $true; data = $cleaned }
    }
    catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ─── Exports ─────────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Write-Banner'
    'Send-JsonResponse'
    'Send-HtmlResponse'
    'Get-RequestBody'
    'Invoke-SqlQuery'
    'Invoke-SqlNonQuery'
    'Handle-TestConnection'
    'Handle-Connect'
    'Handle-Disconnect'
    'Handle-GetDatabases'
    'Handle-GetObjects'
    'Handle-CreateAudit'
    'Handle-RemoveAudit'
    'Handle-ReadAudit'
)
