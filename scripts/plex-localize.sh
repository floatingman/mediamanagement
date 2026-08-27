#!/usr/bin/env bash
# plex-localize.sh — Phase C: move Plex data from NAS (CIFS) to a local VM disk.
# Run ON media-vm (192.168.0.7). Assumes Phase A (Plex running on VM via CIFS) done.
#
# Usage:
#   sudo scripts/plex-localize.sh start /dev/sdb   # format disk, bulk copy (Plex stays live)
#   sudo scripts/plex-localize.sh status           # progress: local bytes + bundle sample
#   sudo scripts/plex-localize.sh stop             # stop the copy (rsync = resumable)
#   sudo scripts/plex-localize.sh switch           # cutover: delta sync, flip mount, restart Plex
#   sudo scripts/plex-localize.sh rollback         # flip back to CIFS (emergency)
#
# rsync is safe here: destination is local ext4 (no CIFS metadata tax on compare).
# Live SQLite DBs + Preferences.xml are excluded from the bulk copy and
# delta-synced by `switch` after Plex stops.

set -euo pipefail

PLEX_DEST="/var/lib/plexmediaserver"
STAGING="/mnt/plexdata"
STATE="/tmp/plex-localize.state"   # stores UUID of the new disk
PIDFILE="/tmp/plex-localize.pid"
LOG="/tmp/plex-localize.log"
EXPECTED_ID="6f98f34c-b227-401d-89c5-46956183069e"
PLEX_DIR="Library/Application Support/Plex Media Server"
BUNDLE_SAMPLE="${PLEX_DIR}/Media/localhost/a"

LIVE_EXCLUDES=(
  --exclude="Plug-in Support/Databases"
  --exclude="Plug-in Support/Databases/*"
  --exclude="Preferences.xml"
)

[[ $EUID -eq 0 ]] || { echo "Run with sudo (needs mount/mkfs/fstab access)"; exit 1; }

running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

preflight() {
  grep -q "plexvm" /proc/mounts \
    || { echo "ERROR: ${PLEX_DEST} is not the CIFS mount (plexvm) — already localized?"; exit 1; }
  docker ps --format '{{.Names}}' | grep -qx plex \
    || echo "NOTE: plex container not running (fine for start/switch, Plex just isn't serving)"
}

cmd_start() {
  local disk="${1:-}"
  [[ -b "$disk" ]] || { echo "ERROR: pass a block device, e.g. $0 start /dev/sdb"; exit 1; }
  running && { echo "Already running (pid $(cat "$PIDFILE"))"; exit 0; }
  preflight

  # SAFETY: refuse disks that already hold a filesystem
  local fs; fs="$(lsblk -fno FSTYPE "$disk" | tr -d '[:space:]')"
  [[ -z "$fs" ]] || { echo "ERROR: ${disk} already has filesystem '${fs}' — refusing to format. Wrong disk?"; exit 1; }

  echo "Formatting ${disk} as ext4 (label plexdata)..."
  wipefs -a "$disk"
  mkfs.ext4 -F -L plexdata "$disk" >>"$LOG" 2>&1
  local uuid; uuid="$(lsblk -fno UUID "$disk" | tr -d '[:space:]')"
  echo "UUID=${uuid}" > "$STATE"

  mkdir -p "$STAGING"
  # fstab: staging mount (nofail so a missing disk never blocks boot)
  echo "UUID=${uuid} ${STAGING} ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "$STAGING"

  echo "[$(date -Is)] bulk copy ${PLEX_DEST} (CIFS) -> ${STAGING} (local)" >> "$LOG"
  setsid bash -c "
    rsync -rlt --info=progress2 --chown=999:996 ${LIVE_EXCLUDES[*]} \
      '${PLEX_DEST}/' '${STAGING}/'
    echo \"[\$(date -Is)] bulk copy finished, exit=\$?\" >> $LOG
  " >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "Started (pid $(cat "$PIDFILE")). First pass scans ~1.4M files over CIFS — be patient."
  echo "Progress: $0 status    Cutover when done: $0 switch"
}

cmd_status() {
  if running; then
    echo "RUNNING (pid $(cat "$PIDFILE"), since $(date -r "$PIDFILE" "+%F %T"))"
    tail -2 "$LOG"
  else
    echo "NOT RUNNING"
    tail -2 "$LOG" 2>/dev/null || echo "(no log yet)"
  fi
  local bytes src dst
  bytes=$(du -sh "$STAGING" 2>/dev/null | cut -f1) || true
  src=$(ls "$PLEX_DEST/$BUNDLE_SAMPLE" 2>/dev/null | wc -l) || true
  dst=$(ls "$STAGING/$BUNDLE_SAMPLE" 2>/dev/null | wc -l) || true
  echo "Local bytes: ${bytes:-?} / ~864G"
  echo "Bundle sample (a/): local ${dst:-0} / cifs ${src:-0}"
}

cmd_stop() {
  if running; then
    kill -TERM -- -"$(cat "$PIDFILE")" 2>/dev/null || kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "Stopped. Re-run 'start <disk>' to resume (rsync resumes the delta only)."
  else
    echo "Not running."
  fi
}

cmd_switch() {
  running && { echo "ERROR: bulk copy still running"; exit 1; }
  [[ -f "$STATE" ]] || { echo "ERROR: no state file — run 'start <disk>' first"; exit 1; }
  preflight
  local uuid; uuid="$(grep -oP '(?<=UUID=).*' "$STATE")"

  echo ">>> Stopping Plex (downtime starts)..."
  cd /home/dnewman/mediamanagement && docker compose stop plex

  echo ">>> Final delta (DBs + identity, small)..."
  rsync -rlt --info=progress2 --chown=999:996 "${PLEX_DEST}/" "${STAGING}/"

  echo ">>> Flipping mount: CIFS out, local disk in..."
  umount "$PLEX_DEST"
  umount "$STAGING"
  # fstab: disable CIFS line, repoint staging entry to the real destination
  sed -i "s|^\(//192.168.0.5/Media/plexvm.*\)|#localized# \1|" /etc/fstab
  sed -i "s|^\(UUID=${uuid}\) ${STAGING}|\1 ${PLEX_DEST}|" /etc/fstab
  mount "$PLEX_DEST"
  mountpoint -q "$PLEX_DEST" || { echo "ERROR: local mount failed — check fstab"; exit 1; }

  echo ">>> Starting Plex on local disk..."
  docker compose start plex

  local id; id="$(grep -oP '(?<=MachineIdentifier=")[^"]*' "${PLEX_DEST}/${PLEX_DIR}/Preferences.xml" 2>/dev/null || true)"
  if [[ "$id" == "$EXPECTED_ID" ]]; then
    echo ">>> PASS: MachineIdentifier matches (${id})"
    echo ">>> Cutover complete. Old CIFS entry kept (commented) in fstab for rollback."
    echo ">>> When confident: remove the '#localized#' fstab line and wipe the NAS staging copy."
  else
    echo ">>> FAIL: identity is '${id:-missing}' (expected ${EXPECTED_ID})"
    echo ">>> Rollback: $0 rollback"
    exit 1
  fi
}

cmd_rollback() {
  [[ -f "$STATE" ]] || { echo "ERROR: no state file"; exit 1; }
  local uuid; uuid="$(grep -oP '(?<=UUID=).*' "$STATE")"
  cd /home/dnewman/mediamanagement && docker compose stop plex || true
  umount "$PLEX_DEST" 2>/dev/null || true
  # fstab: restore CIFS line, demote local line back to staging
  sed -i "s|^#localized# ||" /etc/fstab
  sed -i "s|^\(UUID=${uuid}\) ${PLEX_DEST}|\1 ${STAGING}|" /etc/fstab
  mount "$PLEX_DEST"
  docker compose start plex
  echo "Rolled back to CIFS. Local copy still intact at ${STAGING}."
}

case "${1:-}" in
  start)    shift; cmd_start "$@" ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  switch)   cmd_switch ;;
  rollback) cmd_rollback ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac