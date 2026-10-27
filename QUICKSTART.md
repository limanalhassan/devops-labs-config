# Quickstart (the easy way)

**Two steps. About 2 minutes.** No files to edit; the installer asks you for everything it needs.

## 1. Install Docker Desktop

If you don't have Docker already:

- Mac: https://www.docker.com/products/docker-desktop/ (pick the Apple Silicon or Intel installer)
- Windows: https://www.docker.com/products/docker-desktop/
- Linux: https://docs.docker.com/engine/install/

Open Docker Desktop after installing and wait until it says **"Docker is running"** in the bottom-left corner. (On Mac and Windows the installer will try to open Docker Desktop for you if it's not already running.)

## 2. Run the installer

Open a terminal (Terminal on Mac, PowerShell on Windows, any shell on Linux) and run **one** of these:

**macOS, Linux, or Windows (Git Bash / WSL2):**
```bash
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.sh | bash
```

**Windows (PowerShell, native):**
```powershell
irm https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.ps1 | iex
```

The installer will:

1. Check prerequisites (Docker, Compose, disk, RAM, port).
2. Ask you for your **pull token** (`github_pat_...`). Hidden as you type.
3. Ask you for your **license key** (`eyJ...`). Visible so you can confirm the paste.
4. Ask what **port** you want for the browser UI (default 8090; press Enter to accept).
5. Pull the images, start the stack, and print the URL to open.

That's it. Point your browser at the URL (usually `http://localhost:8090`) and start learning.

> **Where do the two values come from?** Both are in the welcome email you received from Liman. The first (`eyJ...`) is your license key. The second (`github_pat_...`) is your pull token for the Docker images.

---

## FAQ

**Can I pre-fill the values instead of being prompted?** Yes. Create a file at `~/devops-labs/.env` (`%USERPROFILE%\devops-labs\.env` on Windows) with these three lines before running the installer:

```ini
DEVOPS_LABS_LICENSE_KEY=<your eyJ... key>
GHCR_TOKEN=<your github_pat_... token>
DEVOPS_LABS_PORT=8090
```

The installer will skip the prompts for any value it finds in that file. Useful for scripted or unattended installs.

**I don't have an email with the two values.** Contact @limanalhassan on GitHub.

**Can I run everything inside a company VPN / proxy / firewall?** Yes, as long as Docker can reach `ghcr.io` and the installer can reach `raw.githubusercontent.com`. If your IT blocks either, ask them to allow those two hostnames.

**I want to stop it later.**
```
cd ~/devops-labs
docker compose stop
```
Resume with `docker compose start`.

**I want to update to the latest version.**
```
cd ~/devops-labs
docker compose pull
docker compose up -d
```

**Something's not working.** Open [INSTALL.md](INSTALL.md#troubleshooting). If still stuck, email @limanalhassan on GitHub with the output of:
```
docker compose ps
curl -s http://localhost:8090/api/license
docker compose logs api | tail -40
```
