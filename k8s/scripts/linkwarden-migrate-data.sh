#!/usr/bin/env bash
# linkwarden-migrate-data.sh — cut linkwarden's data over from the Docker VM
# to the Kubernetes deployment.
#
# Copies appdata/linkwarden/{pgdata,meili_data,data} into the k8s PVCs
# (linkwarden-pgdata, linkwarden-meili, linkwarden-data), with the k8s
# deployments scaled to zero so nothing touches the volumes mid-copy. The
# docker compose stack must already be stopped — one writer per volume.
#
# Usage:
#   k8s/scripts/linkwarden-migrate-data.sh            # dry run (prints steps)
#   k8s/scripts/linkwarden-migrate-data.sh --execute  # actually copies
#
# Prereqs: kubectl pointed at the cluster, k8s/linkwarden applied
# (kubectl apply -k k8s/linkwarden), sudo for reading the root-owned pgdata.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NS=linkwarden
SRC=$REPO/appdata/linkwarden
EXECUTE=0
[[ ${1:-} == "--execute" ]] && EXECUTE=1

for d in pgdata meili_data data; do
    [[ -d $SRC/$d ]] || { echo "ERROR: $SRC/$d not found"; exit 1; }
done

kubectl get ns "$NS" >/dev/null 2>&1 ||
    { echo "ERROR: namespace $NS not found — run: kubectl apply -k k8s/linkwarden"; exit 1; }

for pvc in linkwarden-pgdata linkwarden-meili linkwarden-data; do
    kubectl -n "$NS" get pvc "$pvc" >/dev/null 2>&1 ||
        { echo "ERROR: PVC $pvc missing in namespace $NS"; exit 1; }
done

# Refuse to copy out from under a live writer on the compose side.
if docker compose -f "$REPO/docker-compose.yaml" ps --status running 2>/dev/null |
    grep -qE 'linkwarden'; then
    echo "ERROR: linkwarden containers still running — stop them first:"
    echo "  cd $REPO && docker compose stop linkwarden linkwarden-db linkwarden-search"
    exit 1
fi

echo ">>> Source data:"
sudo du -sh "$SRC/pgdata" "$SRC/meili_data" "$SRC/data"

# Copy a local dir into a path inside the helper pod. pgdata is root-owned on
# the VM (postgres uid 70), so the local tar runs under sudo.
copy_dir() { # copy_dir <local-dir> <pod-path>
    sudo tar -C "$1" -cf - . | kubectl exec -i -n "$NS" lw-migrate -- tar -xf - -C "$2"
}

scale() { # scale <0|1>
    kubectl -n "$NS" scale deploy/linkwarden deploy/linkwarden-db deploy/linkwarden-search --replicas="$1" >/dev/null
}

HELPER_MANIFEST=$(cat <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: lw-migrate
  namespace: linkwarden
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: busybox:1.36
      command: [sh, -c, "sleep 3600"]
      volumeMounts:
        # subPath must mirror the postgres deployment's mount (postgres.yaml)
        - {name: pgdata, mountPath: /target/pgdata, subPath: pgdata}
        - {name: meili, mountPath: /target/meili_data}
        - {name: data, mountPath: /target/data}
  volumes:
    - name: pgdata
      persistentVolumeClaim: {claimName: linkwarden-pgdata}
    - name: meili
      persistentVolumeClaim: {claimName: linkwarden-meili}
    - name: data
      persistentVolumeClaim: {claimName: linkwarden-data}
EOF
)

if [[ $EXECUTE -ne 1 ]]; then
    echo ">>> DRY RUN — steps that would run:"
    echo "    1. kubectl -n $NS scale deploy/{linkwarden,linkwarden-db,linkwarden-search} --replicas=0"
    echo "    2. run helper pod lw-migrate mounting the three PVCs"
    echo "    3. copy $SRC/pgdata     -> PVC linkwarden-pgdata (subPath pgdata), chown 70:70"
    echo "    4. copy $SRC/meili_data -> PVC linkwarden-meili,              chown 1000:1000"
    echo "    5. copy $SRC/data       -> PVC linkwarden-data,               chown 1000:1000"
    echo "    6. delete helper, scale deployments back to 1, wait for rollout"
    echo ">>> Re-run with --execute to perform the migration."
    exit 0
fi

echo ">>> Scaling k8s linkwarden deployments to zero..."
scale 0
for lbl in linkwarden linkwarden-db linkwarden-search; do
    kubectl -n "$NS" wait --for=delete pod -l "app=$lbl" --timeout=180s >/dev/null 2>&1 || true
done

echo ">>> Starting helper pod..."
kubectl apply -f - <<<"$HELPER_MANIFEST" >/dev/null
kubectl -n "$NS" wait --for=condition=Ready pod/lw-migrate --timeout=120s >/dev/null

echo ">>> Copying pgdata (postgres files, via sudo tar)..."
copy_dir "$SRC/pgdata" /target/pgdata
echo ">>> Copying meili_data..."
copy_dir "$SRC/meili_data" /target/meili_data
echo ">>> Copying data (12G of snapshots — this is the slow one)..."
copy_dir "$SRC/data" /target/data

echo ">>> Fixing ownership (postgres alpine uid 70; meili/linkwarden uid 1000)..."
kubectl exec -n "$NS" lw-migrate -- chown -R 70:70 /target/pgdata
kubectl exec -n "$NS" lw-migrate -- chown -R 1000:1000 /target/meili_data /target/data

echo ">>> Copied sizes (compare against the source listing above):"
kubectl exec -n "$NS" lw-migrate -- du -sh /target/pgdata /target/meili_data /target/data

kubectl -n "$NS" delete pod lw-migrate --wait=false >/dev/null

echo ">>> Scaling back up..."
scale 1
kubectl -n "$NS" rollout status deploy/linkwarden-db --timeout=180s
kubectl -n "$NS" rollout status deploy/linkwarden-search --timeout=180s
kubectl -n "$NS" rollout status deploy/linkwarden --timeout=180s

echo ">>> Done. Verify:"
echo "    kubectl -n $NS get pods"
echo "    kubectl -n $NS port-forward svc/linkwarden 3000:3000  # then http://localhost:3000"
echo ">>> Old data is untouched at $SRC — remove the compose services once"
echo "    you've confirmed logins/search/AI-tagging work on the cluster."
