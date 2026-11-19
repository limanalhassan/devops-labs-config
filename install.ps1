# DevOps Labs installer for Windows (PowerShell 5.1+ or PowerShell 7+).
# Equivalent to install.sh, same semantics, same output file layout.
#
# Walkthrough:
#   1. Detects the container runtime; if none is present, installs Rancher
#      Desktop (preferred: free, open source) or Docker Desktop via winget.
#   2. Checks prerequisites: Docker Compose v2, port, disk, RAM.
#   3. Asks for the GitHub pull token and logs into ghcr.io.
#   4. Downloads compose.yaml and .env.example into %USERPROFILE%\devops-labs\.
#   5. Asks for your license key and port, writes .env.
#   6. Pulls images and starts the stack.
#   7. Confirms /api/license shows kind=licensed and prints the URL.
#
# Re-run any time. Existing .env values survive.
#
# Non-interactive install (CI, automation):
#   $env:DEVOPS_LABS_RUNTIME=rancher|docker|skip  — pick without prompting.
#   $env:DEVOPS_LABS_AUTO_INSTALL=1               — auto-"Y" on install prompts.

$ErrorActionPreference = 'Stop'

$InstallDir = if ($env:DEVOPS_LABS_HOME) { $env:DEVOPS_LABS_HOME } else { Join-Path $env:USERPROFILE "devops-labs" }
$Raw = "https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main"
$GhcrUser = "limanalhassan"
$MinDiskGb = 10
$MinRamGb = 8
$DefaultPort = 8090

# Drop any inherited DEVOPS_LABS_* process env vars. Docker compose checks the
# process env BEFORE the .env file, so a stale empty value from a prior shell
# session would silently override the real key in .env. Unsetting here forces
# .env to be the single source of truth. DEVOPS_LABS_HOME was already captured
# into $InstallDir above.
$env:DEVOPS_LABS_LICENSE_KEY = $null
$env:DEVOPS_LABS_PORT = $null
$env:DEVOPS_LABS_HOME = $null
$env:DEVOPS_LABS_VERSION = $null

# If a pre-filled .env exists in the install dir, pick up every value from it
# so a low-friction customer can edit two blanks and run the installer unattended.
# Existing process env vars still win (letting a scripted install override).
$envFile = Join-Path $InstallDir ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
            $k = $Matches[1]; $v = $Matches[2]
            # Strip one layer of surrounding single or double quotes.
            if ($v -match "^'(.*)'$" -or $v -match '^"(.*)"$') {
                $v = $Matches[1]
            }
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

function Wait-ForRuntimeDaemon ($runtime) {
    # $runtime = "rancher" or "docker". Launches the matching app if it's
    # installed and polls `docker info` until the daemon answers or budget runs
    # out (6 min for Rancher Desktop's VM first boot, 90s for Docker Desktop).
    $budgetSec = 90
    $exe = $null
    switch ($runtime) {
        "rancher" {
            $budgetSec = 360
            $candidates = @(
                "C:\Program Files\Rancher Desktop\Rancher Desktop.exe",
                (Join-Path $env:LOCALAPPDATA "Programs\Rancher Desktop\Rancher Desktop.exe")
            )
            $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $exe) {
                Warn "Rancher Desktop isn't installed. Install from https://rancherdesktop.io/ and re-run."
                return $false
            }
            Warn "Rancher Desktop isn't running. Launching (first boot can take 3-6 minutes)..."
        }
        default {
            $candidates = @(
                "C:\Program Files\Docker\Docker\Docker Desktop.exe",
                (Join-Path $env:LOCALAPPDATA "Docker\Docker Desktop.exe")
            )
            $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $exe) {
                Warn "Docker Desktop isn't installed. Install from https://www.docker.com/products/docker-desktop/ and re-run."
                return $false
            }
            Warn "Docker daemon isn't running. Launching Docker Desktop (first start ~60s)..."
        }
    }
    Start-Process -FilePath $exe -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    $max = [int]($budgetSec / 2)
    for ($i = 0; $i -lt $max; $i++) {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Back-compat shim for older callers.
function Wait-ForDockerDaemon { Wait-ForRuntimeDaemon -runtime "docker" }

function Test-IsRancherActiveContext {
    # Loose check: the docker context is rancher-desktop OR the app bundle is
    # installed in one of the standard locations.
    $ctx = docker context ls 2>$null | Select-String 'rancher-desktop.*\*'
    if ($ctx) { return $true }
    $rdDirs = @(
        "C:\Program Files\Rancher Desktop",
        (Join-Path $env:LOCALAPPDATA "Programs\Rancher Desktop")
    )
    foreach ($d in $rdDirs) { if (Test-Path $d) { return $true } }
    return $false
}

function Get-RuntimeState {
    # Returns: docker-running | rancher-running | docker-installed | rancher-installed | none
    if (Test-Command 'docker') {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if (Test-IsRancherActiveContext) { return "rancher-running" }
            return "docker-running"
        }
    }
    # Daemon not up. Check which GUI is installed.
    $rdDirs = @(
        "C:\Program Files\Rancher Desktop",
        (Join-Path $env:LOCALAPPDATA "Programs\Rancher Desktop")
    )
    foreach ($d in $rdDirs) { if (Test-Path $d) { return "rancher-installed" } }
    $ddDirs = @(
        "C:\Program Files\Docker\Docker",
        (Join-Path $env:LOCALAPPDATA "Docker")
    )
    foreach ($d in $ddDirs) { if (Test-Path $d) { return "docker-installed" } }
    if (Test-Command 'docker') { return "docker-installed" }
    return "none"
}

function Confirm-YesNo ($prompt, $default) {
    if ($env:DEVOPS_LABS_AUTO_INSTALL -eq '1') { return $true }
    $ans = Read-Host $prompt
    if (-not $ans) { $ans = $default }
    return ($ans -match '^[Yy]')
}

function Install-WithWinget ($id, $name) {
    if (-not (Test-Command 'winget')) {
        Fail "winget is required but isn't on PATH. Install '$name' manually from the vendor website and re-run."
    }
    Say "Installing $name via winget"
    & winget install -e --id $id --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Fail "winget install $id failed. Install '$name' manually and re-run."
    }
    Ok "$name installed."
}

function Install-RancherDesktop { Install-WithWinget "SUSE.RancherDesktop" "Rancher Desktop" }
function Install-DockerDesktop  { Install-WithWinget "Docker.DockerDesktop" "Docker Desktop" }

function Choose-And-Install-Runtime {
    $pick = $env:DEVOPS_LABS_RUNTIME
    if (-not $pick) {
        Write-Host ""
        Write-Host "    OpsBench needs a container runtime. Pick one:"
        Write-Host "      1) Rancher Desktop  (recommended: free, open source, same docker CLI)"
        Write-Host "      2) Docker Desktop   (closed source, free for small teams only)"
        Write-Host "      3) Skip  (you'll install one yourself and re-run)"
        $n = Read-Host "    Choice [1]"
        if (-not $n) { $n = "1" }
        switch ($n) {
            "1" { $pick = "rancher" }
            "2" { $pick = "docker" }
            default { $pick = "skip" }
        }
    }
    switch ($pick) {
        "rancher" { Install-RancherDesktop }
        "docker"  { Install-DockerDesktop }
        "skip"    { Fail "No container runtime available. Install Rancher Desktop (https://rancherdesktop.io/) or Docker Desktop and re-run." }
        default   { Fail "DEVOPS_LABS_RUNTIME='$pick' is not one of: rancher, docker, skip." }
    }
}

function Ensure-ContainerRuntime {
    $state = Get-RuntimeState
    switch ($state) {
        "docker-running" {
            $v = (docker version --format '{{.Client.Version}}' 2>$null)
            Ok "Container runtime: Docker ($v)"
        }
        "rancher-running" {
            $v = (docker version --format '{{.Client.Version}}' 2>$null)
            Ok "Container runtime: Rancher Desktop (docker $v)"
        }
        "docker-installed" {
            Warn "Docker is installed but the daemon isn't running."
            if (-not (Wait-ForRuntimeDaemon "docker")) {
                Fail "Docker daemon didn't come up in time. Open Docker Desktop, wait for 'Engine running', and re-run."
            }
            Ok "Docker daemon: running"
        }
        "rancher-installed" {
            Warn "Rancher Desktop is installed but the daemon isn't running."
            if (-not (Wait-ForRuntimeDaemon "rancher")) {
                Fail "Rancher Desktop didn't come up in time. Open it, wait for 'Running', and re-run."
            }
            Ok "Rancher Desktop daemon: running"
        }
        "none" {
            Warn "No container runtime detected on this machine."
            Choose-And-Install-Runtime
            if (Wait-ForRuntimeDaemon "rancher") {
                Ok "Rancher Desktop daemon: running"
            } elseif (Wait-ForRuntimeDaemon "docker") {
                Ok "Docker daemon: running"
            } else {
                Fail "Runtime installed, but the daemon never came up. Open the runtime app, wait for 'Running', and re-run this installer."
            }
        }
        default { Fail "Unexpected runtime state: $state" }
    }
}

function Check-Prereqs {
    Say "Checking prerequisites"

    Ok "OS: Windows ($([System.Environment]::OSVersion.VersionString))"

    # Container runtime (detects Docker / Rancher Desktop; offers to install
    # Rancher Desktop if nothing's there yet).
    Ensure-ContainerRuntime

    docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Shouldn't happen since Ensure-ContainerRuntime already confirmed, but
        # keep the fallback so a weird edge case still prints something useful.
        if (-not (Wait-ForRuntimeDaemon "docker")) {
            Fail "Container runtime is installed but the daemon isn't up. Open it, wait for 'Running', and re-run."
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
    # Stop any lab containers from a previous install BEFORE the pull+recreate.
    # Otherwise a running lesson keeps a stale sidecar image (e.g. the old Gitea)
    # alive while the api gets replaced, and the learner sees the bug the
    # upgrade was supposed to fix until they manually End lab. The engine stamps
    # `devops-labs` on every container it creates; filtering by that label
    # catches all of them and nothing else. Safe on a fresh install (empty list).
    Say "Stopping any running lab containers (so the upgrade actually takes effect)"
    $stale = docker ps -aq --filter "label=devops-labs" 2>$null
    if ($stale) {
        docker rm -f $stale 2>$null | Out-Null
        $count = @($stale).Count
        Ok "Removed $count stale lab container(s)."
    }
    # Same for lab networks the engine created (one per session).
    $staleNets = docker network ls -q --filter "label=devops-labs" 2>$null
    if ($staleNets) {
        docker network rm $staleNets 2>$null | Out-Null
    }

    Say "Pulling images (first time: about two minutes; upgrades: seconds)"
    Push-Location $InstallDir
    try {
        # Docker Compose writes progress to stderr. Under $ErrorActionPreference='Stop'
        # (set at the top of this script), PowerShell 5.1 treats ANY native-command
        # stderr line as a terminating NativeCommandError and kills the script, even
        # when docker's own exit code is 0. We can't change compose's behaviour, so
        # we temporarily downgrade to 'Continue' around compose calls and judge
        # success from $LASTEXITCODE instead.
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # `--profile images` picks up every lab image too (workspace-*, gitea-sidecar,
            # etc.). Without it, `docker compose pull` would only refresh the api and
            # leave the per-lesson images on whatever was cached from last time, which
            # is the "stuck on stale containers" bug this installer is trying to avoid.
            docker compose --profile images pull
            $pullCode = $LASTEXITCODE
            if ($pullCode -ne 0) {
                throw "docker compose pull failed with exit code $pullCode. Usually a token problem; re-run the installer to re-login."
            }
            Say "Starting the stack"
            # --force-recreate: a previous install may have left an api container
            # around with a stale port mapping OR an older image id. Without
            # --force-recreate, 'up' just starts it again with the old binding.
            # Force-recreate ensures the current .env + freshly-pulled image win.
            docker compose up -d --force-recreate api | Out-Null
            $upCode = $LASTEXITCODE
            if ($upCode -ne 0) {
                throw "docker compose up failed with exit code $upCode."
            }

            # Reclaim disk from the previous version's now-untagged image layers.
            # `docker compose pull` replaces tags in place, leaving the OLD layers
            # dangling (no tag, no running container). After a few upgrades a
            # customer accumulates 10-20 GB of these. `image prune -f` only
            # touches dangling images; it never removes a tagged image or
            # anything a container is using, so it's safe to run every install.
            $pruneOutput = (docker image prune -f 2>&1 | Out-String)
            if ($pruneOutput -match 'Total reclaimed space:\s+(.+)') {
                $reclaimed = $Matches[1].Trim()
                if ($reclaimed -and $reclaimed -ne '0B') {
                    Ok "Reclaimed $reclaimed of disk from old image layers."
                }
            }
        } finally {
            $ErrorActionPreference = $savedPreference
        }
    } finally {
        Pop-Location
    }

    Say "Confirming the license took effect"
    # Strip CR, whitespace, quotes. Without this, a Windows-style line ending or
    # surrounding quotes in .env would leave junk in $port and Invoke-RestMethod
    # would silently fail against a malformed URL.
    $port = ((Get-Content (Join-Path $InstallDir ".env") | Select-String '^DEVOPS_LABS_PORT=').ToString() `
             -replace '^DEVOPS_LABS_PORT=', '' `
             -replace '[\s\r\n"'']', '')
    if ($port -notmatch '^\d+$') {
        Fail "DEVOPS_LABS_PORT in $InstallDir\.env is not a valid number (got '$port'). Fix it and re-run."
    }
    Write-Host "    (polling http://localhost:$port/api/license)"

    # Was a key provided? Trial after providing a key means the key was
    # malformed, truncated, or signed with the wrong keypair, so we must fail.
    $keyWasProvided = Select-String -Path (Join-Path $InstallDir ".env") -Pattern '^DEVOPS_LABS_LICENSE_KEY=..' -Quiet

    # Poll /api/license for up to 60s (slow first-start after a cold pull).
    $status = $null
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $status = Invoke-RestMethod -Uri "http://localhost:$port/api/license" -TimeoutSec 2
            if ($status) { break }
        } catch { }
        Start-Sleep -Seconds 2
    }

    function Stop-AndFail ($msg) {
        Warn "Container port mapping (so you can see where traffic should land):"
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { docker port devops-labs-api-1 2>&1 | ForEach-Object { Write-Host "        $_" } } catch { }
        Warn "Last 40 lines of the api container log (for diagnosis):"
        Push-Location $InstallDir
        try { docker compose logs api --tail 40 2>&1 | ForEach-Object { Write-Host "        $_" } } catch { }
        Warn "Tearing down the half-started stack so it doesn't sit in a broken state..."
        try { docker compose down | Out-Null } catch { }
        $ErrorActionPreference = $savedPreference
        Pop-Location
        Fail $msg
    }

    if (-not $status) {
        Stop-AndFail "The API never responded on http://localhost:$port/api/license after 60s. Likely a boot issue; check 'docker compose -p devops-labs logs api' for the real error."
    } else {
        switch ($status.kind) {
            "licensed"        { Ok "License is active." }
            "trial"           {
                if ($keyWasProvided) {
                    Stop-AndFail "Your license key was not accepted; the API fell back to a trial. The key may be malformed, truncated, or signed with a different keypair than this build expects. Fix $InstallDir\.env and re-run."
                } else {
                    Warn "No license key provided; a 14-day trial has started."
                }
            }
            "expired-grace"   { Warn "License is in the 7-day grace period. The app works, but please renew soon." }
            "expired-blocked" { Stop-AndFail "License is expired past its 7-day grace period. The API will return 503 on every request. Contact @limanalhassan for a renewal, then update $InstallDir\.env with the new key and re-run." }
            default           { Stop-AndFail "Unexpected license state '$($status.kind)'. Run 'curl -s http://localhost:$port/api/license' for the full response." }
        }
    }
    Write-Host ""
    Say "Done. Open http://localhost:$port in your browser."
    # Auto-open the URL unless the user opted out. On Windows, Start-Process
    # with a URL hands off to the default browser via the shell.
    if (-not $env:DEVOPS_LABS_NO_BROWSER) {
        try { Start-Process "http://localhost:$port" | Out-Null } catch { }
    }
}

Check-Prereqs
Login-Ghcr
Fetch-Files
Write-Env
Start-Stack
