# Quickstart (the easy way)

**Three steps. About 2 minutes.** If you can edit a text file, you can do this.

## 1. Install Docker Desktop

If you don't have Docker already:

- Mac: https://www.docker.com/products/docker-desktop/ (pick the Apple Silicon or Intel installer)
- Windows: https://www.docker.com/products/docker-desktop/
- Linux: https://docs.docker.com/engine/install/

Open Docker Desktop after installing and wait until it says **"Docker is running"** in the bottom-left corner.

## 2. Create your `.env` file

Make a new folder for DevOps Labs and a file inside it called `.env`.

**macOS / Linux:**
```bash
mkdir -p ~/devops-labs
nano ~/devops-labs/.env
```

**Windows (PowerShell):**
```powershell
mkdir $env:USERPROFILE\devops-labs
notepad $env:USERPROFILE\devops-labs\.env
```

Paste this template into the file and fill in the two values you were emailed:

```ini
# Paste the long string that starts with eyJ... here (no quotes, one line)
DEVOPS_LABS_LICENSE_KEY=

# Paste the long string that starts with github_pat_... here
GHCR_TOKEN=

# Port on your machine for the web UI. Change if 8090 is taken.
DEVOPS_LABS_PORT=8090
```

Save and close the file.

> **Where do the two values come from?** Both are in the welcome email you received from Liman. The first (`eyJ...`) is your license key. The second (`github_pat_...`) is your pull token for the Docker images.

## 3. Run the installer

Open a terminal (Terminal on Mac, PowerShell on Windows, any shell on Linux) and run **one** of these:

**macOS, Linux, or Windows (Git Bash / WSL2):**
```bash
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.sh | bash
```

**Windows (PowerShell, native):**
```powershell
irm https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.ps1 | iex
```

The script sees your `.env`, reads both values, pulls the images, starts the stack, and prints the URL to open.

That's it. Point your browser at the URL (usually `http://localhost:8090`) and start learning.

---

## FAQ

**I ran the installer without creating `.env` first.** No problem — the script will prompt you for both values. The `.env` approach is just slightly tidier.

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
