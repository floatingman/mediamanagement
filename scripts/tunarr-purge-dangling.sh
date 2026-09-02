#!/usr/bin/env bash
# tunarr-purge-dangling.sh — remove lineup references to deleted programs.
#
# Works around tunarr bug #1973 (startup silently deletes program rows below a
# timestamp boundary). After a tunarr restart, channel lineups can reference
# program rows that no longer exist; the scheduler then spins at 100% CPU on
# "Program in lineup ... not found in database" and blocks all streaming.
#
# Usage: sudo scripts/tunarr-purge-dangling.sh   # stops tunarr, purges, restarts

set -euo pipefail
DATA=/var/lib/plexmediaserver/tunarr-data
LINEUPS=$DATA/channel-lineups

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ -f $DATA/db.db ]] || { echo "ERROR: $DATA/db.db not found"; exit 1; }

cd "$(dirname "$0")/.."
if docker compose ps --status running tunarr 2>/dev/null | grep -q tunarr; then
    echo ">>> Stopping tunarr..."
    docker compose stop tunarr
    STOPPED=1
fi

python3 - "$DATA" <<'EOF'
import json, sqlite3, glob, shutil, sys, os
data = sys.argv[1]
db = sqlite3.connect(f'file:{data}/db.db?mode=ro', uri=True)
valid = {r[0] for r in db.execute("SELECT uuid FROM program")}
total = 0
for f in glob.glob(f'{data}/channel-lineups/*.json'):
    if f.endswith(('.bak', '.pre-purge.bak')):
        continue
    j = json.load(open(f))
    items = j.get('items', [])
    kept = [i for i in items if i.get('type') != 'content' or i.get('id') in valid]
    dropped = len(items) - len(kept)
    if dropped:
        shutil.copy(f, f + '.pre-purge.bak')
        j['items'] = kept
        json.dump(j, open(f, 'w'))
        print(f"  {os.path.basename(f)[:12]}: dropped {dropped}, kept {len(kept)}")
        total += dropped
print(f">>> Purged {total} dangling references" if total else ">>> Lineups clean, nothing to purge")
EOF

if [[ ${STOPPED:-0} -eq 1 ]]; then
    echo ">>> Starting tunarr..."
    docker compose start tunarr
    sleep 8
    curl -sf -o /dev/null -m 10 http://192.168.0.9:8000/api/version \
        && echo ">>> API healthy. Watch: docker logs -f tunarr  (expect no 'not found in database')"
fi
