<#
.SYNOPSIS
    Who Changed That — SQL Server Version
    A Kovoco Inc tool to audit changes on a single SQL Server object.

.DESCRIPTION
    Starts a local HTTP server that serves the HTML UI and provides
    a REST API for SQL Server audit operations. No external dependencies
    required — uses built-in .NET SqlClient.

.NOTES
    Copy this folder to any Windows Server with PowerShell 5.1+ and run:
        .\Start-WhoChangedThat.ps1
    
    The browser will open automatically to the UI.
    Press Ctrl+C in the PowerShell window to stop the server.
#>

param(
    [int]$Port = 8642,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$script:SqlConnection = $null

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Who Changed That — SQL Server Version         ║" -ForegroundColor Cyan
    Write-Host "  ║   Powered by Kovoco Inc                         ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Send-JsonResponse {
    param($Response, $Data, [int]$StatusCode = 200)
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.Headers.Add('Access-Control-Allow-Origin', '*')
    $Response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Send-HtmlResponse {
    param($Response, [string]$Html)
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.StatusCode = 200
    $Response.ContentType = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Get-RequestBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if ($body) { return $body | ConvertFrom-Json } else { return $null }
}

function Invoke-SqlQuery {
    param([string]$Query, [string]$Database = $null)
    
    if (-not $script:SqlConnection -or $script:SqlConnection.State -ne 'Open') {
        throw "Not connected to SQL Server"
    }
    
    # Switch database if requested
    if ($Database -and $Database -ne $script:SqlConnection.Database) {
        $script:SqlConnection.ChangeDatabase($Database)
    }
    
    $cmd = $script:SqlConnection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 30
    
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dataset = New-Object System.Data.DataSet
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
    param([string]$Query, [string]$Database = $null)
    
    if (-not $script:SqlConnection -or $script:SqlConnection.State -ne 'Open') {
        throw "Not connected to SQL Server"
    }
    
    if ($Database -and $Database -ne $script:SqlConnection.Database) {
        $script:SqlConnection.ChangeDatabase($Database)
    }
    
    $cmd = $script:SqlConnection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 30
    [void]$cmd.ExecuteNonQuery()
}

# ─── API Route Handlers ──────────────────────────────────────────────────────

function Handle-TestConnection {
    param($Body)
    try {
        $connStr = "Server=$($Body.server),$($Body.port);User Id=$($Body.username);Password=$($Body.password);Connection Timeout=10;"
        if ($Body.encrypt) { $connStr += "Encrypt=True;" }
        if ($Body.trustCert) { $connStr += "TrustServerCertificate=True;" }
        
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        $conn.Close()
        $conn.Dispose()
        return @{ success = $true }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-Connect {
    param($Body)
    try {
        if ($script:SqlConnection -and $script:SqlConnection.State -eq 'Open') {
            $script:SqlConnection.Close()
            $script:SqlConnection.Dispose()
        }
        
        $db = if ($Body.database) { $Body.database } else { "master" }
        $connStr = "Server=$($Body.server),$($Body.port);Database=$db;User Id=$($Body.username);Password=$($Body.password);Connection Timeout=15;"
        if ($Body.encrypt) { $connStr += "Encrypt=True;" }
        if ($Body.trustCert) { $connStr += "TrustServerCertificate=True;" }
        
        $script:SqlConnection = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $script:SqlConnection.Open()
        
        Write-Host "  [CONNECTED] $($Body.server):$($Body.port) / $db" -ForegroundColor Green
        return @{ success = $true }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-Disconnect {
    try {
        if ($script:SqlConnection -and $script:SqlConnection.State -eq 'Open') {
            $script:SqlConnection.Close()
            $script:SqlConnection.Dispose()
            $script:SqlConnection = $null
            Write-Host "  [DISCONNECTED]" -ForegroundColor Yellow
        }
        return @{ success = $true }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-GetDatabases {
    try {
        $results = Invoke-SqlQuery -Query @"
            SELECT name FROM sys.databases
            WHERE state_desc = 'ONLINE'
              AND name NOT IN ('master','tempdb','model','msdb')
            ORDER BY name
"@
        return @{ success = $true; data = @($results | ForEach-Object { $_.name }) }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-GetObjects {
    param($Body)
    try {
        $results = Invoke-SqlQuery -Database $Body.database -Query @"
            SELECT
                s.name AS schema_name,
                o.name AS object_name,
                o.type_desc AS object_type,
                s.name + '.' + o.name AS full_name
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN ('U','V','P','FN','IF','TF','TR')
              AND o.is_ms_shipped = 0
            ORDER BY o.type_desc, s.name, o.name
"@
        return @{ success = $true; data = $results }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-CreateAudit {
    param($Body)
    try {
        $db = $Body.database
        $schema = $Body.schemaName
        $obj = $Body.objectName
        $path = $Body.auditFilePath
        $auditName = "WCM_Audit_${db}_${schema}_${obj}"
        $specName = "${auditName}_Spec"
        
        # Ensure we're on master for server-level audit
        Invoke-SqlNonQuery -Database "master" -Query @"
            IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName')
            BEGIN
                CREATE SERVER AUDIT [$auditName]
                TO FILE (
                    FILEPATH = '$($path -replace "'","''")',
                    MAXSIZE = 100 MB,
                    MAX_ROLLOVER_FILES = 10,
                    RESERVE_DISK_SPACE = OFF
                )
                WITH (
                    QUEUE_DELAY = 1000,
                    ON_FAILURE = CONTINUE
                );
            END
"@
        
        Invoke-SqlNonQuery -Database "master" -Query @"
            IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName' AND status_desc = 'STOPPED')
                ALTER SERVER AUDIT [$auditName] WITH (STATE = ON);
"@
        
        Invoke-SqlNonQuery -Database $db -Query @"
            IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '$specName')
            BEGIN
                CREATE DATABASE AUDIT SPECIFICATION [$specName]
                FOR SERVER AUDIT [$auditName]
                ADD (SCHEMA_OBJECT_CHANGE_GROUP),
                ADD (INSERT ON OBJECT::[$schema].[$obj] BY [public]),
                ADD (UPDATE ON OBJECT::[$schema].[$obj] BY [public]),
                ADD (DELETE ON OBJECT::[$schema].[$obj] BY [public]),
                ADD (SELECT ON OBJECT::[$schema].[$obj] BY [public]),
                ADD (EXECUTE ON OBJECT::[$schema].[$obj] BY [public])
                WITH (STATE = ON);
            END
"@
        
        Write-Host "  [AUDIT CREATED] $auditName -> $path" -ForegroundColor Green
        return @{ success = $true; auditName = $auditName; specName = $specName }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-RemoveAudit {
    param($Body)
    try {
        $db = $Body.database
        $schema = $Body.schemaName
        $obj = $Body.objectName
        $auditName = "WCM_Audit_${db}_${schema}_${obj}"
        $specName = "${auditName}_Spec"
        
        try {
            Invoke-SqlNonQuery -Database $db -Query @"
                IF EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = '$specName')
                BEGIN
                    ALTER DATABASE AUDIT SPECIFICATION [$specName] WITH (STATE = OFF);
                    DROP DATABASE AUDIT SPECIFICATION [$specName];
                END
"@
        } catch { <# spec may not exist #> }
        
        try {
            Invoke-SqlNonQuery -Database "master" -Query @"
                IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$auditName')
                BEGIN
                    ALTER SERVER AUDIT [$auditName] WITH (STATE = OFF);
                    DROP SERVER AUDIT [$auditName];
                END
"@
        } catch { <# audit may not exist #> }
        
        Write-Host "  [AUDIT REMOVED] $auditName" -ForegroundColor Yellow
        return @{ success = $true }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Handle-ReadAudit {
    param($Body)
    try {
        $schema = $Body.schemaName
        $obj = $Body.objectName
        $path = $Body.auditFilePath -replace "'","''"
        
        $results = Invoke-SqlQuery -Database "master" -Query @"
            SELECT
                event_time,
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
            FROM sys.fn_get_audit_file('$path\*.sqlaudit', DEFAULT, DEFAULT)
            WHERE (
                (object_name = '$obj' AND schema_name = '$schema')
                OR (
                    class_type IN ('OB','SC')
                    AND [statement] LIKE '%$obj%'
                )
            )
            ORDER BY event_time DESC
"@
        
        # Convert DateTimes to ISO strings for JSON
        $cleaned = @()
        foreach ($r in $results) {
            if ($r.event_time -is [DateTime]) {
                $r.event_time = $r.event_time.ToString('o')
            }
            $cleaned += $r
        }
        
        Write-Host "  [AUDIT READ] $($cleaned.Count) events found" -ForegroundColor Cyan
        return @{ success = $true; data = $cleaned }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ─── HTTP Server ──────────────────────────────────────────────────────────────

Write-Banner

$htmlPath = Join-Path $PSScriptRoot "index.html"
if (-not (Test-Path $htmlPath)) {
    Write-Host "  ERROR: index.html not found at $htmlPath" -ForegroundColor Red
    Write-Host "  Make sure index.html is in the same folder as this script." -ForegroundColor Red
    exit 1
}
$htmlContent = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "  ERROR: Could not start listener on port $Port." -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host "  Try running as Administrator or use a different port: .\Start-WhoChangedThat.ps1 -Port 9000" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Server running at $prefix" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) {
    Start-Process $prefix
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        $method = $request.HttpMethod
        $path = $request.Url.AbsolutePath
        
        # Handle CORS preflight
        if ($method -eq 'OPTIONS') {
            $response.StatusCode = 204
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
            $response.OutputStream.Close()
            continue
        }
        
        try {
            switch ($path) {
                '/' {
                    Send-HtmlResponse -Response $response -Html $htmlContent
                }
                '/api/test-connection' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-TestConnection -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/connect' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-Connect -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/disconnect' {
                    $result = Handle-Disconnect
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/get-databases' {
                    $result = Handle-GetDatabases
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/get-objects' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-GetObjects -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/create-audit' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-CreateAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/remove-audit' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-RemoveAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/read-audit' {
                    $body = Get-RequestBody -Request $request
                    $result = Handle-ReadAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                default {
                    $response.StatusCode = 404
                    Send-JsonResponse -Response $response -Data @{ error = "Not found" } -StatusCode 404
                }
            }
        } catch {
            Write-Host "  [ERROR] $path : $($_.Exception.Message)" -ForegroundColor Red
            try {
                Send-JsonResponse -Response $response -Data @{ success = $false; error = $_.Exception.Message } -StatusCode 500
            } catch { <# response may already be sent #> }
        }
    }
} finally {
    Write-Host ""
    Write-Host "  Shutting down..." -ForegroundColor Yellow
    if ($script:SqlConnection -and $script:SqlConnection.State -eq 'Open') {
        $script:SqlConnection.Close()
        $script:SqlConnection.Dispose()
    }
    $listener.Stop()
    $listener.Close()
    Write-Host "  Server stopped." -ForegroundColor DarkGray
}
