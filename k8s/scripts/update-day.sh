#!/usr/bin/env bash
# update-day.sh — the monthly/monthly-ish image + chart refresh.
#
# The :latest fleet (imagePullPolicy: Always) picks up new images via
# rollout restarts; helm releases are upgraded with the repo's values.
# Pinned images (recyclarr, meilisearch...) update via Renovate PRs —
# merge them, then run this script to apply.
#
# Safety built in:
#   1. Cluster reachable before anything else
#   2. radarr restarts FIRST as a canary (DB migrations are the risk) —
#      waits for readiness, greps its logs for errors, aborts if unhealthy
#   3. torrent is excluded (rolled back to the VM; do not resurrect)
#   4. Every rollout is waited on; failures abort the run
#   5. traefik upgrade handles the hostPort deadlock (deletes the old pod)
#   6. Final sweep: CrashLoop/OOM pods listed + edge spot-check
#
# Usage:
#   k8s/scripts/update-day.sh             # full run
#   k8s/scripts/update-day.sh --skip-helm # deployments only
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SKIP_HELM=0
[[ ${1:-} == "--skip-helm" ]] && SKIP_HELM=1

say() { echo ">>> $*"; }
fail() { echo ">>> ABORT: $*" >&2; exit 1; }

# --- 0. Preflight ------------------------------------------------------------
kubectl get nodes >/dev/null 2>&1 || fail "cluster unreachable"
say "cluster reachable: $(kubectl get nodes --no-headers | grep -c Ready)/$(kubectl get nodes --no-headers | wc -l) nodes Ready"
[[ $(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l) -eq 0 ]] || fail "not all nodes Ready — fix that first"

# --- 1. radarr canary (DB-migration risk lives here) --------------------------
say "restarting radarr as the canary..."
kubectl -n media rollout restart deploy/radarr >/dev/null
kubectl -n media rollout status deploy/radarr --timeout=300s >/dev/null
sleep 10
if kubectl -n media logs deploy/radarr --since=2m 2>/dev/null | grep -qiE 'fatal|migration failed|corrupt'; then
    kubectl -n media logs deploy/radarr --since=2m | grep -iE 'fatal|migration failed|corrupt' | head -5
    fail "radarr canary logged errors — NOT continuing with the rest of the *arr stack. Inspect: kubectl -n media logs deploy/radarr"
fi
say "canary healthy"

# --- 2. Rest of the :latest fleet ---------------------------------------------
# torrent excluded deliberately (gluetun race; runs on the Docker VM).
restart_ns() { # restart_ns <namespace> [exclusions...]
    local ns=$1; shift
    local deps
    deps=$(kubectl -n "$ns" get deploy -o name | sed 's|deployment.apps/||' | grep -vE "^($(IFS=\|; echo "$*"))$" || true)
    [[ -z $deps ]] && return 0
    for d in $deps; do
        say "  $ns/$d"
        kubectl -n "$ns" rollout restart deploy/"$d" >/dev/null
        kubectl -n "$ns" rollout status deploy/"$d" --timeout=300s >/dev/null
    done
}

say "restarting media deployments (torrent excluded)..."
restart_ns media 'torrent'
say "restarting auth/apps/linkwarden deployments..."
restart_ns auth
restart_ns apps
restart_ns linkwarden

# --- 3. Helm releases ----------------------------------------------------------
if [[ $SKIP_HELM -eq 1 ]]; then
    say "--skip-helm: skipping chart upgrades"
else
    say "upgrading helm releases (values from k8s/helm/)..."
    helm repo update >/dev/null 2>&1 || fail "helm repo update failed"

    say "  csi-driver-nfs"
    helm upgrade csi-driver-nfs csi-driver-nfs/csi-driver-nfs -n kube-system \
        -f "$REPO/k8s/helm/csi-nfs-values.yaml" >/dev/null

    say "  cert-manager"
    helm upgrade cert-manager jetstack/cert-manager -n cert-manager \
        --set crds.enabled=true >/dev/null

    say "  traefik (edge — brief hostPort swap)"
    helm upgrade traefik traefik/traefik -n traefik \
        -f "$REPO/k8s/helm/traefik-values.yaml" >/dev/null
    # hostPort deadlock: the new pod stays Pending while the old holds 80/443.
    # Wait briefly; if stuck, delete the running pod to cut over.
    if ! kubectl -n traefik rollout status deploy/traefik --timeout=90s >/dev/null 2>&1; then
        OLD=$(kubectl -n traefik get pods --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [[ -n $OLD ]] && { say "  hostPort deadlock — deleting old pod $OLD"; kubectl -n traefik delete pod "$OLD" >/dev/null; }
        kubectl -n traefik rollout status deploy/traefik --timeout=180s >/dev/null
    fi
fi

# --- 4. Final sweep --------------------------------------------------------------
say "post-update sweep..."
BAD=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed|Succeeded' | grep -vE 'torrent' | head -10 || true)
if [[ -n $BAD ]]; then
    echo "$BAD"
    say "WARNING: non-running pods above (torrent excluded) — inspect before leaving."
else
    say "all pods Running/Completed"
fi

EDGE=$(curl -sk -o /dev/null -w '%{http_code}' --resolve auth.thenewmans.casa:443:192.168.0.19 --max-time 10 https://auth.thenewmans.casa || echo 000)
say "edge spot-check (auth via 192.168.0.19): HTTP $EDGE"

say "update day complete. Reminders:"
echo "    - Rancher VM charts: KUBECONFIG=~/.kube/rancher-vm helm upgrade rancher rancher-latest/rancher -n cattle-system --version <new> -f k8s/helm/rancher-values.yaml"
echo "    - Renovate PRs merged since last run are now live; check the *arr UIs."
echo "    - torrent/gluetun live on the VM: docker compose pull vpn torrent && docker compose up -d vpn torrent"
