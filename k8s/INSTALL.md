# Kubernetes Install & Migration Guide

End-to-end: build the 3-node K3s cluster, deploy the Wave 0 foundation + the
linkwarden proving-ground stack, then (optionally, when ready) cut the edge
and linkwarden's data over from the Docker VM.

Everything here assumes the layout documented in this repo's `CLAUDE.md`
(Kubernetes Migration section) and the manifests under `k8s/`.

## 0. End state

```
                        *.thenewmans.casa (wildcard DNS -> same public IP)
                                      |
              router port-forwards: 80/443 -> ingress node
                                   32400/tcp -> Docker VM (Plex, unchanged)
                                      |
        +---------------------------+----------------------------+
        |  K3s cluster (3 servers) |  Docker VM 192.168.0.9      |
        |  traefik edge (hostPort) |  plex, tunarr, ollama,      |
        |  linkwarden (Wave 1)     |  perplexica, searxng,       |
        |  *arr + downloaders      |  mcsmanager  (permanent —   |
        |    (Waves 2-3, later)    |  cluster nodes have no GPU) |
        +---------------------------+----------------------------+
                     |
        NFS: 192.168.0.5:/mnt/user/Media (ratchet)
             192.168.0.6:/volume1/Media, /volume3/MediaExpansion (perceptor)
```

| Item | Value |
|---|---|
| Cluster | 3 x K3s servers, embedded etcd (quorum survives one node loss) |
| Docker VM (existing) | `192.168.0.9` — stays up throughout; nothing is removed until Step 8 |
| Ingress node | one cluster node labeled `newman.media/ingress=true` |
| Storage class | `local-path` (K3s built-in) for appdata; static NFS PVs for media |
| Workstation for kubectl/helm | the Docker VM itself (`kubectl`/`helm` already installed there) |

## 1. Prerequisites

- 3 nodes, Ubuntu 22.04/24.04+, 2 GB+ RAM and **120G+ disk** each (50G works
  through Step 8; sizing analysis and Wave 2 growth in §12), same LAN as the VM.
- **Static IPs** for all three nodes (DHCP reservations or static config).
  Etcd membership, the ingress node, and the edge all depend on stable IPs.
- Unique hostnames (they become node names): e.g. `media-k8s-1/2/3`.
- Router access (to move 80/443 port-forwards later — Step 9 only).
- `kubectl` + `helm` on the machine you'll deploy from (the VM has both).

## 2. Node preparation (all three nodes)

```bash
sudo apt-get update && sudo apt-get install -y curl nfs-common
sudo hostnamectl set-hostname media-k8s-1        # 2, 3 on the other nodes
sudo timedatectl set-timezone America/Chicago    # optional, log sanity
```

`nfs-common` is required for mounting the media NFS shares (kubelet performs
the mount on the node itself).

If `ufw` is active, open the K3s ports (simplest for a LAN homelab is
`sudo ufw disable`, but the minimal set):

```bash
sudo ufw allow 6443/tcp          # Kubernetes API
sudo ufw allow 8472/udp          # flannel VXLAN overlay
sudo ufw allow 10250/tcp         # kubelet
sudo ufw allow 2379:2380/tcp     # etcd (server nodes = all three here)
```

The ingress node additionally needs 80/443 free (Traefik binds them as
hostPorts).

## 3. Install the K3s cluster

`--disable=traefik` matters: the edge Traefik is managed by the helm release
in `k8s/helm/`, and the bundled one would fight it. `--disable=servicelb`
drops klipper (unused — the edge uses hostPorts). Flags must be identical on
all servers.

**Node 1 — bootstrap the cluster (embedded etcd):**

```bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --cluster-init --disable=traefik --disable=servicelb
```

Grab the join token:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

**Nodes 2 and 3 — join as servers (3-way etcd quorum):**

```bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --server https://<node1-ip>:6443 \
  --token <NODE_TOKEN> \
  --disable=traefik --disable=servicelb
```

**Verify** (on any node; allow a minute for etcd to converge):

```bash
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes -o wide
# NAME         STATUS   ROLES                       AGE   VERSION
# media-k8s-1  Ready    control-plane,etcd,master   2m    v1.3x
# media-k8s-2  Ready    control-plane,etcd,master   1m    v1.3x
# media-k8s-3  Ready    control-plane,etcd,master   1m    v1.3x

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get pods -A
# All Running/Completed — coredns, metrics-server, local-path-provisioner
```

## 4. Kubeconfig on the deploy machine (the Docker VM)

```bash
mkdir -p ~/.kube && chmod 700 ~/.kube
ssh <node1-ip> sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config
sed -i 's|https://127.0.0.1:6443|https://<node1-ip>:6443|' ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes     # same three Ready nodes, now from the VM
```

From here on, run everything from `/home/dnewman/mediamanagement` on the VM.

## 5. NAS NFS exports

Good news, verified 2026-09-15 with `showmount -e`: **both NAS boxes already
export to the whole `192.168.0.0/24`**, so any cluster node IP is already
permitted — nothing to change on the NAS. The exports in use:

| Purpose | Export |
|---|---|
| ratchet media (Unraid) | `192.168.0.5:/mnt/user/Media` |
| perceptor media (Synology vol1) | `192.168.0.6:/volume1/Media` |
| perceptor expansion (Synology vol3) | `192.168.0.6:/volume3/MediaExpansion` |
| backups: Books + Roms (Synology vol3) | `192.168.0.6:/volume3/Backups` |

(`192.168.0.6` also exports `/volume3/ISO` and `/volume3/proxbackup` — unused here.)

**Verify reachability** with an inline NFS pod (no cluster state needed):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nfs-test
spec:
  restartPolicy: Never
  containers:
    - name: t
      image: busybox:1.36
      command: [sh, -c, "ls /pm/Video/Movies | head -3; ls /rm | head -3; ls /pme/Audio | head -3; ls /bk/Books /bk/Games/Roms/Core_Roms | head -6"]
      volumeMounts:
        - {name: pm, mountPath: /pm}
        - {name: rm, mountPath: /rm}
        - {name: pme, mountPath: /pme}
        - {name: bk, mountPath: /bk}
  volumes:
    - name: pm
      nfs: {server: 192.168.0.6, path: /volume1/Media}
    - name: rm
      nfs: {server: 192.168.0.5, path: /mnt/user/Media}
    - name: pme
      nfs: {server: 192.168.0.6, path: /volume3/MediaExpansion}
    - name: bk
      nfs: {server: 192.168.0.6, path: /volume3/Backups}
EOF
kubectl logs nfs-test          # should list real directories
kubectl delete pod nfs-test
```

If this fails with "access denied by server while mounting", the export ACLs
changed on the NAS since the check above — that error is always NAS-side,
never Kubernetes.

## 6. Deploy the foundation

```bash
cd /home/dnewman/mediamanagement

# 1. Generate the gitignored secret files from .env
k8s/scripts/gen-env.sh

# 2. Edge-transition ConfigMap, Cloudflare secret, static NFS PVs
kubectl apply -k k8s/foundation

# 3. Pick the ingress node and label it BEFORE the traefik install
#    (the pod is pinned by nodeSelector and will hang Pending otherwise)
kubectl label node <ingress-node-name> newman.media/ingress=true

# 4. Traefik edge (config validated against chart 41.5.0)
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n traefik --create-namespace \
  -f k8s/helm/traefik-values.yaml

# 5. NFS CSI driver (serves the static PVs)
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs -n kube-system \
  -f k8s/helm/csi-nfs-values.yaml
```

**Verify:**

```bash
kubectl -n traefik get pods                  # traefik Running on the labeled node
kubectl get pv                               # 3 nfs-* PVs, Available (bound in Wave 2)
kubectl -n traefik port-forward deploy/traefik 9000:9000 &
# http://localhost:9000/dashboard/  — routers list is empty until cutover; fine
```

Nothing user-facing has changed at this point: the Docker VM Traefik still
owns 80/443 and all traffic.

## 7. Deploy linkwarden (empty proving instance)

Runs in parallel with the Docker linkwarden; the real data cut is Step 8.

```bash
kubectl apply -k k8s/linkwarden
kubectl -n linkwarden get pods               # 3/3 Running
kubectl -n linkwarden port-forward svc/linkwarden 3000:3000 &
# http://localhost:3000 -> first-time setup screen = healthy empty instance
```

## 8. Linkwarden data cutover

Stops the compose trio, copies `appdata/linkwarden/{pgdata,meili_data,data}`
(≈12 GB) into the PVCs, restarts the k8s side. Dry-run first:

```bash
docker compose stop linkwarden linkwarden-db linkwarden-search
k8s/scripts/linkwarden-migrate-data.sh              # dry run
k8s/scripts/linkwarden-migrate-data.sh --execute
```

**Verify:** log in at the port-forward, check a search (meili), check AI
tagging on a new bookmark (ollama via the VM), check archived snapshots
(images render). Then decommission the compose services (edit
`compose/bookmarks.yaml`, remove the trio) — old data stays untouched at
`appdata/linkwarden*` as a rollback copy until you're confident.

Note: after stopping the compose trio the VM Traefik has no linkwarden backend
and the subdomain 404s. The interim fix (deployed 2026-09-15): the VM edge
loads `traefik-dyn/transition.yaml` (file provider added to the proxy service
in compose/infrastructure.yaml) and forwards every migrated subdomain
(linkwarden, auth, dash, convertx, zipline, headlamp)
to the cluster edge at https://192.168.0.19 — so they all work
immediately, before the full Step 9 cutover. The VM Traefik issues its own
LE certs for them; first request after adding a host may stall ~10s during
ACME. The file, the two provider args, and the `/dyn` volume mount all
retire at cutover.

## 9. Edge cutover (when ready to serve everything from the cluster)

Reversible: rollback = undo the router port-forward and
`docker compose start proxy`.

**9a. Publish host ports for VM services with none today** (the k8s edge
reaches them by IP):

```yaml
# compose/utilities.yaml -> searxng  (PERMANENT — never migrates)
    ports:
      - "8082:8080"

# compose/ai.yaml -> perplexica  (PERMANENT — GPU-bound via ollama)
    ports:
      - "3002:3000"

```

`docker compose up -d searxng perplexica` to apply.
(nextdash migrated in wave 1 — no temporary port needed anymore.)

**9b. Carry the certs over** (skip to re-issue from scratch):

```bash
kubectl -n traefik cp letsencrypt/acme.json deploy/traefik:/data/acme.json --no-preserve
kubectl -n traefik exec deploy/traefik -- chmod 600 /data/acme.json
kubectl -n traefik rollout restart deploy/traefik
```

**9c. Move the edge:**

```bash
docker compose stop proxy          # frees 80/443 on the VM
```

Then on the router: port-forwards `80/tcp` and `443/tcp`
`192.168.0.9 -> <ingress-node-ip>`. Leave `32400/tcp -> 192.168.0.9` (Plex).
Public IP is unchanged, so cloudflare-ddns needs nothing.

**9d. Verify** — each should answer with its real UI:

```bash
for h in auth radarr sonarr lidarr bazarr sabnzbd torrent seerr tautulli \
         agregarr tunarr cleanuparr maintainerr profilarr titlecardmaker \
         audiobookshelf calibre romm minecraft convertx zipline sync \
         search perplexica linkwarden headlamp rancher; do
  echo -n "$h: "; curl -sIo /dev/null -w '%{http_code}\n' https://$h.thenewmans.casa
done
```

Any 5xx/timeout: `kubectl -n traefik logs deploy/traefik` and the dashboard.

## 10. Ongoing operations

- **Upgrades**: re-run the K3s install command on each node in turn (same
  flags); nodes drain/uncordon automatically. Declarative alternative:
  [system-upgrade-controller](https://docs.k3s.io/upgrades/automated).
- **Etcd backups**: automatic snapshots in
  `/var/lib/rancher/k3s/server/db/snapshots` on each server; copy them off-node
  regularly. Restore: `k3s server --cluster-reset --cluster-reset-restore-path=<path>`.
- **Secrets**: after editing `.env`, re-run `k8s/scripts/gen-env.sh` and
  `kubectl apply -k` the affected kustomization.
- **Reset a botched cluster**: `/usr/local/bin/k3s-killall.sh` +
  `/usr/local/bin/k3s-uninstall.sh` per node, then redo Step 3.
- **Rancher (management VM)**: deployed 2026-09-16 on a separate VM
  (192.168.0.22, single-node k3s **v1.35** — the 2.15.1-on-1.36 pairing is
  broken, see the Rancher removal note below). The media cluster is
  registered as a DOWNSTREAM cluster (`media`, agent in ns cattle-system).
  UI: https://rancher.thenewmans.casa (routed via traefik-dyn → VM :443,
  skip-verify LAN hop; LE cert terminated at the media edge). Rancher runs
  `tls=external` + setting `agent-tls-mode=system-store` so agents trust the
  public LE cert; the first import needed `kubectl -n cattle-system set env
  deploy/cattle-cluster-agent STRICT_VERIFY=false` because the cached
  manifest still carried strict-CA. Kubeconfig for the VM cluster:
  `~/.kube/rancher-vm` (KUBECONFIG=... to target it).
  **Rancher REMOVED from the media cluster 2026-09-15:** v2.15.1 (the only
  release supporting k8s 1.36) deletes the `cluster-admin` ClusterRole ~60s
  after start, then fatals on its own RBAC — verified empirically on a clean
  reinstall; role survives with rancher scaled to 0. If rancher is ever
  removed from a cluster: delete ns cattle-* + cattle CRDs (strip
  finalizers) + the v1.ext.cattle.io APIService, then RECREATE cluster-admin
  (`apiGroups/resources/verbs: ["*"]`, `nonResourceURLs: ["*"]`).

## 11. Roadmap after this guide

| Wave | Contents | Notes |
|---|---|---|
| 1 remainder | authelia (+valkey), nextdash, convertx — DONE 2026-09-15 (ns `auth`, `apps`) | zipline manifests + data migrated, pod blocked on node CPU model (needs x86-64-v2 → Proxmox CPU type `host` + rolling reboot), then uncomment the zipline router in traefik-dyn/transition.yaml |
| 2 | *arr stack in `media` ns | prune + size nodes per §12 first; binds the pre-claimed NFS PVs; same-namespace DNS keeps `http://radarr:7878` URLs working |
| 3 | sabnzbd; gluetun+qbittorrent pod; syncthing (relocate syncs to NFS) | verify gluetun iptables accepts the pod CIDR on 8181 |
| 3b | romm (+mariadb) and calibre-web | unblocked: libraries mount from the `nfs-backups` PV (`/volume3/Backups`) instead of CIFS |
| never | plex, tunarr, ollama, perplexica, searxng, mcsmanager | no GPUs on cluster nodes; mcsmanager needs docker.sock |

## 12. Node storage sizing & Wave 2 prep

Measured 2026-09-15. Node disks hold only appdata PVCs (local-path) + OS/k3s
overhead + container images — media is on NFS and the GPU tier stays on the
VM. Most of the raw appdata payload is regenerable cache:

| Service | Raw | Real state | Notes |
|---|---|---|---|
| lidarr | 57G | ~6G | 47G MediaCover cache + 5G old DB backups |
| titlecardmaker | 37G | ~35G | keep source + generated cards; trim logs |
| romm | 29G | ~29G | resources cache — re-scraping hits quota-limited APIs; keep |
| radarr | 14G | ~1.5G | 13G MediaCover cache |
| linkwarden | 12G | ~1G | 11G orphaned archives (DB verified empty) |
| everything else | ~7.5G | ~7.5G | sonarr, syncthing, agregarr, recyclarr, bazarr, tautulli, authelia, … |
| **Total** | **~155G** | **~80G** | |

Overhead per node: ~4G OS/k3s baseline now, ~10-12G per node after Waves 2-3
images land (arr stack, romm, calibre+ebook-convert are 1-2G each).

**Recommendation: 120G per node** (uniform; measured disks are 50G). Local-path
PVCs are node-pinned, so size for worst-case per-node skew (~70G of state on
one node), not the total. Migrating without the prune below: size ~160G/node
instead. Cheaper alternative: one "stateful" node at ~200G (nodeSelector-pin
the fat singletons) + two lean nodes at ~60G.

Grow before Wave 2 binds PVCs (online, no reboot — verify partition layout
with `lsblk` first; cloud images keep root on partition 3):

```bash
# Proxmox host, per VM:
qm resize <vmid> scsi0 +70G
# in-guest, per node:
sudo growpart /dev/sda 3 && sudo resize2fs /dev/sda3
```

**Prune on the VM before migrating each service** (all cache/derived data —
regenerated on next library scan):

```bash
sudo rm -rf appdata/lidarr/MediaCover/* appdata/radarr/MediaCover/*
sudo bash -c 'cd appdata/lidarr/Backups && ls -t *.zip | tail -n +2 | xargs -r rm -f'
sudo bash -c 'cd appdata/radarr/Backups && ls -t *.zip | tail -n +2 | xargs -r rm -f'
sudo rm -rf appdata/titlecardmaker/logs/*
sudo rm -rf appdata/linkwarden/data/*   # 11G orphaned archives, DB has zero links
```

The same 11G of linkwarden archives was copied into the `linkwarden-data`
PVC on media-k8s-3 during the data cutover — clearing it there frees node
disk too. Inspect first
(`kubectl -n linkwarden exec deploy/linkwarden -- du -sh /data/data/*`),
then clear the orphaned snapshot dir
(`kubectl -n linkwarden exec deploy/linkwarden -- rm -rf /data/data/archives/*`);
local-path is directory-backed, so deletes reclaim real space.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Node `NotReady`, flannel errors | 8472/udp blocked between nodes (ufw) |
| traefik pod `Pending` | ingress node not labeled `newman.media/ingress=true` |
| traefik `CrashLoopBackOff` | something already binds 80/443 on the ingress node |
| Cert issuance loops, `error presenting token` | CF token wrong / `traefik-cloudflare` secret stale (re-run gen-env.sh + apply) |
| `access denied by server while mounting` | NFS export ACLs (Step 5) |
| Pods stuck `ContainerCreating` on NFS PVCs | csi-driver-nfs not installed / node missing `nfs-common` |
| linkwarden AI tagging fails | VM firewall must allow the cluster subnet to reach 192.168.0.9:11434 |
| PVC `Pending` | `storageClassName: local-path` doesn't match your cluster's class (`kubectl get sc`) |
| App crashes citing `AUTHELIA_*` env vars | k8s service-link injection collides with env-greedy apps — set `enableServiceLinks: false` (see k8s/auth/authelia.yaml) |
| Node image crashes on `sharp`/`Unsupported CPU ... require v2 microarchitecture` | Proxmox VM CPU model is `qemu64`-class (no x86-64-v2). Set the VMs' CPU type to `host` in Proxmox (Hardware -> Processor) and reboot nodes ONE AT A TIME (etcd quorum). Known victim: zipline |
| traefik upgrade leaves new pod `Pending` for minutes | hostPort 80/443 + RollingUpdate: old pod holds the ports. It self-resolves at the progress deadline; or `kubectl -n traefik delete pod <old>` to cut over immediately |
| 502/404 on a just-migrated subdomain | a stale forward for it still exists in traefik-dyn/transition.yaml or the foundation ConfigMap — delete the old router (duplicate Host rules = undefined) |
