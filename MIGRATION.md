# Migration Guide

Complete runbook for moving this entire media-management stack to a new server.
This complements `README.md` (which covers fresh installs) — use this when you
already have a running stack and want to relocate it with minimal data loss and
downtime.

---

## TL;DR — what actually moves

| Category | Size | Moves? | Where |
|----------|------|--------|-------|
| Compose + config (git) | tiny | ✅ git clone | `compose/`, `*.yaml`, `CLAUDE.md` |
| Secrets | tiny | ✅ copy securely | `.env`, `appdata/recyclarr/secrets.yml`, `appdata/authelia/users_database.yml` |
| App data (configs + DBs) | **~108 GB** | ✅ rsync | `appdata/` |
| Plex server state | **~847 GB** | ✅ rsync (special) | `/var/lib/plexmediaserver` (`PLEX_DATA_PATH`) |
| Media libraries (movies/TV/music) | ~273 TB | ❌ **stays on NAS** | `//192.168.0.5` + `//192.168.0.6` SMB shares |
| Let's Encrypt certs | 228 KB | ⚠️ optional | `letsencrypt/` (re-issuable) |

**The media does not move.** It lives on NAS boxes (`192.168.0.5`, `192.168.0.6`)
mounted via SMB/CIFS. On the new server you just re-mount the same shares at the
same paths. Only the orchestration, configs, databases, and Plex state travel.

---

## 1. Before you start — decisions & inventory

Answer these up front; they determine several steps below.

1. **New LAN subnet the same?** This stack is currently on `192.168.0.0/24`.
   The VPN service reads `LAN_SUBNET` from `.env` (lets LAN hosts reach
   qBittorrent through the tunnel). If the new LAN differs (e.g. `10.0.0.0/24`),
   set `LAN_SUBNET` in `.env`. See [§7 Network gotchas](#7-network--ip-gotchas).
2. **Do the NAS boxes keep their IPs?** `192.168.0.5` and `192.168.0.6` are in
   `/etc/fstab`. If they move, update the new server's fstab.
3. **Does the new server have an NVIDIA GPU?** Plex, Tunarr, and Ollama use
   `runtime: nvidia`. No GPU → remove those lines (see [§7](#7-network--ip-gotchas)).
4. **New public IP?** `cloudflare-ddns` updates `thenewmans.casa` automatically,
   so a new WAN IP is fine — it'll just re-publish.
5. **Downtime tolerance?** Only Plex (847 GB) is big enough to need a two-stage
   rsync. Everything else can stop-and-copy in one pass.

> **Golden rule for all databases:** stop the container *before* copying its
> data. SQLite (Radarr/Sonarr/Lidarr/Plex/Authelia/Tautulli) and PostgreSQL
> (Linkwarden) cannot be safely copied while open.

---

## 2. Phase 0 — Prepare the new server

### 2.1 Base OS + Docker
```bash
# Docker Engine + Compose plugin
curl -fsSL https://get.docker.com | sh
sudo apt install -y docker-compose-plugin     # or distro equivalent
sudo usermod -aG docker $USER                 # log out/in after
```

### 2.2 GPU support (only if the new box has an NVIDIA GPU)
```bash
# 1. NVIDIA driver (distro-specific) — confirm with: nvidia-smi
# 2. nvidia-container-toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
. /etc/os-release
curl -s -L https://nvidia.github.io/libnvidia-container/$ID$VERSION_ID/libnvidia-container.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
# Verify: docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```
No GPU? Delete `runtime: nvidia` + the `NVIDIA_*` env lines from Plex, Tunarr,
and Ollama in the compose files.

### 2.3 Re-mount the NAS media shares
The stack expects these mount points to exist with identical paths. Recreate the
`/etc/fstab` entries (use a credentials file instead of inline passwords):

```bash
sudo apt install -y cifs-utils
sudo mkdir -p /mnt/{perceptormedia,perceptormediaexpansion,ratchetmedia,downloads,backups}
# Store NAS creds securely (mode 600)
sudo tee /etc/samba/.nascreds >/dev/null <<'EOF'
username=dnewman
password=YOUR_NAS_PASSWORD
EOF
sudo chmod 600 /etc/samba/.nascreds
```
Append to `/etc/fstab` (adjust NAS IPs if they changed):
```fstab
//192.168.0.6/Media           /mnt/perceptormedia           cifs _netdev,nofail,credentials=/etc/samba/.nascreds,uid=1000,gid=1003 0 0
//192.168.0.6/MediaExpansion  /mnt/perceptormediaexpansion  cifs _netdev,nofail,credentials=/etc/samba/.nascreds,uid=1000,gid=1003 0 0
//192.168.0.6/Downloads       /mnt/downloads                 cifs _netdev,nofail,credentials=/etc/samba/.nascreds,uid=1000,gid=1003 0 0
//192.168.0.5/Media           /mnt/ratchetmedia              cifs _netdev,nofail,credentials=/etc/samba/.nascreds,uid=1000,gid=1003 0 0
//192.168.0.6/Backups         /mnt/backups                   cifs _netdev,nofail,credentials=/etc/samba/.nascreds,uid=1000,gid=1003 0 0
```
```bash
sudo mount -a
df -h /mnt/perceptormedia /mnt/ratchetmedia   # confirm they mount
```
> Match `uid`/`gid` to the new server's media-owning user (here `1000:1003`).
> CIFS `forceuid`/`forcegid` makes all files appear as that owner regardless.

### 2.4 Create base directories
```bash
sudo mkdir -p /var/lib/plexmediaserver          # Plex data target (PLEX_DATA_PATH)
mkdir -p ~/mediamanagement
# Watch folders used by SABnzbd/qBittorrent (path is repo-relative: ../../syncs/Sync)
mkdir -p ../syncs/Sync/nzb ../syncs/Sync/torrent
```

---

## 3. Phase 1 — Migrate configuration & secrets

### 3.1 Get the repo
```bash
cd ~/mediamanagement
git clone <your-repo-url> .          # or rsync the dir from the old server
```

### 3.2 Copy the secrets (NOT in git — do this manually/securely)
From the old server, transfer:
```bash
# .env (all API keys + secrets)
scp OLDSRV:~/mediamanagement/.env ~/mediamanagement/.env

# Recyclarr API keys
scp -r OLDSRV:~/mediamanagement/appdata/recyclarr/secrets.yml \
        ~/mediamanagement/appdata/recyclarr/

# Authelia user accounts (password hashes)
scp OLDSRV:~/mediamanagement/appdata/authelia/users_database.yml \
        ~/mediamanagement/appdata/authelia/
```

### 3.3 Edit `.env` for the new server
```bash
# Server-specific deployment settings (NOT secret) — set for the new host:
TZ=America/Chicago
PUID=1000                 # account that owns appdata + media on the new host
PGID=1003
LAN_SUBNET=192.168.0.0/24 # new LAN subnet, e.g. 10.0.0.0/24 (VPN uses this)

# Plex paths + ownership (defaults match the original server):
PLEX_DATA_PATH=/var/lib/plexmediaserver
PLEX_PUID=1000            # change to whatever owns the data on the new box
PLEX_PGID=1003
# All other secrets (Cloudflare, NordVPN, Authelia, Linkwarden, Maintainerr)
# carry over unchanged — they're account-bound, not server-bound.
```

---

## 4. Phase 2 — Migrate app data (`appdata/`, ~108 GB)

Most services store config in `appdata/<service>`. The safe procedure is
**stop everything on the old server, then rsync once**.

```bash
# ON THE OLD SERVER — clean stop so all DBs flush to disk
cd ~/mediamanagement && docker compose stop

# ON THE NEW SERVER — copy appdata (run as root to preserve ownership)
sudo rsync -aHSx --info=progress2 --numeric-ids \
  OLDSRV:~/mediamanagement/appdata/ ~/mediamanagement/appdata/
```

### Why stop-first (not live rsync)
Radarr/Sonarr/Lidarr/Readarr, Plex, Authelia, Tautulli, Agregarr, etc. all use
**SQLite**. Copying an open SQLite file yields a corrupt snapshot. Linkwarden
uses **PostgreSQL** — same rule. Stopping first guarantees consistency.

### Optional: two-stage to cut downtime
If ~108 GB over your link is too slow for a single stop window:
```bash
# Stage 1 (old still running) — everything EXCEPT live databases
sudo rsync -aHSx --numeric-ids \
  --exclude '*/__pycache__/' \
  OLDSRV:~/mediamanagement/appdata/ ~/mediamanagement/appdata/
# Stage 2 (after `docker compose stop` on old) — catch DBs + deltas
sudo rsync -aHSx --numeric-ids --delete \
  OLDSRV:~/mediamanagement/appdata/ ~/mediamanagement/appdata/
```

### Largest appdata consumers (plan transfer time)
| Service | Size | Notes |
|---------|------|-------|
| lidarr | 56 GB | music metadata + art |
| radarr | 13 GB | |
| linkwarden | 12 GB | Postgres + Meilisearch + bookmark data — see §5 |
| tunarr | 11 GB | |
| ollama | 7.4 GB | model weights (re-pullable: `docker exec ollama ollama pull <model>`) |
| readarr | 2.7 GB | |
| sonarr | 2.6 GB | |
| others | <1 GB each | |

> **Ollama shortcut:** if you don't want to copy 7.4 GB, delete `appdata/ollama`
> and re-pull after startup: `docker exec ollama ollama pull ${OLLAMA_MODEL}`.

---

## 5. Phase 3 — Migrate Linkwarden's database (special handling)

Linkwarden has three data stores. The stop-first rsync in §4 captures all of
them, **but** PostgreSQL data files are only safely rsync'd between identical
major versions. The robust, version-independent method is dump + restore:

```bash
# ON OLD SERVER (running) — export
docker exec linkwarden-db pg_dump -U postgres postgres > linkwarden.sql

# Transfer + ON NEW SERVER (after `docker compose up -d linkwarden-db`)
scp OLDSRV:linkwarden.sql .
docker compose up -d linkwarden-db
docker exec -i linkwarden-db psql -U postgres postgres < linkwarden.sql
```
Meilisearch (`appdata/linkwarden/meili_data`) and bookmark files
(`appdata/linkwarden/data`) come over via the §4 rsync. If Meili seems stale,
it rebuilds its index from Postgres automatically.

---

## 6. Phase 4 — Migrate Plex (the 847 GB special case)

Plex is the only service whose data lives **outside** `appdata/` (at
`/var/lib/plexmediaserver`) and is large enough to require two-stage rsync.
Use a **two-stage** copy to keep the old server live during the bulk transfer,
and **never copy its SQLite DBs while running**.

```bash
# Stage 1 — bulk (old server RUNNING), exclude live DBs + identity
sudo rsync -aHSx --info=progress2 --numeric-ids \
  --exclude 'Plug-in Support/Databases/' \
  --exclude 'Preferences.xml' \
  --exclude 'Logs/' --exclude 'Crash Reports/' --exclude 'Codecs/' \
  --exclude 'Cache/Transcode/' \
  OLDSRV:'/var/lib/plexmediaserver/' /var/lib/plexmediaserver/

# Stage 2 — final (old Plex STOPPED), grab DBs + claim + deltas
#   on old: docker compose stop plex
sudo rsync -aHSx --info=progress2 --numeric-ids \
  OLDSRV:'/var/lib/plexmediaserver/' /var/lib/plexmediaserver/

# Fix ownership to match .env (PLEX_PUID/PLEX_PGID)
sudo chown -R ${PLEX_PUID:-999}:${PLEX_PGID:-996} /var/lib/plexmediaserver
```

Key facts:
- The library DB has **absolute paths baked in** (`/mnt/...` and
  `/var/lib/plexmediaserver/...`). The compose mounts both, so they resolve
  unchanged — **do not relocate the data to a different internal path**.
- The machine identity + your claim travel in `Preferences.xml`. It shows up as
  the **same** server on the new box — **no re-claim** needed.
- Two servers can't hold the same identity/claim at once — keep the old one off.
- Full details: see the Plex migration discussion; this guide supersedes it.

---

## 7. Network & IP gotchas

These are easy to miss and will silently break things:

| Gotcha | File | Fix |
|--------|------|-----|
| **VPN local-network bypass** | `.env` → `LAN_SUBNET=192.168.0.0/24` (wired to the VPN's `NET_LOCAL`) | Change to the new LAN subnet (e.g. `10.0.0.0/24`). Lets LAN clients reach qBittorrent's WebUI through the VPN. Wrong value = qbittorrent unreachable on LAN. |
| **NAS share IPs** | `/etc/fstab` | `//192.168.0.5` + `//192.168.0.6` — update if the NAS moved. |
| **Plex host networking** | `compose/media-server.yaml` | Plex uses `network_mode: host`, so it binds the host's `32400` directly. On the new host, ensure `32400/tcp` is free and firewalled appropriately. Remote access needs UPnP on the new router or a manual port forward. |
| **qBittorrent via VPN** | `compose/downloaders.yaml` | `torrent` uses `network_mode: service:vpn` — it shares the VPN container's network namespace. Both must come up together (already wired via `depends_on`). |
| **MCSManager needs Docker** | `compose/gaming.yaml` | `mcsmanager-daemon` mounts `/var/run/docker.sock` to launch game servers. Works as-is on the new host. |
| **Media ownership** | `/etc/fstab` + `.env` | CIFS mounts with `uid/gid`; containers run `PUID`/`PGID` (default `1000`/`1003`; Plex `PLEX_PUID`/`PLEX_PGID` `999`/`996`). Keep these consistent. |

---

## 8. Phase 5 — SSL, DNS & external integrations

These are **account-bound, not server-bound**, so they keep working after the
move — but verify each:

- **Cloudflare DNS** (`CLOUDFLARE_DNS_TOKEN`): same token works from anywhere.
  `cloudflare-ddns` will publish the new public IP automatically.
- **Let's Encrypt certs** (Traefik via Cloudflare DNS-01 challenge):
  - *Easiest:* let Traefik re-issue on the new server (the DNS challenge works
    because the Cloudflare token is unchanged). One-time re-issuance per domain.
  - *To preserve certs:* copy `letsencrypt/` over and `chmod 600 letsencrypt/acme.json`.
- **NordVPN** (`NORDVPN_PRIVATE_KEY`): same WireGuard key works anywhere.
- **Plex claim**: travels with the migrated data — no action.
- **Radarr/Sonarr API keys**: travel in `appdata/<svc>/config.xml` — recyclarr's
  `secrets.yml` (copied in §3.2) still matches.

---

## 9. Phase 6 — Start up (in dependency order)

```bash
cd ~/mediamanagement

# Bring groups up in order so dependencies resolve
docker compose up -d proxy domain          # Traefik + DDNS (certs re-issue)
docker compose up -d authelia              # SSO gate
docker compose up -d vpn sabnzbd torrent   # downloaders (vpn before torrent)
docker compose up -d radarr sonarr lidarr readarr bazarr profilarr recyclarr
docker compose up -d seerr tautulli agregarr tunarr cleanuparr maintainerr audiobookshelf
docker compose up -d ollama                # GPU model server
docker compose up -d linkwarden-db linkwarden-search linkwarden
docker compose up -d mcsmanager-web mcsmanager-daemon
docker compose up -d plex                  # last — biggest, host-networked
```
Or simply `docker compose up -d` and let `depends_on` order things.

---

## 10. Phase 7 — Verify (per-service checklist)

```bash
# All containers healthy
docker compose ps

# Media shares visible to containers
docker exec radarr ls /media /ratchetmedia /downloads | head

# Linkwarden DB intact
docker exec linkwarden-db psql -U postgres -c "SELECT count(*) FROM \"Bookmark\";"

# Ollama model present
docker exec ollama ollama list

# Traefik routing + certs (browse each *.thenewmans.casa URL)
curl -sk https://radarr.thenewmans.casa/api/v3/system/status -H "X-Api-Key: $(grep -oP '<apikey>\K[^<]+' appdata/radarr/config.xml)" | head

# Plex identity preserved (same machine, not a new one) + remote access
docker exec plex grep -o 'MachineIdentifier="[A-Za-z0-9]\{6\}' \
  "$PLEX_DATA_PATH/Library/Application Support/Plex Media Server/Preferences.xml"
docker exec plex sh -c 'grep -iE "reachab|published" \
  "'$PLEX_DATA_PATH'/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" | tail -3'

# qBittorrent reachable through VPN
curl -sk https://torrent.thenewmans.casa  # or http://<vpn-ip>:8181
docker exec nordvpn wget -qO- https://api.ipify.org   # should show NordVPN exit IP, not your WAN
```

---

## 11. Per-service reference

| Service | Data path | ~Size | Special handling | Verify |
|---------|-----------|-------|------------------|--------|
| **traefik** | `letsencrypt/` | 228 KB | Re-issues certs via Cloudflare DNS-01; copy dir to preserve | HTTPS works on all subdomains |
| **cloudflare-ddns** | none | — | Re-publishes new WAN IP automatically | `dig thenewmans.casa` → new IP |
| **authelia** | `appdata/authelia/` | 316 KB | SQLite + `users_database.yml` (secrets) | Login at `auth.thenewmans.casa` |
| **vpn** (nordlynx) | none | — | **`NET_LOCAL`** must match new LAN subnet | exit IP ≠ your WAN |
| **sabnzbd** | `appdata/sabnzbd/` | 36 MB | mounts `../../syncs/Sync/nzb` watch folder | WebUI loads, servers listed |
| **torrent** (qbit) | `appdata/qbittorrent/` | 40 MB | `network_mode: service:vpn`; `../../syncs/Sync/torrent` watch | WebUI via VPN, torrents seeding |
| **radarr** | `appdata/radarr/` | 13 GB | SQLite — stop before copy | Movies list intact |
| **sonarr** | `appdata/sonarr/` | 2.6 GB | SQLite — stop before copy | Series list intact |
| **lidarr** | `appdata/lidarr/` | 56 GB | SQLite — stop before copy | Artists list intact |
| **readarr** | `appdata/readarr/` | 2.7 GB | SQLite — stop before copy | Books list intact |
| **bazarr** | `appdata/bazarr/` | 280 MB | SQLite — stop before copy | Subtitles list |
| **recyclarr** | `appdata/recyclarr/` | 617 MB | needs `secrets.yml` (API keys) | `docker compose run --rm recyclarr sync` |
| **profilarr** | `appdata/profilarr/` | 144 MB | | WebUI loads |
| **seerr** | `appdata/seerr/` | 60 MB | SQLite — stop before copy | Requests list |
| **tautulli** | `appdata/tautulli/` | 267 MB | SQLite + Plex token | Connects to Plex |
| **agregarr** | `appdata/agregarr/` | 491 MB | | Collections display |
| **tunarr** | `appdata/tunarr/` | 11 GB | **GPU** (`runtime: nvidia`) | Channels play |
| **cleanuparr** | `appdata/cleanuparr/` | 4.4 MB | | WebUI loads |
| **maintainerr** | `appdata/maintainerr/` | 928 KB | `MAINTAINERR_GITHUB_TOKEN` | Rules present |
| **audiobookshelf** | `appdata/audiobookshelf/` | 166 MB | media on NAS shares | Library loads |
| **plex** | `/var/lib/plexmediaserver` | **847 GB** | **host networking**, GPU, two-stage rsync, identity in `Preferences.xml` | Same machine ID; remote access green |
| **ollama** | `appdata/ollama/` | 7.4 GB | **GPU**; models re-pullable | `ollama list` |
| **linkwarden-db** | `appdata/linkwarden/pgdata` | (in 12 GB) | **PostgreSQL** — dump/restore (§5) | `SELECT count(*)` |
| **linkwarden-search** | `appdata/linkwarden/meili_data` | (in 12 GB) | rebuilds index from DB | search works |
| **linkwarden** | `appdata/linkwarden/data` | (in 12 GB) | depends on db + search | bookmarks load |
| **mcsmanager-web** | `appdata/mcsmanager-web/` | 167 MB | | WebUI + login |
| **mcsmanager-daemon** | `appdata/mcsmanager-daemon/` | 631 MB | mounts `/var/run/docker.sock` | instances listed |

---

## 12. Cutover & rollback

### Cutover sequence
1. Complete §2–§5 on the new server while the old one still serves traffic.
2. Pick a cutover window. Stop the old stack: `docker compose stop` (old).
3. Final incremental rsyncs for `appdata/` and Plex (§4 stage 2, §6 stage 2).
4. Start the new stack (§9). Verify (§10).
5. Update DNS TTL ahead of time if you change the public IP — though
   `cloudflare-ddns` handles `thenewmans.casa` automatically.

### Rollback
- If the new server fails verification: `docker compose stop` (new),
  `docker compose up -d` (old) — the old server's data is untouched (you only
  *copied* from it).
- **Caveat:** once both Plex servers have run with the same identity, only one
  can hold the claim. If you started the new Plex, stop it before reviving the
  old one.

---

## 13. Appendix — command quick-reference

```bash
# Sizes on the old server (re-check before planning transfer time)
sudo du -sh ~/mediamanagement/appdata/* | sort -rh
sudo du -sh /var/lib/plexmediaserver

# Full appdata migration (stop-first)
ssh OLDSRV 'cd ~/mediamanagement && docker compose stop'
sudo rsync -aHSx --info=progress2 --numeric-ids \
  OLDSRV:~/mediamanagement/appdata/ ~/mediamanagement/appdata/

# Linkwarden dump/restore
docker exec linkwarden-db pg_dump -U postgres postgres > linkwarden.sql
docker exec -i linkwarden-db psql -U postgres postgres < linkwarden.sql

# Bring everything up + watch
docker compose up -d && docker compose ps
docker compose logs -f --tail=50 plex

# Clean up old server after successful cutover
ssh OLDSRV 'cd ~/mediamanagement && docker compose down'
```

### What does NOT need migrating
- **Media** — on the NAS, re-mounted only.
- **Ollama models** — re-pullable (`ollama pull`).
- **Let's Encrypt certs** — re-issuable via the Cloudflare DNS challenge.
- **Docker images** — pulled fresh by `docker compose up`.
- **API keys / secrets** — they're in `.env` and the copied secrets files; they
  are account-bound, so the same values work everywhere.
