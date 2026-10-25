# DevOps Labs

Hands-on DevOps labs you run on your own machine: Python, Linux, Git, Docker, Kubernetes, Terraform and more. Each lab is a real environment in a disposable container; progress is yours, offline, forever.

**This repo** is where you install the lab platform. The source code is in a private repo; you don't need it.

## Quick install (one liner)

Make sure you have **Docker Desktop** (Mac/Windows) or **Docker Engine** (Linux), 24.0 or newer, and about 20 GB of free disk. Then:

```bash
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/install.sh | bash
```

The script walks you through:
1. Signing in to the private container registry (you'll paste the token you were emailed).
2. Pulling the two Docker images.
3. Dropping your license key into a `.env` file.
4. Starting the stack.
5. Opening http://localhost:8090 in your browser.

Total time: about 2 minutes, mostly waiting for the image pull.

## What you'll need to have been emailed

1. **A license key**, one long string starting with `eyJ...`. Tied to your subscription period.
2. **A container registry token**, one long string starting with `github_pat_...`. Shared across customers, rotated every 90 days.
3. The GitHub username to pair with that token: `limanalhassan`.

If you don't have both of these, email @limanalhassan on GitHub.

## Prefer to install by hand?

See [INSTALL.md](INSTALL.md) for the step-by-step version without the script.

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
