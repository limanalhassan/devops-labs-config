#!/usr/bin/env bash
# DevOps Labs installer. One-shot, idempotent, safe to re-run.
#
# What it does:
#   1. Checks you have Docker and Docker Compose v2.
#   2. Asks for the GitHub pull token you were emailed, logs into ghcr.io.
#   3. Downloads compose.yaml and .env.example into ~/devops-labs/.
#   4. Asks for your license key and port, writes .env.
#   5. Pulls the images and starts the stack.
#   6. Prints the dashboard URL.
#
# Re-run any time to re-prompt for anything you want to change.
set -euo pipefail

INSTALL_DIR="${DEVOPS_LABS_HOME:-$HOME/devops-labs}"
RAW="https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main"
GHCR_USER="limanalhassan"

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

check_prereqs() {
    say "Checking prerequisites"
    command -v docker >/dev/null || fail "Docker is not installed. See https://docs.docker.com/get-docker/"
    docker info >/dev/null 2>&1 || fail "Docker is installed but not running. Open Docker Desktop or run 'sudo systemctl start docker'."
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required. Update Docker Desktop or install the compose plugin."
    echo "    Docker $(docker --version | awk '{print $3}' | tr -d ,)"
    echo "    Compose $(docker compose version --short)"
}

ghcr_login() {
    say "Signing in to ghcr.io"
    local tok
    if [ -n "${GHCR_TOKEN:-}" ]; then
        tok="$GHCR_TOKEN"
        echo "    (using GHCR_TOKEN from the environment)"
    else
        read -r -s -p "    Paste the pull token you were emailed (github_pat_...): " tok
        echo
    fi
    [ -n "$tok" ] || fail "Token is empty. Re-run and paste the token when prompted."
    echo "$tok" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
}

fetch_files() {
    say "Setting up $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$RAW/compose.yaml"    -o "$INSTALL_DIR/compose.yaml"
    curl -fsSL "$RAW/.env.example"    -o "$INSTALL_DIR/.env.example"
}

write_env() {
    local env_file="$INSTALL_DIR/.env"
    say "Writing $env_file"
    if [ -f "$env_file" ] && grep -q "^DEVOPS_LABS_LICENSE_KEY=.." "$env_file"; then
        echo "    .env already exists and has a license key; keeping it."
        return
    fi
    local key port
    if [ -n "${DEVOPS_LABS_LICENSE_KEY:-}" ]; then
        key="$DEVOPS_LABS_LICENSE_KEY"
    else
        read -r -p "    License key you were emailed (eyJ...): " key
    fi
    port="${DEVOPS_LABS_PORT:-8090}"
    read -r -p "    Port on this machine for the UI [$port]: " input
    port="${input:-$port}"
    cat > "$env_file" <<EOF
DEVOPS_LABS_LICENSE_KEY=$key
DEVOPS_LABS_PORT=$port
EOF
    chmod 600 "$env_file"
}

start_stack() {
    say "Pulling images (first run only, about a minute)"
    (cd "$INSTALL_DIR" && docker compose pull)
    say "Starting the stack"
    (cd "$INSTALL_DIR" && docker compose up -d)
    say "Confirming the license took effect"
    sleep 2
    local port
    port=$(grep ^DEVOPS_LABS_PORT= "$INSTALL_DIR/.env" | cut -d= -f2)
    local status
    status=$(curl -fsS "http://localhost:$port/api/license" 2>/dev/null | grep -o '"kind":"[^"]*"' | cut -d'"' -f4)
    case "$status" in
        licensed)      echo "    License is active."              ;;
        trial)         warn "No license key, trial started."       ;;
        expired-grace) warn "License is in grace period."          ;;
        expired-blocked) warn "License is blocked. Check /api/license." ;;
        *)             warn "Could not read /api/license. Give it a few seconds and curl it yourself." ;;
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
