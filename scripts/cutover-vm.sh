#!/usr/bin/env bash
# cutover-vm.sh — Step 5 of full cutover. Run ON media-vm (192.168.0.7).
# Prereq: GPU passthrough done (Mirage) + nvidia-container-toolkit installed,
# else `go` will fail starting plex/ollama/tunarr (runtime: nvidia).
#
# Usage:
#   scripts/cutover-vm.sh prep    # stage full-stack compose + pre-pull images (safe now)
#   scripts/cutover-vm.sh go      # flip compose to full stack and bring everything up
#   scripts/cutover-vm.sh undo    # restore split-stack compose (emergency)

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="$REPO/docker-compose.yaml"
STAGED="$REPO/docker-compose.fullstack.yaml"
BACKUP="$REPO/docker-compose.yaml.split.bak"

FULLSTACK=$(cat <<'EOF'
# Full stack on media-vm — after LXC decommission. GPU services included.
include:
  - compose/infrastructure.yaml
  - compose/auth.yaml
  - compose/downloaders.yaml
  - compose/media-management.yaml
  - compose/media-server.yaml
  - compose/gaming.yaml
  - compose/bookmarks.yaml
  - compose/ai.yaml
  - compose/utilities.yaml

services:
  # Host ports for LAN/admin access (Traefik handles subdomains internally)
  authelia:
    ports:
      - "9091:9091"
  radarr:
    ports:
      - "7878:7878"
  sonarr:
    ports:
      - "8989:8989"
  lidarr:
    ports:
      - "8686:8686"
  titlecardmaker:
    ports:
      - "4242:4242"
  sabnzbd:
    ports:
      - "8080:8080"
  vpn:
    ports:
      - "8181:8181"
EOF
)

cmd_prep() {
  echo "$FULLSTACK" > "$STAGED"
  echo ">>> Staged: $STAGED"
  echo ">>> Pre-pulling images (safe; nothing restarts)..."
  ( cd "$REPO" && docker compose -f "$STAGED" pull --ignore-buildable 2>&1 | grep -cE 'Pulling|up to date' || true )
  echo ">>> Staged compose preview:"
  ( cd "$REPO" && docker compose -f "$STAGED" config --services | sort | tr '\n' ' ' ); echo
}

cmd_go() {
  [[ -f "$STAGED" ]] || { echo "ERROR: run 'prep' first"; exit 1; }
  nvidia-smi &>/dev/null || { echo "ERROR: nvidia-smi failed — GPU/driver not ready (Step 3-4 first)"; exit 1; }
  docker info 2>/dev/null | grep -q nvidia || { echo "ERROR: docker nvidia runtime not configured (nvidia-ctk runtime configure)"; exit 1; }
  echo ">>> Flipping compose to full stack (backup: $BACKUP)..."
  cp "$LIVE" "$BACKUP"
  cp "$STAGED" "$LIVE"
  ( cd "$REPO" && docker compose up -d --remove-orphans )
  echo ">>> Status:"
  ( cd "$REPO" && docker compose ps --format 'table {{.Name}}\t{{.Status}}' )
  cat <<'EOF'

Verify next:
  1. Plex identity: grep -o 'MachineIdentifier="[^"]*"' \
       '/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml'
     expect 6f98f34c-b227-401d-89c5-46956183069e
  2. Router: move 192.168.0.9 DHCP reservation to this VM's MAC
  3. Subdomains via new local Traefik; play a transcode -> nvidia-smi
EOF
}

cmd_undo() {
  [[ -f "$BACKUP" ]] || { echo "ERROR: no backup found"; exit 1; }
  cp "$BACKUP" "$LIVE"
  ( cd "$REPO" && docker compose up -d --remove-orphans )
  echo "Restored split-stack compose."
}

case "${1:-}" in
  prep) cmd_prep ;;
  go)   cmd_go ;;
  undo) cmd_undo ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac