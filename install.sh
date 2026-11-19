#!/usr/bin/env bash
# DevOps Labs installer. One-shot, idempotent, safe to re-run.
# Works on macOS, Linux, and Windows via Git Bash or WSL2.
#
# Walkthrough:
#   1. Detects the container runtime; if none is present, installs Rancher
#      Desktop (preferred: free, open source) or a Docker Desktop fallback,
#      and bootstraps Homebrew on macOS if that's also missing.
#   2. Checks prerequisites: Docker Compose v2, curl, port, disk, RAM.
#   3. Asks for the GitHub pull token and logs into ghcr.io.
#   4. Downloads compose.yaml and .env.example into ~/devops-labs/.
#   5. Asks for your license key and port, writes .env.
#   6. Pulls images and starts the stack.
#   7. Confirms /api/license shows kind=licensed and prints the URL.
#
# Re-run any time to tweak anything. Values already set in .env survive.
#
# Non-interactive install (CI, automation):
#   DEVOPS_LABS_RUNTIME=rancher|docker|skip  — pick without prompting.
#     skip = fail if no runtime (don't install one).
#   DEVOPS_LABS_AUTO_INSTALL=1  — accept all "install this?" prompts as yes.
set -euo pipefail

INSTALL_DIR="${DEVOPS_LABS_HOME:-$HOME/devops-labs}"
RAW="https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main"
GHCR_USER="limanalhassan"
MIN_DISK_GB=10
MIN_RAM_GB=8
DEFAULT_PORT=8090
# Rancher Desktop's first boot provisions a VM and starts dockerd. That's slow:
# plan for 6 minutes before giving up. Docker Desktop first boot is ~60-90s.
RANCHER_BOOT_SECONDS=360
DOCKER_BOOT_SECONDS=90

# Drop any inherited DEVOPS_LABS_* env vars from the caller's shell. Docker
# compose checks the shell environment BEFORE the .env file, so a stale
# `DEVOPS_LABS_LICENSE_KEY=` (empty but set) from a prior shell session, a
# sourced .env, or some editor plugin would silently override the real key
# the user is about to paste. Unsetting here forces .env to be the single
# source of truth. DEVOPS_LABS_HOME was already captured into INSTALL_DIR
# above, so it's safe to clear.
unset DEVOPS_LABS_LICENSE_KEY DEVOPS_LABS_PORT DEVOPS_LABS_HOME DEVOPS_LABS_VERSION

# If a pre-filled .env exists in the install dir, pick up every value from it
# so a low-friction customer can edit two blanks and run the installer unattended.
# Shell env still wins (letting a scripted install override).
#
# We parse the file line by line instead of `source`-ing it, for two reasons:
#   - a stray `$DEV_LICENSE` in the file would be expanded (and fatal under
#     `set -u`), silently killing the installer.
#   - unquoted shell metachars (`;`, backticks) in a value would execute.
# Here the value is always read as a literal string.
load_env_file() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blanks and comments.
        case "$line" in
            ''|'#'*) continue ;;
        esac
        # Must look like KEY=... with an upper-case/underscore key.
        case "$line" in
            [A-Z_]*=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        # Strip one layer of surrounding single or double quotes if present.
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        # Shell env wins: don't clobber a value already set in the environment.
        set +u
        if [ -z "${!key}" ]; then
            export "$key=$value"
        fi
        set -u
    done < "$file"
}

if [ -f "$INSTALL_DIR/.env" ]; then
    load_env_file "$INSTALL_DIR/.env"
fi

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# True if we can prompt the user interactively. Covers two cases:
#   1. Script was `bash install.sh`, stdin is a terminal.
#   2. Script was `curl ... | bash`, stdin is the pipe, but /dev/tty is
#      still open on the user's terminal. Reading from /dev/tty bypasses
#      the pipe, so interactive prompts still work. Same trick rustup
#      and homebrew use.
can_prompt() {
    [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }
}

# Read a value from the user, hidden ($1="hidden") or visible, into
# the variable named by $2. Reads from stdin if it's a terminal, otherwise
# from /dev/tty so `curl | bash` can still prompt.
prompt() {
    local mode="$1" varname="$2" message="$3"
    if [ -t 0 ]; then
        if [ "$mode" = "hidden" ]; then
            read -r -s -p "$message" "$varname"; echo
        else
            read -r -p "$message" "$varname"
        fi
    else
        if [ "$mode" = "hidden" ]; then
            read -r -s -p "$message" "$varname" </dev/tty; echo
        else
            read -r -p "$message" "$varname" </dev/tty
        fi
    fi
}

detect_os() {
    case "$(uname -s)" in
        Darwin)         echo "macos" ;;
        Linux)          echo "linux" ;;
        MINGW*|CYGWIN*|MSYS*) echo "windows" ;;
        *)              echo "unknown" ;;
    esac
}

free_disk_gb() {
    # Return free GB on the filesystem that holds $INSTALL_DIR's parent.
    local target="$HOME"
    df -k "$target" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

total_ram_gb() {
    case "$(detect_os)" in
        macos)   sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}' ;;
        linux)   awk '/^MemTotal:/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null ;;
        windows) echo "0" ;; # Can't portably detect under Git Bash; skip the check.
        *)       echo "0" ;;
    esac
}

port_in_use() {
    local port="$1"
    # Try several ways to detect "something listening on this port".
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -i ":$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q "" && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null && return 0
    fi
    return 1
}

wait_for_runtime_daemon() {
    # Try to launch the GUI runtime app (Mac/Windows) if it's installed, then poll
    # `docker info` until the daemon answers or the budget runs out.
    # Returns 0 if the daemon comes up, 1 otherwise.
    #   $1 = os (macos|linux|windows)
    #   $2 = runtime ("docker" or "rancher"); which app to launch and how long to wait.
    local os="$1" runtime="$2"
    local budget
    if [ "$runtime" = "rancher" ]; then
        budget="$RANCHER_BOOT_SECONDS"
    else
        budget="$DOCKER_BOOT_SECONDS"
    fi
    case "$os" in
        macos)
            if [ "$runtime" = "rancher" ] && [ -d "/Applications/Rancher Desktop.app" ]; then
                warn "Rancher Desktop isn't running. Launching (first boot can take 3-6 minutes)..."
                open -a "Rancher Desktop" >/dev/null 2>&1 || true
            elif [ -d "/Applications/Docker.app" ]; then
                warn "Docker Desktop isn't running. Launching (first start ~60s)..."
                open -a Docker >/dev/null 2>&1 || true
            else
                warn "No container runtime app found in /Applications. Install Rancher Desktop (https://rancherdesktop.io/) or Docker Desktop and re-run."
                return 1
            fi
            ;;
        windows)
            local exe=""
            if [ "$runtime" = "rancher" ]; then
                for cand in \
                    "/c/Program Files/Rancher Desktop/Rancher Desktop.exe" \
                    "$HOME/AppData/Local/Programs/Rancher Desktop/Rancher Desktop.exe"; do
                    [ -f "$cand" ] && exe="$cand" && break
                done
            fi
            if [ -z "$exe" ]; then
                for cand in \
                    "/c/Program Files/Docker/Docker/Docker Desktop.exe" \
                    "$HOME/AppData/Local/Docker/Docker Desktop.exe"; do
                    [ -f "$cand" ] && exe="$cand" && break
                done
            fi
            if [ -n "$exe" ]; then
                warn "Container runtime isn't running. Launching \"$(basename "$exe")\" (first boot can take a couple of minutes)..."
                "$exe" >/dev/null 2>&1 &
                disown 2>/dev/null || true
            else
                warn "No container runtime found. Install Rancher Desktop (https://rancherdesktop.io/) or Docker Desktop and re-run."
                return 1
            fi
            ;;
        linux)
            # Linux has no "GUI app" to open generically; dockerd is a service, and
            # Rancher Desktop on Linux is launched from the applications menu.
            if [ "$runtime" = "rancher" ]; then
                warn "Rancher Desktop isn't running. Launch it from your applications menu and wait for 'Running' before re-running the installer."
            else
                warn "Docker daemon isn't running. Start it with: sudo systemctl start docker"
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
    # Poll in 2s increments.
    local tries=0 max=$((budget / 2))
    while [ $tries -lt $max ]; do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

# Back-compat shim: older copies of this script called wait_for_docker_daemon
# with a single arg. Keep the symbol around so a repeated invocation from a
# script bundle doesn't break.
wait_for_docker_daemon() { wait_for_runtime_daemon "$1" docker; }

# -- Container runtime detection --
#
# Returns one of:
#   docker-running    docker info succeeds; the context is Docker Desktop or native dockerd.
#   rancher-running   docker info succeeds; the active docker context is Rancher Desktop.
#   docker-installed  docker binary present, Docker Desktop app detected, daemon down.
#   rancher-installed rancher-desktop app detected, daemon down.
#   none              nothing usable here; we'll offer to install Rancher Desktop.
is_rancher_active_context() {
    # Several signals: an active context named rancher-desktop, or an app known
    # to be installed on this platform. Any one of them is enough.
    docker context ls 2>/dev/null | grep -qE '^\*?\s*rancher-desktop\s' \
        && docker context ls 2>/dev/null | awk '/^\*/{print $1,$2}' | grep -q rancher-desktop \
        && return 0
    # Fallback: app bundle present and no Docker Desktop one is.
    case "$(detect_os)" in
        macos)
            [ -d "/Applications/Rancher Desktop.app" ] && [ ! -d "/Applications/Docker.app" ] && return 0
            ;;
    esac
    return 1
}

detect_runtime() {
    local os
    os=$(detect_os)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if is_rancher_active_context; then
            echo "rancher-running"
        else
            echo "docker-running"
        fi
        return
    fi
    # No reachable daemon. Check installed GUI apps.
    case "$os" in
        macos)
            if [ -d "/Applications/Rancher Desktop.app" ]; then
                echo "rancher-installed"
            elif [ -d "/Applications/Docker.app" ]; then
                echo "docker-installed"
            elif command -v docker >/dev/null 2>&1; then
                echo "docker-installed"
            else
                echo "none"
            fi
            ;;
        linux)
            # On Linux, Rancher Desktop lives in /opt or is launched from the
            # menu; we treat a present `rancher-desktop` binary as installed.
            if command -v rancher-desktop >/dev/null 2>&1 || [ -x /opt/rancher-desktop/rancher-desktop ]; then
                echo "rancher-installed"
            elif command -v docker >/dev/null 2>&1; then
                echo "docker-installed"
            else
                echo "none"
            fi
            ;;
        windows)
            if [ -d "/c/Program Files/Rancher Desktop" ] || [ -d "$HOME/AppData/Local/Programs/Rancher Desktop" ]; then
                echo "rancher-installed"
            elif [ -d "/c/Program Files/Docker" ] || command -v docker >/dev/null 2>&1; then
                echo "docker-installed"
            else
                echo "none"
            fi
            ;;
        *)
            command -v docker >/dev/null 2>&1 && echo "docker-installed" || echo "none"
            ;;
    esac
}

# Ask Y/N with a default. $1 = prompt text, $2 = default (Y or N).
# Honors DEVOPS_LABS_AUTO_INSTALL=1 (treats everything as Y).
confirm() {
    local message="$1" default="$2"
    [ "${DEVOPS_LABS_AUTO_INSTALL:-0}" = "1" ] && return 0
    if ! can_prompt; then
        # Non-interactive: a default of Y means "go ahead".
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    local ans
    prompt visible ans "    $message "
    ans="${ans:-$default}"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# Make sure homebrew is on PATH after installing it fresh.
brew_path_fixup() {
    for p in /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$p/brew" ] && ! command -v brew >/dev/null 2>&1; then
            export PATH="$p:$PATH"
        fi
    done
}

ensure_homebrew_macos() {
    command -v brew >/dev/null 2>&1 && return 0
    say "Homebrew is required to install Rancher Desktop on macOS"
    if ! confirm "Install Homebrew now (requires your password)? [Y/n]:" Y; then
        fail "Homebrew is required. Install from https://brew.sh/, then re-run this script."
    fi
    # The homebrew installer is interactive and may ask for sudo. It handles
    # /opt/homebrew (Apple Silicon) vs /usr/local (Intel) automatically.
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail "Homebrew install failed. Install it manually from https://brew.sh/ and re-run."
    brew_path_fixup
    command -v brew >/dev/null 2>&1 \
        || fail "Homebrew installed but 'brew' isn't on PATH yet. Open a new shell and re-run."
    ok "Homebrew installed."
}

install_rancher_desktop_macos() {
    ensure_homebrew_macos
    say "Installing Rancher Desktop via Homebrew (brew install --cask rancher)"
    brew install --cask rancher \
        || fail "brew install --cask rancher failed. Install manually from https://rancherdesktop.io/ then re-run."
    ok "Rancher Desktop installed."
}

install_rancher_desktop_linux() {
    say "Installing Rancher Desktop for Linux"
    # Use the openSUSE Build Service repo that Rancher Desktop publishes to.
    # See https://docs.rancherdesktop.io/getting-started/installation/.
    if command -v apt-get >/dev/null 2>&1; then
        sudo mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
        curl -fsSL https://download.opensuse.org/repositories/isv:/Rancher:/stable/deb/Release.key \
            | gpg --dearmor 2>/dev/null \
            | sudo tee /etc/apt/keyrings/isv-rancher-stable-archive-keyring.gpg >/dev/null
        echo 'deb [signed-by=/etc/apt/keyrings/isv-rancher-stable-archive-keyring.gpg] https://download.opensuse.org/repositories/isv:/Rancher:/stable/deb/ ./' \
            | sudo tee /etc/apt/sources.list.d/isv-rancher-stable.list >/dev/null
        sudo apt-get update
        sudo apt-get install -y rancher-desktop \
            || fail "apt-get install rancher-desktop failed. Install from https://rancherdesktop.io/ and re-run."
        ok "Rancher Desktop installed via apt."
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        local yum_cmd=dnf
        command -v dnf >/dev/null 2>&1 || yum_cmd=yum
        sudo tee /etc/yum.repos.d/isv_Rancher_stable.repo >/dev/null <<EOF
[isv_Rancher_stable]
name=Rancher Desktop (stable)
baseurl=https://download.opensuse.org/repositories/isv:/Rancher:/stable/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/Rancher:/stable/rpm/repodata/repomd.xml.key
EOF
        sudo "$yum_cmd" install -y rancher-desktop \
            || fail "$yum_cmd install rancher-desktop failed. Install from https://rancherdesktop.io/ and re-run."
        ok "Rancher Desktop installed via $yum_cmd."
    else
        fail "Could not find apt-get, dnf or yum on this Linux. Install Rancher Desktop manually from https://rancherdesktop.io/, then re-run."
    fi
    warn "Rancher Desktop was just installed. You'll need to open it from your applications menu, accept the first-launch wizard (dockerd engine, defaults are fine), and wait for the status to say 'Running' before re-running this installer."
    exit 0
}

install_rancher_desktop_windows() {
    say "Installing Rancher Desktop via winget"
    if ! command -v winget.exe >/dev/null 2>&1 && ! command -v winget >/dev/null 2>&1; then
        fail "winget isn't available here (needs recent Windows + App Installer). Install Rancher Desktop manually from https://rancherdesktop.io/ then re-run."
    fi
    winget install -e --id SUSE.RancherDesktop --accept-source-agreements --accept-package-agreements \
        || fail "winget install SUSE.RancherDesktop failed. Install manually from https://rancherdesktop.io/ and re-run."
    ok "Rancher Desktop installed."
}

install_docker_desktop_macos() {
    ensure_homebrew_macos
    say "Installing Docker Desktop via Homebrew (brew install --cask docker)"
    brew install --cask docker \
        || fail "brew install --cask docker failed. Install manually from https://www.docker.com/products/docker-desktop/ then re-run."
    ok "Docker Desktop installed."
}

install_docker_desktop_windows() {
    say "Installing Docker Desktop via winget"
    winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements \
        || fail "winget install Docker.DockerDesktop failed. Install manually from https://www.docker.com/products/docker-desktop/ and re-run."
    ok "Docker Desktop installed."
}

install_docker_desktop_linux() {
    # Docker Desktop on Linux needs an installer per distro (.deb, .rpm, .arch).
    # We keep this short: point the user at the official docs and exit so they
    # can finish the manual install.
    warn "Docker Desktop on Linux requires a distro-specific package. Install it from https://docs.docker.com/desktop/install/linux-install/ and re-run."
    exit 0
}

# Pick a runtime and install it, honoring DEVOPS_LABS_RUNTIME or asking.
choose_and_install_runtime() {
    local os="$1"
    local pick="${DEVOPS_LABS_RUNTIME:-}"
    if [ -z "$pick" ]; then
        echo
        echo "    OpsBench needs a container runtime. Pick one:"
        echo "      1) Rancher Desktop  (recommended: free, open source, same docker CLI)"
        echo "      2) Docker Desktop   (closed source, free for small teams only)"
        echo "      3) Skip  (you'll install one yourself and re-run)"
        if can_prompt; then
            local n
            prompt visible n "    Choice [1]: "
            case "${n:-1}" in
                1|'') pick=rancher ;;
                2)    pick=docker ;;
                *)    pick=skip ;;
            esac
        else
            pick=rancher
            warn "No TTY; defaulting to Rancher Desktop. Set DEVOPS_LABS_RUNTIME=docker to pick Docker Desktop."
        fi
    fi
    case "$pick" in
        rancher)
            case "$os" in
                macos)   install_rancher_desktop_macos ;;
                linux)   install_rancher_desktop_linux ;;
                windows) install_rancher_desktop_windows ;;
                *)       fail "Unsupported OS for auto-install. Install Rancher Desktop from https://rancherdesktop.io/ then re-run." ;;
            esac
            ;;
        docker)
            case "$os" in
                macos)   install_docker_desktop_macos ;;
                linux)   install_docker_desktop_linux ;;
                windows) install_docker_desktop_windows ;;
                *)       fail "Unsupported OS for auto-install. Install Docker Desktop manually then re-run." ;;
            esac
            ;;
        skip)
            fail "No container runtime available. Install Rancher Desktop (https://rancherdesktop.io/) or Docker Desktop and re-run."
            ;;
        *)
            fail "DEVOPS_LABS_RUNTIME=$pick is not one of: rancher, docker, skip."
            ;;
    esac
}

ensure_container_runtime() {
    local os="$1"
    local state
    state=$(detect_runtime)
    case "$state" in
        docker-running)
            local v
            v=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
            ok "Container runtime: Docker ($v)"
            ;;
        rancher-running)
            local v
            v=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
            ok "Container runtime: Rancher Desktop (docker $v)"
            ;;
        docker-installed)
            warn "Docker is installed but the daemon isn't running."
            wait_for_runtime_daemon "$os" docker \
                || fail "Docker daemon didn't come up in time. Open Docker Desktop, wait for the whale to steady, and re-run."
            ok "Docker daemon: running"
            ;;
        rancher-installed)
            warn "Rancher Desktop is installed but the daemon isn't running."
            wait_for_runtime_daemon "$os" rancher \
                || fail "Rancher Desktop didn't come up in time. Open it, wait for 'Running', and re-run."
            ok "Rancher Desktop daemon: running"
            ;;
        none)
            warn "No container runtime detected on this machine."
            choose_and_install_runtime "$os"
            # After an install, launch and poll. Try Rancher first, fall back to
            # Docker: whichever one we just installed will answer.
            if wait_for_runtime_daemon "$os" rancher 2>/dev/null; then
                ok "Rancher Desktop daemon: running"
            elif wait_for_runtime_daemon "$os" docker 2>/dev/null; then
                ok "Docker daemon: running"
            else
                fail "Runtime installed, but the daemon never came up. Open the runtime app, wait for 'Running', and re-run this installer."
            fi
            ;;
        *)
            fail "Unexpected runtime detection state: $state"
            ;;
    esac
}

check_prereqs() {
    say "Checking prerequisites"

    # OS
    local os
    os=$(detect_os)
    ok "OS: $os"
    [ "$os" = "unknown" ] && warn "Unknown OS. Carrying on, but ymmv."

    # Container runtime (detects Docker / Rancher Desktop; offers to install
    # Rancher Desktop if nothing's there yet).
    ensure_container_runtime "$os"

    # Compose v2 (shipped with both Docker Desktop and Rancher Desktop)
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required. Update your runtime (Docker Desktop or Rancher Desktop both bundle it) or install the compose plugin on Linux: https://docs.docker.com/compose/install/"
    local compose_version
    compose_version=$(docker compose version --short)
    ok "Docker Compose: $compose_version"

    # Script dependencies
    command -v curl >/dev/null || fail "curl is required. Install it from your package manager."
    ok "curl: present"

    # Disk space
    local disk_gb
    disk_gb=$(free_disk_gb)
    if [ -n "$disk_gb" ] && [ "$disk_gb" -gt 0 ]; then
        if [ "$disk_gb" -lt "$MIN_DISK_GB" ]; then
            warn "Only ${disk_gb}G free. Recommend at least ${MIN_DISK_GB}G. Install may still fit."
        else
            ok "Disk: ${disk_gb}G free (need ~${MIN_DISK_GB}G)"
        fi
    fi

    # RAM
    local ram_gb
    ram_gb=$(total_ram_gb)
    if [ -n "$ram_gb" ] && [ "$ram_gb" -gt 0 ]; then
        if [ "$ram_gb" -lt "$MIN_RAM_GB" ]; then
            warn "${ram_gb}G total RAM. Recommend at least ${MIN_RAM_GB}G. Labs may feel sluggish."
        else
            ok "RAM: ${ram_gb}G (need ~${MIN_RAM_GB}G)"
        fi
    fi

    # Docker socket (needed because the API spawns lab containers through it)
    local sock="/var/run/docker.sock"
    if [ "$os" = "windows" ]; then
        ok "Docker socket: Docker Desktop handles the socket on Windows."
    elif [ -S "$sock" ] || [ -e "$sock" ]; then
        ok "Docker socket: $sock present"
    else
        warn "No $sock. If labs can't start later, check your Docker Desktop setting 'Allow default Docker socket to be used'."
    fi
}

ghcr_login() {
    say "Signing in to ghcr.io (so Docker can pull private images)"
    local tok
    if [ -n "${GHCR_TOKEN:-}" ]; then
        tok="$GHCR_TOKEN"
        echo "    (using GHCR_TOKEN from $INSTALL_DIR/.env or the environment)"
    elif can_prompt; then
        prompt hidden tok "    Paste the pull token you were emailed (github_pat_...): "
    else
        fail "GHCR_TOKEN is not set and no interactive terminal is available (not a TTY and no /dev/tty). Create $INSTALL_DIR/.env with GHCR_TOKEN=... and re-run."
    fi
    [ -n "$tok" ] || fail "Token is empty. Re-run and paste the token when prompted, or add it to $INSTALL_DIR/.env."
    echo "$tok" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null \
        || fail "Login failed. The token may be wrong, expired, or missing read:packages. Email @limanalhassan."
    ok "Signed in to ghcr.io as $GHCR_USER"
}

fetch_files() {
    say "Setting up $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$RAW/compose.yaml"    -o "$INSTALL_DIR/compose.yaml"
    curl -fsSL "$RAW/.env.example"    -o "$INSTALL_DIR/.env.example"
    ok "compose.yaml and .env.example in place"
}

write_env() {
    local env_file="$INSTALL_DIR/.env"
    say "Writing $env_file"
    if [ -f "$env_file" ] && grep -q "^DEVOPS_LABS_LICENSE_KEY=.." "$env_file"; then
        ok "An existing .env already has a license key; keeping it. Delete it to redo."
        return
    fi
    local key port port_input
    if [ -n "${DEVOPS_LABS_LICENSE_KEY:-}" ]; then
        key="$DEVOPS_LABS_LICENSE_KEY"
    elif can_prompt; then
        prompt visible key "    License key you were emailed (eyJ...): "
    else
        fail "DEVOPS_LABS_LICENSE_KEY is not set and no interactive terminal is available. Add it to $INSTALL_DIR/.env and re-run."
    fi
    port="${DEVOPS_LABS_PORT:-$DEFAULT_PORT}"
    if can_prompt; then
        while :; do
            prompt visible port_input "    Port on this machine for the UI [$port]: "
            port="${port_input:-$port}"
            if port_in_use "$port"; then
                warn "Port $port is already in use on this machine. Pick another."
                port="$DEFAULT_PORT"
                continue
            fi
            break
        done
    else
        if port_in_use "$port"; then
            fail "Port $port is already in use. Set DEVOPS_LABS_PORT=<free port> in $INSTALL_DIR/.env and re-run."
        fi
    fi
    cat > "$env_file" <<EOF
DEVOPS_LABS_LICENSE_KEY=$key
DEVOPS_LABS_PORT=$port
EOF
    chmod 600 "$env_file" 2>/dev/null || true  # chmod no-op on Windows FS; ignore.
    ok ".env written (mode 600 where supported). Port $port."
}

start_stack() {
    # Any lab containers from a previous install carry the `devops-labs` label the
    # engine stamps on every one it creates. Stop and remove them BEFORE the
    # pull+recreate so no running lesson keeps a stale image alive (a learner
    # upgrading would otherwise see the new API talking to an old Gitea sidecar
    # or workspace-terraform until they manually "End lab"). Safe to run every
    # time: the list is empty on a fresh install.
    say "Stopping any running lab containers (so the upgrade actually takes effect)"
    local stale
    stale=$(docker ps -aq --filter 'label=devops-labs' 2>/dev/null || true)
    if [ -n "$stale" ]; then
        docker rm -f $stale >/dev/null 2>&1 || true
        ok "Removed $(printf '%s\n' "$stale" | wc -l | tr -d ' ') stale lab container(s)."
    fi
    # Same for lab networks (one per session).
    local stale_nets
    stale_nets=$(docker network ls -q --filter 'label=devops-labs' 2>/dev/null || true)
    if [ -n "$stale_nets" ]; then
        docker network rm $stale_nets >/dev/null 2>&1 || true
    fi

    # Pull BOTH the api image AND the lab images. Without `--profile images`,
    # `docker compose pull` only pulls the api; the per-lesson images stay on
    # whatever the user had cached from last time, which is exactly the "stuck
    # on stale containers" bug this installer is trying to avoid. One pull up
    # front is slower, but the next lab start is instant and uses the fix.
    say "Pulling images (first time: about two minutes; upgrades: seconds)"
    (cd "$INSTALL_DIR" && docker compose --profile images pull) \
        || fail "Pull failed. Usually a token problem; re-run the installer to re-login."

    say "Starting the stack"
    # --force-recreate: if a previous install left an api container around with
    # a stale port mapping OR an older image id, docker compose up alone would
    # just start it again with the old binding. Force-recreate ensures the
    # current .env + freshly-pulled image win.
    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate api)

    # Reclaim disk from the previous version's now-untagged image layers. `docker
    # compose pull` replaces tags like `devops-labs-api:0` in place, which leaves
    # the OLD layers dangling (no tag, no running container). After enough
    # upgrades a single customer accumulates 10-20 GB of these — one real user
    # reclaimed 16.75 GB with `docker system prune -a` after running the labs
    # for a few weeks. `image prune -f` only touches dangling images; it never
    # removes a tagged image or anything a container is using, so it's safe to
    # run every install. Build cache follows the same lifecycle on local dev,
    # but customers using prebuilt images never touch it.
    local reclaimed
    reclaimed=$(docker image prune -f 2>&1 | sed -n 's/.*Total reclaimed space: \(.*\)/\1/p')
    if [ -n "$reclaimed" ] && [ "$reclaimed" != "0B" ]; then
        ok "Reclaimed $reclaimed of disk from old image layers."
    fi
    say "Confirming the license took effect"
    local port
    # Strip CR, whitespace, and surrounding quotes. Without this, a Windows-style
    # line ending in .env would leave an invisible \r in $port and every curl
    # below would silently fail against a malformed URL. `tr -d` takes a single
    # string argument; macOS and GNU both accept this form.
    port=$(grep ^DEVOPS_LABS_PORT= "$INSTALL_DIR/.env" | cut -d= -f2 | tr -d " \t\r\n\"'")
    # Belt-and-suspenders: port must be a reasonable positive integer.
    case "$port" in
        ''|*[!0-9]*)
            fail "DEVOPS_LABS_PORT in $INSTALL_DIR/.env is not a valid number (got '$port'). Fix it and re-run."
            ;;
    esac
    echo "    (polling http://localhost:$port/api/license)"
    # Was a key provided at all? If so, trial state is a hard fail; it means
    # the key was unreadable or malformed. If nothing was provided, trial is
    # the intended state and only expiry states are a problem.
    local key_was_provided=0
    if grep -q "^DEVOPS_LABS_LICENSE_KEY=.." "$INSTALL_DIR/.env"; then
        key_was_provided=1
    fi
    # Poll /api/license for up to 60s. Each attempt caps at 2s so a slow or
    # hung API doesn't blow the whole budget on one call. First-start boots
    # can take a while after a cold image pull.
    local tries=0 status=""
    while [ $tries -lt 30 ]; do
        status=$(curl -fsS --max-time 2 "http://localhost:$port/api/license" 2>/dev/null | tr -d ' \n' || true)
        [ -n "$status" ] && break
        sleep 2
        tries=$((tries + 1))
    done
    local kind
    kind=$(printf '%s' "$status" | sed -n 's/.*"kind":"\([^"]*\)".*/\1/p')
    # Teardown helper: a bad license state should leave nothing half-running.
    # Dumps the last 40 lines of the api log first so the user sees what
    # actually went wrong (an expired key, a crash, a port conflict etc.).
    stop_and_fail() {
        warn "Container port mapping (so you can see where traffic should land):"
        (docker port devops-labs-api-1 2>&1) | sed 's/^/        /' >&2 || true
        warn "Last 40 lines of the api container log (for diagnosis):"
        (cd "$INSTALL_DIR" && docker compose logs api --tail 40 2>&1) | sed 's/^/        /' >&2 || true
        warn "Tearing down the half-started stack so it doesn't sit in a broken state..."
        (cd "$INSTALL_DIR" && docker compose down) >/dev/null 2>&1 || true
        fail "$1"
    }
    case "$kind" in
        licensed)
            ok "License is active."
            ;;
        trial)
            if [ "$key_was_provided" -eq 1 ]; then
                stop_and_fail "Your license key was not accepted; the API fell back to a trial. The key may be malformed, truncated, or signed with a different keypair than this build expects. Fix $INSTALL_DIR/.env and re-run."
            else
                warn "No license key provided; a 14-day trial has started."
            fi
            ;;
        expired-grace)
            warn "License is in the 7-day grace period. The app works, but please renew soon."
            ;;
        expired-blocked)
            stop_and_fail "License is expired past its 7-day grace period. The API will return 503 on every request. Contact @limanalhassan for a renewal, then update $INSTALL_DIR/.env with the new key and re-run."
            ;;
        "")
            stop_and_fail "The API never responded on http://localhost:$port/api/license after 60s. Likely a boot issue; check 'docker compose -p devops-labs logs api' for the real error."
            ;;
        *)
            stop_and_fail "Unexpected license state '$kind'. Run 'curl -s http://localhost:$port/api/license' for the full response."
            ;;
    esac
    echo
    say "Done. Open http://localhost:$port in your browser."
    open_browser "http://localhost:$port"
}

open_browser() {
    # Auto-open the URL unless the user opted out or we're headless.
    #   DEVOPS_LABS_NO_BROWSER=1     scripted / CI installs
    #   SSH_CONNECTION / SSH_CLIENT  running over SSH, no display
    local url="$1"
    [ "${DEVOPS_LABS_NO_BROWSER:-0}" = "1" ] && return 0
    [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ] && return 0
    case "$(detect_os)" in
        macos)
            open "$url" >/dev/null 2>&1 || true
            ;;
        linux)
            command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1 || true
            ;;
        windows)
            # Git Bash / MSYS inherits `start` from cmd.
            start "" "$url" >/dev/null 2>&1 || true
            ;;
    esac
}

main() {
    check_prereqs
    ghcr_login
    fetch_files
    write_env
    start_stack
}

main "$@"
