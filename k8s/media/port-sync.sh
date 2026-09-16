#!/bin/sh
# Port-sync loop (replaces the t-anc GSP docker mod, whose ghcr fetch is
# broken): poll gluetun's control API for the NAT-PMP forwarded port and
# push it into qBittorrent's listening port via the WebUI API (localhost
# bypass-auth is enabled in the config).
#
# The API key is read from gluetun's own auth config (mounted read-only at
# /gluetun-ro) so this never drifts from what gluetun actually enforces.
# Endpoint is /v1/portforward — that's what the auth role in config.toml
# is scoped to.
set -u
KEY=$(sed -n 's/^apikey *= *"\(.*\)"/\1/p' /gluetun-ro/auth/config.toml | head -1)
[ -n "$KEY" ] || { echo "$(date -Iseconds) FATAL: no apikey in /gluetun-ro/auth/config.toml"; exit 1; }
LAST=none
while true; do
    RESP=$(curl -s --max-time 5 -H "X-API-Key: $KEY" http://127.0.0.1:8000/v1/portforward)
    [ -z "$RESP" ] && RESP=$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/v1/portforward)
    PORT=$(echo "$RESP" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')
    if [ -n "$PORT" ] && [ "$PORT" != "0" ] && [ "$PORT" != "$LAST" ]; then
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            --data-urlencode 'json={"listen_port":'"$PORT"'}' \
            http://127.0.0.1:8181/api/v2/app/setPreferences)
        echo "$(date -Iseconds) set qBittorrent listen_port=$PORT (api $CODE)"
        LAST=$PORT
    fi
    sleep 60
done
