# Installing DevOps Labs (manual walkthrough)

For most people the one-liner in [README.md](README.md) is enough. This file is for folks who want to see every step before running anything.

## Prerequisites

- A Mac, Linux box or Windows machine with **at least 16 GB of RAM** and 20 GB of free disk.
- **Docker Desktop** (Mac/Windows) or **Docker Engine** (Linux), 24.0 or newer:
  ```bash
  docker --version
  docker compose version
  ```

## What you've been emailed

| Item | Looks like | Purpose |
|---|---|---|
| **License key** | `eyJjdXN0b21lciI6IkFjbWUi...` (one long base64 string) | Unlocks the API at runtime. Tied to your subscription period. |
| **Pull token** (PAT) | `github_pat_11A...` (one long string) | Lets your machine `docker pull` the private container images. |
| **GHCR username** | `limanalhassan` | Paired with the pull token for `docker login`. |

Keep both strings in a password manager. Don't paste them in Slack, email replies, or screenshots.

## Step 1: sign in to the image registry

```bash
docker login ghcr.io -u limanalhassan
```

When prompted for a password, paste the **pull token** (`github_pat_...`). Expect:

```
Login Succeeded
```

If you get `denied`: your token is wrong, expired, or doesn't have `read:packages`. Email @limanalhassan to double-check.

## Step 2: get the stack definition

Create an install folder and drop in the two files:

```bash
mkdir -p ~/devops-labs && cd ~/devops-labs
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/compose.yaml  -o compose.yaml
curl -fsSL https://raw.githubusercontent.com/limanalhassan/devops-labs-config/main/.env.example  -o .env.example
```

## Step 3: configure your `.env`

```bash
cp .env.example .env
```

Open `.env` in your editor. Paste the **license key** (the `eyJ...` string) after `DEVOPS_LABS_LICENSE_KEY=`:

```ini
DEVOPS_LABS_LICENSE_KEY=eyJjdXN0b21lciI6...<the_full_string_no_quotes>
DEVOPS_LABS_PORT=8090
```

Two notes:

- **One line**, no quotes around the key, no line breaks in the middle. If your email client wrapped the key across two lines, un-wrap it.
- Change `DEVOPS_LABS_PORT=8090` if 8090 is already in use on your machine.

Lock the file so other users on this machine can't read it:

```bash
chmod 600 .env
```

## Step 4: pull and start

```bash
docker compose pull
docker compose up -d
docker compose ps
```

The first pull downloads about 500 MB. When `ps` shows the api container as `Up`, open your browser at:

```
http://localhost:8090
```

(or whatever port you set).

## Step 5: confirm the license took effect

```bash
curl -s http://localhost:8090/api/license
```

Expected shape:

```json
{
  "kind": "licensed",
  "customer": "Your Organisation",
  "expires_on": "2027-12-31",
  "features": ["labs", "api"],
  "seats": null,
  "warning": null
}
```

If `kind` is something other than `licensed`, see Troubleshooting below.

## Updating

A new PAT lands in your inbox roughly every 90 days. When it does, replace your Docker login:

```bash
docker login ghcr.io -u limanalhassan
# paste the new PAT when prompted
docker compose pull
docker compose up -d
```

That's it. Your license key keeps working across updates until its own expiry date.

## Pinning a specific version

By default `compose.yaml` floats to `:0` (any `0.x` release). To pin to an exact version, add to `.env`:

```ini
DEVOPS_LABS_VERSION=0.1.3
```

Then `docker compose up -d`. You'll stay on `0.1.3` until you change the pin.

## Stopping and resuming

```bash
docker compose stop     # pauses, keeps your data
docker compose start    # resumes
docker compose down     # removes containers, keeps data in volumes
docker compose down -v  # wipes everything, including your lab progress
```

## Troubleshooting

### `kind: trial` — license key was not read

- Your `.env` is not in `~/devops-labs/` (where `compose.yaml` lives).
- The key is pasted with hidden line breaks (common from email). Open the key in a plain text editor and confirm it's one line.
- You set the key *after* the container started. Fix: `docker compose down && docker compose up -d`.

### `kind: expired-grace` — subscription has expired

Still working, but you have 7 days left. Contact Liman to renew.

### `kind: expired-blocked` — grace is up

Every page returns 503. Contact Liman for a renewed license key, drop it into `.env`, and restart with `docker compose up -d`.

### `denied: denied` when pulling images

```bash
docker logout ghcr.io
docker login ghcr.io -u limanalhassan
# paste the current PAT
```

If `denied` persists, your PAT is either wrong, expired, or doesn't have `read:packages` on the devops-labs packages. Email Liman.

### Port already in use

```
Error response from daemon: Ports are not available: bind for 0.0.0.0:8090 failed
```

Pick a free port by editing `DEVOPS_LABS_PORT` in `.env`, then `docker compose up -d`.

### I need to move the install to a different machine

The license key is not machine-bound. Copy `~/devops-labs/` (its `compose.yaml`, `.env`, and Docker volumes) to the new machine and `docker compose up -d`. For the volumes, use `docker volume ls` + `docker volume export` or just let the new machine start from scratch; your progress currently lives in the local database inside the data volume.

## Support

Issues, renewals, feature requests: contact **@limanalhassan** on GitHub.

Please include:

```bash
docker compose ps
curl -s http://localhost:8090/api/license
docker compose logs api | tail -40
```

in your message. That's enough for a first-pass diagnosis.
