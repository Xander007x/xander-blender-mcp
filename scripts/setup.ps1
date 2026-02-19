<#
.SYNOPSIS
    Setup script for xander-blender-mcp on Machine 1.
    Downloads the poly-mcp addon, installs dependencies into Blender's Python,
    and configures auto-start.

.DESCRIPTION
    This script:
    1. Locates or installs Blender
    2. Downloads blender_mcp.py from poly-mcp/Blender-MCP-Server
    3. Installs Python dependencies into Blender's embedded Python
    4. Copies our polymcp_toolkit shim (no external polymcp package needed)
    5. Installs the addon and auto-start script into Blender's user dirs
#>

param(
    [string]$BlenderPath = "",
    [int]$Port = 8000
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path "$RepoRoot\addon")) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

Write-Host "`n=== xander-blender-mcp Setup ===" -ForegroundColor Cyan

# ── 1. Find Blender ──────────────────────────────────────────────
function Find-Blender {
    # Check common install locations
    $searchPaths = @(
        "C:\Program Files\Blender Foundation\Blender*\blender.exe",
        "C:\Program Files (x86)\Blender Foundation\Blender*\blender.exe",
        "$env:LOCALAPPDATA\Blender Foundation\Blender*\blender.exe"
    )

    foreach ($pattern in $searchPaths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | 
                 Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    # Try PATH
    $inPath = Get-Command blender -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    return $null
}

if ($BlenderPath -and (Test-Path $BlenderPath)) {
    $blender = $BlenderPath
} else {
    $blender = Find-Blender
}

if (-not $blender) {
    Write-Host "[!] Blender not found. Install it first:" -ForegroundColor Red
    Write-Host "    winget install BlenderFoundation.Blender" -ForegroundColor Yellow
    Write-Host "    Or download from https://www.blender.org/download/" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] Blender found: $blender" -ForegroundColor Green

# Derive paths from Blender executable location
$blenderDir = Split-Path -Parent $blender
$versionDir = Get-ChildItem -Path $blenderDir -Directory | 
    Where-Object { $_.Name -match '^\d+\.\d+$' } | 
    Sort-Object Name -Descending | Select-Object -First 1

if (-not $versionDir) {
    Write-Host "[!] Cannot find Blender version directory" -ForegroundColor Red
    exit 1
}

$blenderVersion = $versionDir.Name
$blenderPython = Join-Path $versionDir.FullName "python\bin\python.exe"
$sitePackages = Join-Path $versionDir.FullName "python\lib\site-packages"
$userAddons = Join-Path $env:APPDATA "Blender Foundation\Blender\$blenderVersion\scripts\addons"
$userStartup = Join-Path $env:APPDATA "Blender Foundation\Blender\$blenderVersion\scripts\startup"

Write-Host "[OK] Blender version: $blenderVersion" -ForegroundColor Green
Write-Host "[OK] Blender Python: $blenderPython" -ForegroundColor Green

# ── 2. Download the poly-mcp addon ───────────────────────────────
$addonDir = Join-Path $RepoRoot "addon"
$addonFile = Join-Path $addonDir "blender_mcp.py"

if (-not (Test-Path $addonFile)) {
    Write-Host "`n[...] Downloading blender_mcp.py from poly-mcp/Blender-MCP-Server..." -ForegroundColor Yellow
    $url = "https://raw.githubusercontent.com/poly-mcp/Blender-MCP-Server/main/blender_mcp.py"
    try {
        Invoke-WebRequest -Uri $url -OutFile $addonFile -UseBasicParsing
        Write-Host "[OK] Addon downloaded" -ForegroundColor Green
    } catch {
        Write-Host "[!] Failed to download addon: $_" -ForegroundColor Red
        Write-Host "    You can manually download from: $url" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[OK] Addon already present: $addonFile" -ForegroundColor Green
}

# ── 3. Install Python dependencies into Blender's Python ────────
Write-Host "`n[...] Installing Python dependencies into Blender's Python..." -ForegroundColor Yellow

$packages = @("fastapi", "uvicorn[standard]", "pydantic", "docstring-parser", "numpy")
foreach ($pkg in $packages) {
    Write-Host "  Installing $pkg..." -NoNewline
    & $blenderPython -m pip install $pkg --quiet --disable-pip-version-check 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Host " WARN (may already be installed)" -ForegroundColor Yellow
    }
}

# ── 4. Install our polymcp_toolkit shim ──────────────────────────
Write-Host "`n[...] Installing polymcp_toolkit shim..." -ForegroundColor Yellow
$shimSource = Join-Path $addonDir "polymcp_toolkit.py"

# pip installs to user site-packages (no admin needed), so put the shim there too
$userSitePackages = & $blenderPython -c "import site; print(site.getusersitepackages())" 2>$null
if (-not $userSitePackages -or -not (Test-Path $userSitePackages)) {
    # Fallback: find where pip installed fastapi
    $userSitePackages = & $blenderPython -c "import fastapi, os; print(os.path.dirname(os.path.dirname(fastapi.__file__)))" 2>$null
}
if (-not $userSitePackages -or -not (Test-Path $userSitePackages)) {
    # Last resort: system site-packages (requires admin)
    $userSitePackages = $sitePackages
}

New-Item -ItemType Directory -Path $userSitePackages -Force -ErrorAction SilentlyContinue | Out-Null
$shimDest = Join-Path $userSitePackages "polymcp_toolkit.py"
Copy-Item -Path $shimSource -Destination $shimDest -Force
Write-Host "[OK] polymcp_toolkit.py -> $shimDest" -ForegroundColor Green

# ── 5. Install addon into Blender's user addons directory ────────
Write-Host "`n[...] Installing addon into Blender..." -ForegroundColor Yellow

New-Item -ItemType Directory -Path $userAddons -Force | Out-Null
Copy-Item -Path $addonFile -Destination (Join-Path $userAddons "blender_mcp.py") -Force
Write-Host "[OK] blender_mcp.py -> $userAddons" -ForegroundColor Green

# ── 6. Install auto-start script ────────────────────────────────
Write-Host "`n[...] Installing auto-start script..." -ForegroundColor Yellow

New-Item -ItemType Directory -Path $userStartup -Force | Out-Null
$autoStartScript = Join-Path (Join-Path $RepoRoot "scripts") "auto_start_server.py"
Copy-Item -Path $autoStartScript -Destination (Join-Path $userStartup "auto_start_mcp.py") -Force
Write-Host "[OK] auto_start_mcp.py -> $userStartup" -ForegroundColor Green

# ── 7. Save config ──────────────────────────────────────────────
$configFile = Join-Path $RepoRoot "blender_config.json"
@{
    blender_path     = $blender
    blender_version  = $blenderVersion
    blender_python   = $blenderPython
    port             = $Port
    addon_installed  = $true
    setup_date       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json | Set-Content $configFile

Write-Host "`n=== Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "To start Blender with MCP server:" -ForegroundColor Cyan
Write-Host "  .\scripts\start.ps1" -ForegroundColor White
Write-Host ""
Write-Host "Or launch Blender normally — the server auto-starts on port $Port." -ForegroundColor Cyan
Write-Host "API docs: http://localhost:$Port/docs" -ForegroundColor White
Write-Host "Tool list: http://localhost:$Port/mcp/list_tools" -ForegroundColor White
