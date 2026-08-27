#!/usr/bin/env bash
# plex-seed.sh — overnight Plex metadata seed: LXC -> VM (NAS-backed /var/lib/plexmediaserver)
#
# Usage:
#   scripts/plex-seed.sh start     # launch bulk seed in background (resumable by re-running)
#   scripts/plex-seed.sh status    # running state + progress (bundle-dir count vs LXC)
#   scripts/plex-seed.sh stop      # kill an in-flight transfer
#   scripts/plex-seed.sh finish    # cutover delta: stop Plex, copy live DBs + identity
#
# Why tar, not rsync: destination is a CIFS mount; rsync stats every file on it
# (millions of SMB round-trips for ~1.4M small files). Tar streams sequentially.
# Tradeoff: no resume — a restart re-copies, but re-writing is fast sequential IO.

set -euo pipefail

VM="dnewman@192.168.0.7"
DEST="/var/lib/plexmediaserver"
PLEX_DIR="Library/Application Support/Plex Media Server"
PIDFILE="/tmp/plex-seed.pid"
LOG="/tmp/plex-seed.log"

# Excluded during live bulk seed: regenerable junk + files that must not be
# copied mid-write (SQLite DBs, identity). `finish` syncs them at cutover.
LIVE_EXCLUDES=(
  --exclude="*/Logs/*"
  --exclude="*/Cache/Transcode/*"
  --exclude="*/Crash Reports/*"
  --exclude="*/Codecs/*"
  --exclude="*/Plug-in Support/Databases/*"
  --exclude="Preferences.xml"
)

count_bundles() { # $1 = host ("lxc" or ssh target); sample = bundles under 'a/' prefix
  # (one of 16 hex prefixes — proportional progress, ~16x faster than full count on CIFS)
  local dir="/var/lib/plexmediaserver/${PLEX_DIR}/Media/localhost/a"
  if [[ "$1" == "lxc" ]]; then
    docker exec plex sh -c "ls '$dir' 2>/dev/null | wc -l"
  else
    ssh "$1" "ls '$dir' 2>/dev/null | wc -l"
  fi
}

running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

preflight() {
  docker ps --format '{{.Names}}' | grep -qx plex \
    || { echo "ERROR: plex container not running on LXC"; exit 1; }
  ssh -o ConnectTimeout=5 "$VM" "true" 2>/dev/null \
    || { echo "ERROR: VM ($VM) unreachable"; exit 1; }
  ssh "$VM" "grep -q plexvm /proc/mounts" \
    || { echo "ERROR: $DEST not mounted on VM (//192.168.0.5/Media/plexvm)"; exit 1; }
}

cmd_start() {
  if running; then
    echo "Already running (pid $(cat "$PIDFILE")). See: $0 status"
    exit 0
  fi
  preflight
  local excludes="${LIVE_EXCLUDES[*]}"
  echo "[$(date -Is)] bulk seed starting: LXC -> $VM:$DEST (CIFS -> //192.168.0.5/Media/plexvm on NAS)" >> "$LOG"
  setsid bash -c "
    docker exec plex bash -c 'cd /var/lib/plexmediaserver && tar cf - ${excludes} .' 2>/dev/null \
      | ssh $VM 'sudo tar xf - -C $DEST'
    echo \"[\$(date -Is)] bulk seed finished, exit=\$?\" >> $LOG
  " >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "Started (pid $(cat "$PIDFILE")). Log: $LOG   Progress: $0 status"
}

cmd_status() {
  if running; then
    echo "RUNNING (pid $(cat "$PIDFILE"), since $(date -r "$PIDFILE" '+%F %T'))"
    tail -3 "$LOG"
  else
    echo "NOT RUNNING"
    tail -2 "$LOG" 2>/dev/null || echo "(no log yet)"
  fi
  local target have
  target=$(count_bundles lxc)
  have=$(count_bundles "$VM" || echo "?")
  echo "Preview bundles: VM ${have:-?} / LXC ${target}"
  echo "Destination: $VM:$DEST (NAS share: $(ssh "$VM" "awk '/plexvm/ {print \$1}' /proc/mounts" 2>/dev/null || echo "//192.168.0.5/Media/plexvm"))"
}

cmd_stop() {
  if running; then
    local pgid; pgid="$(cat "$PIDFILE")"
    kill -TERM -- -"$pgid" 2>/dev/null || kill "$pgid" 2>/dev/null || true
    ssh "$VM" "sudo pkill -f 'tar xf - -C $DEST'" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "Stopped. Re-run '$0 start' to resume (restarts from scratch — tar has no resume)."
  else
    echo "Not running."
  fi
}

cmd_finish() {
  running && { echo "ERROR: bulk seed still running — run '$0 status' first"; exit 1; }
  preflight
  echo ">>> Stopping Plex on LXC (downtime starts)..."
  ( cd "$(dirname "$0")/.." && docker compose stop plex )
  echo ">>> Copying live databases + identity (~minutes)..."
  docker exec plex bash -c "cd /var/lib/plexmediaserver && tar cf - \
      '${PLEX_DIR}/Plug-in Support/Databases' \
      '${PLEX_DIR}/Preferences.xml'" 2>/dev/null \
    | ssh "$VM" "sudo tar xf - -C $DEST"
  echo ">>> Delta complete. Plex data is fully staged on the VM."
  cat <<'EOF'

Remaining cutover steps (not automated):
  1. Mirage:  pct stop <LXC-ID> && qm set 200 --hostpci0 01:00,pcie=1 && qm start 200
  2. VM:      install nvidia-driver + nvidia-container-toolkit, verify nvidia-smi
  3. VM repo: add compose/media-server.yaml to the include list (git: cherry-pick
              from main), then: docker compose up -d plex
  4. Router:  move the 192.168.0.9 DHCP reservation to the VM's MAC
  5. Verify Plex identity: grep -o 'MachineIdentifier="[^"]*"' \
       "/var/lib/plexmediaserver/$PLEX_DIR/Preferences.xml"
     Expect: 6f98f34c-b227-401d-89c5-46956183069e
EOF
}

case "${1:-}" in
  start)  cmd_start ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  finish) cmd_finish ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac