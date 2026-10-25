# DevOps Labs

Hands-on DevOps labs you run on your own machine: Python, Linux, Git, Docker, Kubernetes, Terraform and more. Each lab is a real environment in a disposable container; progress is yours, offline, forever.

**This repo** is where you install the lab platform. The source code is in a private repo; you don't need it.

## Quick install (one liner)

Make sure you have **Docker Desktop** (Mac/Windows) or **Docker Engine** (Linux), 24.0 or newer, and about 10 GB of free disk + 8 GB of RAM. Then run the installer that matches your OS and shell:

**macOS, Linux, or Windows via WSL2 / Git Bash:**

```bash
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.sh | bash
```

**Windows PowerShell (native):**

```powershell
irm https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.ps1 | iex
```

Both scripts do the same thing:
1. Check prerequisites (Docker running, Compose v2, free disk, free RAM, port available).
2. Ask for the pull token (one long string from your welcome email) and log in to ghcr.io.
3. Download `compose.yaml` and `.env.example` into `~/devops-labs/` (`%USERPROFILE%\devops-labs\` on Windows).
4. Ask for your license key and port, write `.env`.
5. Pull the Docker images and start the stack.
6. Confirm `/api/license` reads `licensed` and tell you the browser URL.

Total time: about 2 minutes, mostly waiting for the image pull.

## What you'll need to have been emailed

1. **A license key**, one long string starting with `eyJ...`. Tied to your subscription period.
2. **A container registry token**, one long string starting with `github_pat_...`. Shared across customers, rotated every 90 days.
3. The GitHub username to pair with that token: `limanalhassan`.

If you don't have both of these, email @limanalhassan on GitHub.

## New here? Prefer step-by-step?

- **[QUICKSTART.md](QUICKSTART.md)** — the easiest path: install Docker, fill in two blanks in a `.env` file, run one command. If you'd rather not pipe `curl` into `bash`, start here.
- **[INSTALL.md](INSTALL.md)** — full manual walkthrough with every detail, prerequisites, and troubleshooting for every failure mode.

## Updating

```bash
cd ~/devops-labs
docker compose pull
docker compose up -d
```

A new PAT lands in your inbox every 90 days as a reminder to update.

## Stopping

```bash
cd ~/devops-labs
docker compose stop
```

Your progress and lab files stick around. Start again with `docker compose start`.

## Troubleshooting

See [INSTALL.md](INSTALL.md#troubleshooting). If you're stuck, contact @limanalhassan on GitHub with the output of:

```bash
docker compose ps
curl -s http://localhost:8090/api/license
docker compose logs api | tail -40
```

## License

Commercial. See the main project's LICENSE. This repo contains only installation assets (compose file, install script, docs); the platform source is proprietary.
