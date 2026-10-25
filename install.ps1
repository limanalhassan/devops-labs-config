# DevOps Labs installer for Windows (PowerShell 5.1+ or PowerShell 7+).
# Equivalent to install.sh, same semantics, same output file layout.
#
# Walkthrough:
#   1. Checks prerequisites: Docker, Docker Compose v2, port, disk, RAM.
#   2. Asks for the GitHub pull token and logs into ghcr.io.
#   3. Downloads compose.yaml and .env.example into %USERPROFILE%\devops-labs\.
#   4. Asks for your license key and port, writes .env.
#   5. Pulls images and starts the stack.
#   6. Confirms /api/license shows kind=licensed and prints the URL.
#
# Re-run any time. Existing .env values survive.

$ErrorActionPreference = 'Stop'

$InstallDir = if ($env:DEVOPS_LABS_HOME) { $env:DEVOPS_LABS_HOME } else { Join-Path $env:USERPROFILE "devops-labs" }
$Raw = "https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main"
$GhcrUser = "limanalhassan"
$MinDiskGb = 10
$MinRamGb = 8
$DefaultPort = 8090

# If a pre-filled .env exists in the install dir, pick up every value from it
# so a low-friction customer can edit two blanks and run the installer unattended.
# Existing process env vars still win (letting a scripted install override).
$envFile = Join-Path $InstallDir ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            if (-not [Environment]::GetEnvironmentVariable($k, 'Process')) {
                [Environment]::SetEnvironmentVariable($k, $v, 'Process')
            }
        }
    }
}

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "!!  $m" -ForegroundColor Red; exit 1 }

function Test-Command ($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Test-PortInUse ($port) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        return [bool]$conn
    } catch {
        # Fallback for older PowerShell
        $out = netstat -an | Select-String "LISTENING" | Select-String ":$port\s"
        return [bool]$out
    }
}

function Get-FreeDiskGb {
    $drive = (Get-Item $env:USERPROFILE).PSDrive
    [int]([math]::Floor($drive.Free / 1GB))
}

function Get-TotalRamGb {
    $bytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
    if (-not $bytes) { return 0 }
    [int]([math]::Floor($bytes / 1GB))
}

function Wait-ForDockerDaemon {
    # Try to start Docker Desktop and poll `docker info` for up to 90s.
    # Returns $true if the daemon comes up, $false otherwise.
    $candidates = @(
        "C:\Program Files\Docker\Docker\Docker Desktop.exe",
        (Join-Path $env:LOCALAPPDATA "Docker\Docker Desktop.exe")
    )
    $dockerDesktop = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dockerDesktop) {
        Warn "Docker Desktop isn't installed. Install it from https://www.docker.com/products/docker-desktop/ and re-run."
        return $false
    }
    Warn "Docker daemon isn't running. Launching Docker Desktop (first start can take ~60s)..."
    Start-Process -FilePath $dockerDesktop -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    for ($i = 0; $i -lt 45; $i++) {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Check-Prereqs {
    Say "Checking prerequisites"

    Ok "OS: Windows ($([System.Environment]::OSVersion.VersionString))"

    if (-not (Test-Command 'docker')) {
        Fail "Docker is not installed. Install Docker Desktop: https://docs.docker.com/get-docker/"
    }
    $dockerVersion = (docker version --format '{{.Client.Version}}' 2>$null)
    Ok "Docker CLI: $dockerVersion"

    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (-not (Wait-ForDockerDaemon)) {
            Fail "Docker is installed but the daemon isn't up after 90s. Open Docker Desktop manually, wait for 'Engine running', and re-run."
        }
    }
    Ok "Docker daemon: running"

    docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "Docker Compose v2 is required. Update Docker Desktop (it bundles compose)."
    }
    $composeVersion = (docker compose version --short)
    Ok "Docker Compose: $composeVersion"

    $diskGb = Get-FreeDiskGb
    if ($diskGb -lt $MinDiskGb) {
        Warn "Only ${diskGb}G free on $($env:USERPROFILE.Substring(0,2)). Recommend at least ${MinDiskGb}G."
    } else {
        Ok "Disk: ${diskGb}G free (need ~${MinDiskGb}G)"
    }

    $ramGb = Get-TotalRamGb
    if ($ramGb -gt 0 -and $ramGb -lt $MinRamGb) {
        Warn "${ramGb}G total RAM. Recommend at least ${MinRamGb}G. Labs may feel sluggish."
    } elseif ($ramGb -gt 0) {
        Ok "RAM: ${ramGb}G (need ~${MinRamGb}G)"
    }

    Ok "Docker socket: Docker Desktop handles the socket on Windows."
}

function Login-Ghcr {
    Say "Signing in to ghcr.io (so Docker can pull private images)"
    $tok = $env:GHCR_TOKEN
    if (-not $tok) {
        $secure = Read-Host -AsSecureString "    Paste the pull token you were emailed (github_pat_...)"
        $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    } else {
        Write-Host "    (using GHCR_TOKEN from the environment)"
    }
    if (-not $tok) {
        Fail "Token is empty. Re-run and paste the token when prompted."
    }
    $tok | docker login ghcr.io -u $GhcrUser --password-stdin | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "Login failed. Token may be wrong, expired, or missing read:packages. Email @limanalhassan."
    }
    Ok "Signed in to ghcr.io"
}

function Fetch-Files {
    Say "Setting up $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Invoke-WebRequest -Uri "$Raw/compose.yaml"    -OutFile (Join-Path $InstallDir "compose.yaml")
    Invoke-WebRequest -Uri "$Raw/.env.example"    -OutFile (Join-Path $InstallDir ".env.example")
    Ok "compose.yaml and .env.example in place"
}

function Write-Env {
    $envFile = Join-Path $InstallDir ".env"
    Say "Writing $envFile"
    if (Test-Path $envFile) {
        $existing = Get-Content $envFile
        if ($existing | Select-String -Pattern '^DEVOPS_LABS_LICENSE_KEY=..') {
            Ok "An existing .env already has a license key; keeping it. Delete it to redo."
            return
        }
    }
    $key = $env:DEVOPS_LABS_LICENSE_KEY
    if (-not $key) {
        $key = Read-Host "    License key you were emailed (eyJ...)"
    }
    $port = $env:DEVOPS_LABS_PORT
    if (-not $port) { $port = $DefaultPort }
    while ($true) {
        $input = Read-Host "    Port on this machine for the UI [$port]"
        if ($input) { $port = $input }
        if (Test-PortInUse $port) {
            Warn "Port $port is already in use on this machine. Pick another."
            $port = $DefaultPort
            continue
        }
        break
    }
    Set-Content -Path $envFile -Value @(
        "DEVOPS_LABS_LICENSE_KEY=$key",
        "DEVOPS_LABS_PORT=$port"
    )
    Ok ".env written. Port $port."
}

function Start-Stack {
    Say "Pulling images (about a minute the first time)"
    Push-Location $InstallDir
    try {
        docker compose pull
        if ($LASTEXITCODE -ne 0) {
            Fail "Pull failed. Usually a token problem; re-run the installer to re-login."
        }
        Say "Starting the stack"
        docker compose up -d | Out-Null
    } finally {
        Pop-Location
    }

    Say "Confirming the license took effect"
    $port = (Get-Content (Join-Path $InstallDir ".env") | Select-String '^DEVOPS_LABS_PORT=').ToString().Split('=')[1]

    $status = $null
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $status = Invoke-RestMethod -Uri "http://localhost:$port/api/license" -TimeoutSec 2
            if ($status) { break }
        } catch { }
        Start-Sleep -Seconds 1
    }

    if (-not $status) {
        Warn "Could not read /api/license. Try: curl http://localhost:$port/api/license"
    } else {
        switch ($status.kind) {
            "licensed"        { Ok "License is active." }
            "trial"           { Warn "No valid license key; a 14-day trial has started." }
            "expired-grace"   { Warn "License is in the 7-day grace period." }
            "expired-blocked" { Warn "License is expired. API is blocked. Contact @limanalhassan." }
            default           { Warn "Unexpected license state: $($status.kind)" }
        }
    }
    Write-Host ""
    Say "Done. Open http://localhost:$port in your browser."
}

Check-Prereqs
Login-Ghcr
Fetch-Files
Write-Env
Start-Stack
