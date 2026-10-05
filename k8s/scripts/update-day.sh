#!/usr/bin/env bash
# The :latest fleet (imagePullPolicy: Always) picks up new images via
# rollout restarts; helm releases are upgraded with the repo's values.
# Pinned images (recyclarr, meilisearch...) update via Renovate PRs —
# merge them, then run this script to apply. The Docker VM compose fleet
# (plex, ollama, jellyfin, searxng, perplexica, nostalgiatv, mcsmanager,
# torrent/gluetun, cline-gateway) is pulled and recreated in the same run —
# only containers whose image digest changed get recreated. NB: a changed
# mcsmanager-daemon image restarts the Minecraft daemons.
#
# Safety built in:
#   1. Cluster reachable before anything else
#   2. radarr restarts FIRST as a canary (DB migrations are the risk) —
#      waits for readiness, greps its logs for errors, aborts if unhealthy
#   3. torrent is excluded from k8s restarts (rolled back to the VM; do not resurrect)
#   4. Every rollout is waited on; failures abort the run
#   5. traefik upgrade handles the hostPort deadlock (deletes the old pod)
#   6. Docker VM: pull + up -d from the repo root (project name!), then
#      a health sweep; only digest-changed containers recreate
#   7. Final sweep: CrashLoop/OOM pods listed + edge spot-check
#
# Usage:
#   k8s/scripts/update-day.sh             # full run (cluster + VM)
#   k8s/scripts/update-day.sh --skip-helm # deployments + VM, no chart upgrades
#   k8s/scripts/update-day.sh --docker-only  # just the Docker VM fleet
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SKIP_HELM=0 SKIP_DOCKER=0 DOCKER_ONLY=0
for a in "$@"; do
    case $a in
        --skip-helm)   SKIP_HELM=1 ;;
        --skip-docker) SKIP_DOCKER=1 ;;
        --docker-only) DOCKER_ONLY=1 ;;
        *) echo "unknown flag: $a" >&2; exit 2 ;;
    esac
done

say() { echo ">>> $*"; }
fail() { echo ">>> ABORT: $*" >&2; exit 1; }

if [[ $DOCKER_ONLY -eq 1 ]]; then
    say "--docker-only: skipping cluster sections (canary/rollouts/helm)"
fi
if [[ $DOCKER_ONLY -eq 0 ]]; then

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
fi # end cluster sections

# --- 4. Docker VM (compose fleet) ------------------------------------------------
# MUST run from the repo root: the project name comes from the root
# docker-compose.yaml include; per-file -f invocations create a foreign
# project and collide (2026-09-21 lesson).
if [[ $SKIP_DOCKER -eq 1 ]]; then
    say "--skip-docker: skipping the Docker VM fleet"
elif ! command -v docker >/dev/null 2>&1; then
    say "docker CLI not present — skipping the Docker VM fleet"
else
    say "docker compose pull (VM fleet: plex, ollama, jellyfin, searxng, perplexica, nostalgiatv, mcsmanager, torrent/gluetun, cline-gateway)..."
    (cd "$REPO" && docker compose pull --quiet) || fail "docker compose pull failed"

    say "docker compose up -d (recreates only digest-changed containers)..."
    (cd "$REPO" && docker compose up -d --remove-orphans) || fail "docker compose up failed"

    say "waiting 25s for containers to settle..."
    sleep 25

    BAD=$(cd "$REPO" && docker compose ps --all --format '{{.Name}}\t{{.State}}\t{{.Health}}' 2>/dev/null \
        | awk -F'\t' '$2 != "running" || ($3 != "" && $3 != "healthy" && $3 != "-")' | head -10 || true)
    if [[ -n $BAD ]]; then
        echo "$BAD" | sed 's/^/    /'
        fail "VM containers not running/healthy after up -d — inspect: docker compose ps"
    fi
    say "VM fleet healthy ($(cd "$REPO" && docker compose ps -q | wc -l) containers running)"
fi


# --- 5. Final sweep --------------------------------------------------------------
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
echo "    - Renovate PRs merged since last run are now live; check the *arr UIs (recyclarr: run the manual job)."
echo "    - romm runs :latest — confirm its UI loads after any recreation (config-coupled)."
