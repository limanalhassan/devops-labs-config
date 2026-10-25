#!/usr/bin/env bash
# DevOps Labs installer. One-shot, idempotent, safe to re-run.
# Works on macOS, Linux, and Windows via Git Bash or WSL2.
#
# Walkthrough:
#   1. Checks prerequisites: Docker, Docker Compose v2, curl, port, disk, RAM.
#   2. Asks for the GitHub pull token and logs into ghcr.io.
#   3. Downloads compose.yaml and .env.example into ~/devops-labs/.
#   4. Asks for your license key and port, writes .env.
#   5. Pulls images and starts the stack.
#   6. Confirms /api/license shows kind=licensed and prints the URL.
#
# Re-run any time to tweak anything. Values already set in .env survive.
set -euo pipefail

INSTALL_DIR="${DEVOPS_LABS_HOME:-$HOME/devops-labs}"
RAW="https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main"
GHCR_USER="limanalhassan"
MIN_DISK_GB=10
MIN_RAM_GB=8
DEFAULT_PORT=8090

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

wait_for_docker_daemon() {
    # Try to start Docker Desktop (Mac/Windows) and poll `docker info` for up
    # to 90s. On Linux, docker is a system service we don't start for the user.
    # Returns 0 if the daemon comes up, 1 otherwise.
    local os="$1"
    case "$os" in
        macos)
            if [ -d "/Applications/Docker.app" ]; then
                warn "Docker daemon isn't running. Launching Docker Desktop (first start can take ~60s)..."
                open -a Docker >/dev/null 2>&1 || true
            else
                warn "Docker Desktop isn't installed in /Applications. Start Docker and re-run, or install from https://www.docker.com/products/docker-desktop/"
                return 1
            fi
            ;;
        windows)
            local dd=""
            for cand in \
                "/c/Program Files/Docker/Docker/Docker Desktop.exe" \
                "$HOME/AppData/Local/Docker/Docker Desktop.exe"; do
                [ -f "$cand" ] && dd="$cand" && break
            done
            if [ -n "$dd" ]; then
                warn "Docker daemon isn't running. Launching Docker Desktop (first start can take ~60s)..."
                "$dd" >/dev/null 2>&1 &
                disown 2>/dev/null || true
            else
                warn "Docker Desktop isn't installed. Start it and re-run, or install from https://www.docker.com/products/docker-desktop/"
                return 1
            fi
            ;;
        linux)
            warn "Docker daemon isn't running. Start it with: sudo systemctl start docker"
            return 1
            ;;
        *)
            return 1
            ;;
    esac
    # Poll up to ~90s.
    local tries=0
    while [ $tries -lt 45 ]; do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

check_prereqs() {
    say "Checking prerequisites"

    # OS
    local os
    os=$(detect_os)
    ok "OS: $os"
    [ "$os" = "unknown" ] && warn "Unknown OS. Carrying on, but ymmv."

    # Docker
    command -v docker >/dev/null || fail "Docker is not installed. Install Docker Desktop (Mac/Windows) or Docker Engine (Linux): https://docs.docker.com/get-docker/"
    local docker_version
    docker_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
    ok "Docker CLI: $docker_version"
    if ! docker info >/dev/null 2>&1; then
        wait_for_docker_daemon "$os" || fail "Docker is installed but the daemon isn't up after 90s. Start Docker Desktop (or 'sudo systemctl start docker' on Linux) and re-run."
    fi
    ok "Docker daemon: running"

    # Compose v2
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required. Update Docker Desktop (it's bundled), or install the compose plugin on Linux: https://docs.docker.com/compose/install/"
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
    elif [ -t 0 ]; then
        read -r -s -p "    Paste the pull token you were emailed (github_pat_...): " tok
        echo
    else
        fail "GHCR_TOKEN is not set and this script is being piped (stdin is not a terminal, so I can't prompt). Create $INSTALL_DIR/.env with GHCR_TOKEN=... and re-run, or export GHCR_TOKEN before the curl line. See https://github.com/limanalhassan/devops-labs-config#quick-install"
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
    elif [ -t 0 ]; then
        read -r -p "    License key you were emailed (eyJ...): " key
    else
        fail "DEVOPS_LABS_LICENSE_KEY is not set and this script is being piped (can't prompt). Add it to $INSTALL_DIR/.env and re-run."
    fi
    port="${DEVOPS_LABS_PORT:-$DEFAULT_PORT}"
    if [ -t 0 ]; then
        while :; do
            read -r -p "    Port on this machine for the UI [$port]: " port_input
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
    say "Pulling images (about a minute the first time)"
    (cd "$INSTALL_DIR" && docker compose pull) \
        || fail "Pull failed. Usually a token problem; re-run the installer to re-login."
    say "Starting the stack"
    (cd "$INSTALL_DIR" && docker compose up -d)
    say "Confirming the license took effect"
    local port
    port=$(grep ^DEVOPS_LABS_PORT= "$INSTALL_DIR/.env" | cut -d= -f2)
    # Wait up to 15s for the API to come up.
    local tries=0 status=""
    while [ $tries -lt 15 ]; do
        status=$(curl -fsS "http://localhost:$port/api/license" 2>/dev/null | tr -d ' \n' || true)
        [ -n "$status" ] && break
        sleep 1
        tries=$((tries + 1))
    done
    local kind
    kind=$(printf '%s' "$status" | sed -n 's/.*"kind":"\([^"]*\)".*/\1/p')
    case "$kind" in
        licensed)        ok "License is active." ;;
        trial)           warn "No valid license key; a 14-day trial has started." ;;
        expired-grace)   warn "License is in the 7-day grace period." ;;
        expired-blocked) warn "License is expired. API is blocked. Contact @limanalhassan." ;;
        "")              warn "Could not read /api/license. Try: curl http://localhost:$port/api/license" ;;
        *)               warn "Unexpected license state: $kind" ;;
    esac
    echo
    say "Done. Open http://localhost:$port in your browser."
}

main() {
    check_prereqs
    ghcr_login
    fetch_files
    write_env
    start_stack
}

main "$@"
