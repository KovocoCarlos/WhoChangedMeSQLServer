<#
.SYNOPSIS
    Who Changed That — SQL Server Version
    A Kovoco Inc tool to audit changes on a single SQL Server object.

.DESCRIPTION
    Starts a local HTTP server that serves the HTML UI and provides a REST API
    for SQL Server audit operations. No external dependencies required — uses
    built-in .NET SqlClient.

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

Import-Module "$PSScriptRoot\WhoChangedThat.psm1" -Force

# ─── HTTP Server ────────────────────────────────────────────────────────────

Write-Banner

$htmlPath = Join-Path $PSScriptRoot "index.html"
if (-not (Test-Path $htmlPath)) {
    Write-Host "  ERROR: index.html not found at $htmlPath" -ForegroundColor Red
    Write-Host "  Make sure index.html is in the same folder as this script." -ForegroundColor Red
    exit 1
}

$htmlContent = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)

$listener = New-Object System.Net.HttpListener
$prefix   = "http://localhost:$Port/"
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

if (-not $NoBrowser) { Start-Process $prefix }

try {
    while ($listener.IsListening) {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $method   = $request.HttpMethod
        $path     = $request.Url.AbsolutePath

        # Handle CORS preflight
        if ($method -eq 'OPTIONS') {
            $response.StatusCode = 204
            $response.Headers.Add('Access-Control-Allow-Origin',  '*')
            $response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
            $response.OutputStream.Close()
            continue
        }

        try {
            switch ($path) {
                '/'                    { Send-HtmlResponse -Response $response -Html $htmlContent }
                '/api/test-connection' {
                    $body   = Get-RequestBody -Request $request
                    $result = Handle-TestConnection -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/connect' {
                    $body   = Get-RequestBody -Request $request
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
                    $body   = Get-RequestBody -Request $request
                    $result = Handle-GetObjects -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/create-audit' {
                    $body   = Get-RequestBody -Request $request
                    $result = Handle-CreateAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/remove-audit' {
                    $body   = Get-RequestBody -Request $request
                    $result = Handle-RemoveAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                '/api/read-audit' {
                    $body   = Get-RequestBody -Request $request
                    $result = Handle-ReadAudit -Body $body
                    Send-JsonResponse -Response $response -Data $result
                }
                default {
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
