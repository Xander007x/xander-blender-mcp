<#
.SYNOPSIS
    Start Blender with MCP Server on Machine 1.

.DESCRIPTION
    Launches Blender (with UI) and the MCP addon auto-starts the
    FastAPI server on port 8000 after 3 seconds.

    If Blender is already running with the server, this script will
    just report the status.
#>

param(
    [switch]$Background,
    [int]$Port = 8000
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Load config
$configFile = Join-Path $RepoRoot "blender_config.json"
if (-not (Test-Path $configFile)) {
    Write-Host "[!] Run setup.ps1 first" -ForegroundColor Red
    exit 1
}

$config = Get-Content $configFile | ConvertFrom-Json
$blender = $config.blender_path

if (-not (Test-Path $blender)) {
    Write-Host "[!] Blender not found at: $blender" -ForegroundColor Red
    Write-Host "    Re-run setup.ps1 to reconfigure" -ForegroundColor Yellow
    exit 1
}

# Check if server is already running
try {
    $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 2
    Write-Host "[OK] Blender MCP Server already running" -ForegroundColor Green
    Write-Host "     Tools: $($health.tools)" -ForegroundColor Cyan
    Write-Host "     Docs:  http://localhost:$Port/docs" -ForegroundColor Cyan
    exit 0
} catch {
    # Not running, start it
}

Write-Host "[...] Starting Blender with MCP Server..." -ForegroundColor Yellow

if ($Background) {
    # Background mode — less reliable for thread-safe operations
    # but useful for headless/CI environments
    $startScript = Join-Path $RepoRoot "scripts\auto_start_server.py"
    Start-Process -FilePath $blender -ArgumentList "--background", "--python", $startScript -NoNewWindow
    Write-Host "[OK] Blender started in background mode" -ForegroundColor Green
} else {
    # Normal mode (recommended) — full Blender UI with server running
    Start-Process -FilePath $blender
    Write-Host "[OK] Blender launched — MCP server will auto-start in ~3 seconds" -ForegroundColor Green
}

Write-Host ""
Write-Host "Waiting for server to come online..." -ForegroundColor Yellow

# Wait for server to start (max 30 seconds)
$maxWait = 30
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 2
    $waited += 2
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$Port/health" -TimeoutSec 2
        Write-Host ""
        Write-Host "[OK] Blender MCP Server is online!" -ForegroundColor Green
        Write-Host "     Tools: $($health.tools)" -ForegroundColor Cyan
        Write-Host "     API:   http://localhost:$Port/docs" -ForegroundColor Cyan
        Write-Host "     List:  http://localhost:$Port/mcp/list_tools" -ForegroundColor Cyan
        exit 0
    } catch {
        Write-Host "." -NoNewline -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[!] Server did not start within $maxWait seconds" -ForegroundColor Red
Write-Host "    Check Blender's System Console (Window > Toggle System Console)" -ForegroundColor Yellow
Write-Host "    Ensure the MCP addon is enabled: Edit > Preferences > Add-ons" -ForegroundColor Yellow
