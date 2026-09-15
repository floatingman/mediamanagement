#!/usr/bin/env bash
# migrate-pvc.sh — copy a directory from the Docker VM into a Kubernetes PVC.
#
# One helper pod per PVC (local-path volumes are node-pinned; the helper
# schedules on the node holding the volume via the PV's node affinity).
#
# Usage:
#   k8s/scripts/migrate-pvc.sh --ns NS --pvc PVC --src DIR [--subpath SP]
#                              [--deploy DEPLOYMENT[,DEPLOYMENT2...]]
#                              [--exclude PATTERN] [--chown UID:GID] [--clear]
#
#   --ns        namespace of the PVC (required)
#   --pvc       PVC name (required)
#   --src       local source directory (required); its CONTENTS land in the
#               mount target (matching tar -C semantics)
#   --subpath   mount the PVC subPath (must mirror the workload's mount)
#   --deploy    comma-separated deployments to scale to 0 for the copy and
#               back to 1 after (strongly recommended: one writer per volume)
#   --exclude   tar --exclude pattern, relative (e.g. `valkey`); repeatable
#   --chown     chown -R the copied tree (e.g. 70:70 for postgres:16-alpine)
#   --clear     wipe the target before copying (strongly recommended: avoids
#               overlaying source data onto a freshly-initialized empty
#               database/AOF dir with stale files)
#
# The docker-compose service owning the same data must already be stopped.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NS= PVC= SRC= SUBPATH= DEPLOYS= CHOWN= CLEAR=0
EXCLUDES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --ns) NS=$2; shift 2 ;;
    --pvc) PVC=$2; shift 2 ;;
    --src) SRC=$2; shift 2 ;;
    --subpath) SUBPATH=$2; shift 2 ;;
    --deploy) DEPLOYS=$2; shift 2 ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    --chown) CHOWN=$2; shift 2 ;;
    --clear) CLEAR=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

for req in NS PVC SRC; do
    [[ -n ${!req} ]] || { echo "ERROR: --$(echo "$req" | tr 'A-Z' 'a-z') is required"; exit 1; }
done
SRC_DIR=$REPO/$SRC
[[ -d $SRC_DIR ]] || { echo "ERROR: $SRC_DIR not found"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: namespace $NS not found"; exit 1; }
kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1 || { echo "ERROR: PVC $PVC missing in $NS"; exit 1; }

echo ">>> Source: $SRC ($(sudo du -sh "$SRC_DIR" | cut -f1))"

HELPER=migrate-$PVC${SUBPATH:+-$(echo "$SUBPATH" | tr / -)}
MOUNT_ARGS="[{name: v, mountPath: /target${SUBPATH:+, subPath: $SUBPATH}}]"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HELPER
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: busybox:1.36
      command: [sh, -c, "sleep 3600"]
      volumeMounts: $MOUNT_ARGS
  volumes:
    - name: v
      persistentVolumeClaim: {claimName: $PVC}
EOF
trap 'kubectl -n "$NS" delete pod "$HELPER" --wait=false >/dev/null 2>&1 || true' EXIT

# Stop writers BEFORE the copy (one writer per volume).
if [[ -n $DEPLOYS ]]; then
    IFS=, read -ra D <<<"$DEPLOYS"
    for d in "${D[@]}"; do
        kubectl -n "$NS" scale deploy/"$d" --replicas=0 >/dev/null
        kubectl -n "$NS" wait --for=delete pod -l "app=$d" --timeout=180s >/dev/null 2>&1 || true
    done
fi

kubectl -n "$NS" wait --for=condition=Ready pod/"$HELPER" --timeout=120s >/dev/null

if [[ $CLEAR -eq 1 ]]; then
    kubectl exec -n "$NS" "$HELPER" -- find /target -mindepth 1 -delete
fi

TAR_ARGS=()
for e in "${EXCLUDES[@]}"; do TAR_ARGS+=(--exclude "$e"); done
sudo tar -C "$SRC_DIR" "${TAR_ARGS[@]}" -cf - . |
    kubectl exec -i -n "$NS" "$HELPER" -- tar -xf - -C /target

if [[ -n $CHOWN ]]; then
    kubectl exec -n "$NS" "$HELPER" -- chown -R "$CHOWN" /target
fi

echo ">>> Copied (target): $(kubectl exec -n "$NS" "$HELPER" -- du -sh /target | cut -f1)"

if [[ -n $DEPLOYS ]]; then
    for d in "${D[@]}"; do
        kubectl -n "$NS" scale deploy/"$d" --replicas=1 >/dev/null
        kubectl -n "$NS" rollout status deploy/"$d" --timeout=180s
    done
fi
echo ">>> Done: $SRC -> $NS/$PVC${SUBPATH:+ (subPath $SUBPATH)}"
