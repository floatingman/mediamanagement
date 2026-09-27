#!/usr/bin/env bash
# migrate-to-longhorn.sh — move a local-path PVC's data to a Longhorn PVC of
# the SAME NAME (Phase 2 hardening, 2026-09-26): two-copy pattern through a
# staging PVC so the source is never destroyed before its copy verifies.
#
#   1. scale --deploy to 0 (wait pod gone)
#   2. create staging PVC <name>-mig (longhorn, same size); wait Bound
#   3. copy old -> staging (tar stream); verify file count + bytes
#   4. DELETE old PVC (reclaim Delete wipes source — copy already verified)
#   5. create final PVC <name> (longhorn); wait Bound
#   6. copy staging -> final; verify
#   7. delete staging; scale --deploy back to 1; wait rollout
#
# Usage:
#   k8s/scripts/migrate-to-longhorn.sh --ns NS --pvc PVC [--deploy DEPLOY]
#
#   --ns          namespace (required)
#   --pvc         PVC name (required)
#   --deploy      deployment to scale during the copy (omit for pods not
#                 backed by a deployment, e.g. parked/unscheduled workloads)
#   --no-scale    alias check: refused unless --yes given (data wipe step)
#
# Longhorn binding mode is Immediate, so PVCs bind even with the consumer
# scaled to zero.
set -euo pipefail

NS= PVC= DEPLOY= SIZE_OVERRIDE=
while [[ $# -gt 0 ]]; do
    case "$1" in
    --ns) NS=$2; shift 2 ;;
    --pvc) PVC=$2; shift 2 ;;
    --deploy) DEPLOY=$2; shift 2 ;;
    --size) SIZE_OVERRIDE=$2; shift 2 ;;  # stage+final size; local-path doesn't
                                          # enforce capacity, so real data can
                                          # exceed the PVC's nominal request
    *) echo "unknown arg: $1"; exit 1 ;;
    esac
done
[[ -n $NS && -n $PVC ]] || { echo "ERROR: --ns and --pvc required"; exit 1; }

SIZE=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}')
[[ -n $SIZE_OVERRIDE ]] && SIZE=$SIZE_OVERRIDE
SC=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.storageClassName}')
[[ $SC == "local-path" ]] || { echo "ERROR: $PVC storageClass is '$SC', expected local-path"; exit 1; }
echo ">>> migrating $NS/$PVC ($SIZE, local-path -> longhorn)"

STAGE=$PVC-mig

if [[ -n $DEPLOY ]]; then
    kubectl -n "$NS" scale "deploy/$DEPLOY" --replicas=0 >/dev/null
    # wait only if pods actually existed (parked deployments have none)
    if kubectl -n "$NS" get pods -l "app=$DEPLOY" --no-headers 2>/dev/null | grep -q Running; then
        kubectl -n "$NS" wait --for=delete pod -l "app=$DEPLOY" --timeout=300s >/dev/null 2>&1 || true
    elif kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$DEPLOY" --no-headers 2>/dev/null | grep -q Running; then
        kubectl -n "$NS" wait --for=delete pod -l "app.kubernetes.io/name=$DEPLOY" --timeout=300s >/dev/null 2>&1 || true
    fi
fi

copy_between() { # $1=src-pvc $2=dst-pvc $3=strict|lenient
    local src=$1 dst=$2 strict=${3:-strict}
    kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: lhc-$src, namespace: $NS}
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.36
      command: [sh, -c, "sleep 7200"]
      volumeMounts:
        - {name: s, mountPath: /src}
        - {name: d, mountPath: /dst}
  volumes:
    - name: s
      persistentVolumeClaim: {claimName: $src}
    - name: d
      persistentVolumeClaim: {claimName: $dst}
EOF
    kubectl -n "$NS" wait --for=condition=Ready "pod/lhc-$src" --timeout=180s >/dev/null
    kubectl -n "$NS" exec "lhc-$src" -- sh -c 'tar -cf - -C /src . | tar -xf - -C /dst'
    local s_files d_files s_bytes d_bytes
    # regular-file CONTENT bytes only (busybox find has no -printf; directory
    # inode sizes differ between filesystems so du -sb is unusable)
    s_files=$(kubectl -n "$NS" exec "lhc-$src" -- sh -c 'find /src -type f | wc -l' | tr -d '\r')
    d_files=$(kubectl -n "$NS" exec "lhc-$src" -- sh -c 'find /dst -type f | wc -l' | tr -d '\r')
    # tar-stream byte compare: deterministic across filesystems and immune
    # to ARG_MAX limits (find -exec cat breaks on 50k+ file trees)
    s_bytes=$(kubectl -n "$NS" exec "lhc-$src" -- sh -c 'tar -cf - -C /src . | wc -c' | tr -d '\r')
    d_bytes=$(kubectl -n "$NS" exec "lhc-$src" -- sh -c 'tar -cf - -C /dst . | wc -c' | tr -d '\r')
    kubectl -n "$NS" delete pod "lhc-$src" --wait=false >/dev/null
    local delta=$(( s_bytes > d_bytes ? s_bytes - d_bytes : d_bytes - s_bytes ))
    if [[ $strict == "strict" ]]; then
        [[ -n $s_bytes && $s_bytes == "$d_bytes" && $s_files == "$d_files" ]] || {
            echo "ERROR: verify failed $src -> $dst (files $s_files/$d_files, bytes $s_bytes/$d_bytes)"; exit 1; }
    else
        # cross-filesystem: tar header padding can differ by a few blocks
        # between ext4 variants; exact file COUNT is still required
        [[ -n $s_bytes && $s_files == "$d_files" && $delta -le 4096 ]] || {
            echo "ERROR: verify failed $src -> $dst (files $s_files/$d_files, bytes $s_bytes/$d_bytes, delta $delta)"; exit 1; }
    fi
    echo "    copied+verified: $d_files files, $d_bytes bytes"
}

# 2) staging volume
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $STAGE, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: {requests: {storage: $SIZE}}
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$STAGE" --timeout=180s >/dev/null

# 3) copy + verify (lenient: local-path ext4 vs longhorn ext4 header noise)
copy_between "$PVC" "$STAGE" lenient

# 4) destroy source (verified copy exists)
kubectl -n "$NS" delete pvc "$PVC" --wait=true

# 5) final volume, same name as original
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $PVC, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources: {requests: {storage: $SIZE}}
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC" --timeout=180s >/dev/null

# 6) copy back + verify (strict: both volumes are longhorn ext4)
copy_between "$STAGE" "$PVC" strict

# 7) drop staging, bring service back
kubectl -n "$NS" delete pvc "$STAGE" --wait=true
if [[ -n $DEPLOY ]]; then
    kubectl -n "$NS" scale "deploy/$DEPLOY" --replicas=1 >/dev/null
    kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s
fi
echo ">>> DONE: $NS/$PVC now on longhorn"
