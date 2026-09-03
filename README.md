# Media Management Stack

Docker Compose-based home media automation stack for the Newman household.

> **Moving to a new server?** See [`MIGRATION.md`](MIGRATION.md) for the complete
> relocation runbook (data inventory, NAS re-mounting, per-service gotchas,
> cutover/rollback).

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| Traefik | — | Reverse proxy + automatic SSL |
| Authelia | `auth.thenewmans.casa` | Single sign-on |
| Radarr | `radarr.thenewmans.casa` | Movie automation |
| Sonarr | `sonarr.thenewmans.casa` | TV show automation |
| Lidarr | `lidarr.thenewmans.casa` | Music automation |
| SABnzbd | `sabnzbd.thenewmans.casa` | Usenet downloader |
| qBittorrent | `torrent.thenewmans.casa` | Torrent client (via NordVPN) |
| Bazarr | `bazarr.thenewmans.casa` | Subtitle automation |
| Seerr | `seerr.thenewmans.casa` | Media request UI |
| Tautulli | `tautulli.thenewmans.casa` | Plex watch activity |
| Recyclarr | — | Quality profile sync (run manually) |
| Profilarr | `profilarr.thenewmans.casa` | Profile management |
| Agregarr | `agregarr.thenewmans.casa` | Collection display |
| Tunarr | `tunarr.thenewmans.casa` | TV channel simulator |
| Cleanuparr | `cleanuparr.thenewmans.casa` | Download queue cleanup |
| Maintainerr | `maintainerr.thenewmans.casa` | Library maintenance |
| Audiobookshelf | `audiobookshelf.thenewmans.casa` | Audiobook/podcast server |
| Linkwarden | `linkwarden.thenewmans.casa` | Bookmark manager |
| MCS Manager | `minecraft.thenewmans.casa` | Minecraft server UI |
| Syncthing | `sync.thenewmans.casa` | File sync → SABnzbd/qBittorrent watch folders |

## Prerequisites

- Docker and Docker Compose v2
- NVIDIA GPU with `nvidia-container-toolkit` installed (used by Tunarr and Ollama)
- A Cloudflare account managing `thenewmans.casa` with a wildcard DNS A record
- A NordVPN account with WireGuard access

## Setup

### 1. Clone the repo

```bash
git clone <repo-url> mediamanagement
cd mediamanagement
```

### 2. Create the secrets file

```bash
cp .env.example .env
```

Open `.env` and fill in all values. Generate random secrets where indicated:

```bash
openssl rand -hex 32     # for Authelia secrets
openssl rand -base64 32  # for Linkwarden secrets
```

See `.env.example` for where to obtain each value.

### 3. Create the Authelia users database

Authelia manages logins for all protected services. Create the users file before starting:

```bash
mkdir -p appdata/authelia
cat > appdata/authelia/users_database.yml << 'EOF'
users:
  yourname:
    displayname: "Your Name"
    password: ""  # Fill in with argon2 hash — see below
    email: you@example.com
    groups:
      - admins
EOF
```

Generate a password hash:

```bash
docker run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 --password 'yourpassword'
```

Paste the output hash into `users_database.yml`.

### 4. Create the recyclarr secrets file

Recyclarr needs API keys to connect to Radarr and Sonarr. After those services
are running (step 6), retrieve their API keys from each app's Settings → General,
then create:

```bash
cat > appdata/recyclarr/secrets.yml << 'EOF'
radarr_hd_url: https://radarr.thenewmans.casa
radarr_hd_apikey: <radarr-api-key>
sonarr_hd_url: https://sonarr.thenewmans.casa
sonarr_hd_apikey: <sonarr-api-key>
EOF
```

### 5. Ensure storage volumes exist

The stack expects these mount points on the host:

```
/mnt/perceptormedia/Video/Movies     — primary movie library
/mnt/perceptormedia/Video/TV         — primary TV library
/mnt/perceptormediaexpansion/Audio/music       — music library
/mnt/perceptormediaexpansion/Audio/audiobooks  — audiobook library
/mnt/perceptormediaexpansion/Audio/podcasts    — podcast library
/mnt/ratchetmedia/Movies             — secondary movie library
/mnt/ratchetmedia/TVShows            — secondary TV library
/mnt/downloads                       — shared download staging area
/mnt/downloads/torrents              — torrent downloads
```

Also required (relative to the repo root):

```
../syncs/Sync/nzb      — SABnzbd NZB watch folder
../syncs/Sync/torrent  — qBittorrent watch folder
```

### 6. Start the stack

```bash
docker compose up -d
```

Or bring up individual service groups:

```bash
docker compose up -d proxy domain          # infrastructure first
docker compose up -d authelia              # then auth
docker compose up -d radarr sonarr lidarr  # then services
```

### 7. Pull the Ollama model

Linkwarden uses Ollama for AI-powered bookmark tagging. Pull the model once
after the stack is running:

```bash
docker exec ollama ollama pull llama3.2
```

### 8. Configure services manually

The following services store their configuration in files that are not tracked
by git (they contain auto-generated API keys and credentials). Each needs to be
configured through its web UI on first run:

| Service | What to configure |
|---------|-------------------|
| Radarr / Sonarr / Lidarr / Readarr | Root folders, quality profiles, download clients |
| SABnzbd | Usenet server credentials, categories |
| qBittorrent | Web UI password (default: `adminadmin`) |
| Tautulli | Connect to Plex |
| Bazarr | Connect to Radarr/Sonarr, subtitle providers |
| Jackett | Indexers |
| Linkwarden | First user to register becomes admin |
| MCS Manager | Admin account created on first login |

### 9. Sync recyclarr

After Radarr and Sonarr are configured and `secrets.yml` is in place:

```bash
docker compose run --rm recyclarr sync
```

## Backups

Files not tracked in git that should be backed up separately:

| Path | Contents |
|------|----------|
| `.env` | All secrets |
| `appdata/recyclarr/secrets.yml` | Radarr/Sonarr API keys |
| `appdata/radarr/config.xml` | Radarr config + API key |
| `appdata/sonarr/config.xml` | Sonarr config + API key |
| `appdata/lidarr/config.xml` | Lidarr config + API key |
| `appdata/sabnzbd/sabnzbd.ini` | SABnzbd config + usenet credentials |
| `appdata/bazarr/config/config.yaml` | Bazarr config |
| `appdata/tautulli/config.ini` | Tautulli config + Plex token |
| `appdata/authelia/users_database.yml` | User accounts |

For Linkwarden, back up the database rather than the config files:

```bash
docker exec linkwarden-db pg_dump -U postgres postgres > linkwarden-backup.sql
```

## Common Commands

```bash
# Start all services
docker compose up -d

# Restart a single service
docker compose restart radarr

# View logs
docker compose logs -f radarr

# Pull latest images and recreate
docker compose pull && docker compose up -d

# Run recyclarr sync
docker compose run --rm recyclarr sync
```
