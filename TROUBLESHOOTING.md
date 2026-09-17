# Troubleshooting Guide — Docker VM + Kubernetes

Symptom-first reference for both environments. Every entry here comes from a
real incident in this repo (most during the 2026-09-15/16 k8s migration).
For migration mechanics see `k8s/INSTALL.md`; for agent-mistake postmortems
see `MISTAKES.md`.

## 0. Triage: where does a service live?

```bash
# Cluster (namespaces: media, auth, apps, linkwarden, traefik, headlamp)
kubectl get pods -A | grep -v Running
# Docker VM (still hosts: plex, tunarr, ollama, perplexica, searxng, mcsmanager)
docker compose ps
```

Traffic path pre-§9-cutover: internet → router :80/443 → **VM traefik** →
either a docker container OR `traefik-dyn/transition.yaml` forward →
**cluster traefik** (192.168.0.19) → pod. A broken subdomain can fail at any
of those hops — check BOTH edges:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://SERVICE.thenewmans.casa   # public
curl -sk -o /dev/null -w '%{http_code}\n' --resolve SERVICE.thenewmans.casa:443:192.168.0.19 https://SERVICE.thenewmans.casa  # cluster edge direct
```

## 1. Edge / routing

| Symptom | Cause | Fix |
|---|---|---|
| 404 on a just-migrated subdomain | No router at either edge: the ConfigMap vm-forward was stripped but no `traefik-dyn` forward or IngressRoute exists yet | Add the forward (see §8 of INSTALL.md) or the IngressRoute; hot-reloads in ~5s |
| 404/502 that "should work" | **Duplicate Host rules** — a stale vm-forward in `traefik-external-services.yaml` (or `traefik-dyn/`) competes with the new IngressRoute; routing is undefined and the dead forward often wins | Delete the old router+service from BOTH files the moment a service gets an IngressRoute |
| 503 after node reboot | App pod crashlooped booting before its DB finished restart (linkwarden P1001 pattern) | `kubectl -n NS rollout restart deploy/APP` — pure boot-order race, no data issue |
| traefik pod `Pending` for minutes on helm upgrade | hostPort 80/443 + RollingUpdate: old pod holds the ports | Waits out at the progress deadline, or `kubectl -n traefik delete pod <old>` to cut over now |
| Cert errors / issuance loops | `traefik-cloudflare` secret stale vs `.env` | `k8s/scripts/gen-env.sh && kubectl apply -k k8s/foundation` |
| First request to a new host stalls ~10s | VM traefik issuing its LE cert (DNS-01) | One-time; retry |

**Edge rollback** (undo a bad cutover): `docker compose start proxy` +
router port-forwards 80/443 back to 192.168.0.9.

## 2. Auth (authelia)

| Symptom | Cause | Fix |
|---|---|---|
| Gated services 302-loop or 500 after authelia changes | Middleware wiring split across two edges: VM labels use `authelia@file` (traefik-dyn middlewares section); cluster uses the CRD `authelia@kubernetescrd` (k8s/auth/middleware.yaml) | Check both definitions point at a live authelia; VM-side address is the NodePort `http://192.168.0.19:30991` until §9 |
| Authelia crashloops citing `AUTHELIA_*_SERVICE_HOST` env | k8s service-link injection collides with authelia's env-prefix-as-config parsing | `enableServiceLinks: false` in the pod spec (already set in k8s/auth/authelia.yaml) |
| Logins lost on restart | Session valkey down | Check `authelia-valkey` deployment + PVC in ns `auth` |

## 3. Storage

### NFS (media shares)

| Symptom | Cause | Fix |
|---|---|---|
| `access denied by server while mounting` | Export ACLs on the NAS | Both boxes export to 192.168.0.0/24 (verified 2026-09-15); re-check Unraid Shares→NFS / Synology Control Panel→File Services→NFS |
| Pod can't create a dir that `sudo mkdir` made fine | **ratchetmedia squashes root**; the sudo-made dir is anon-owned and uid 1000 can't write into it | `sudo rmdir` it, `mkdir` as dnewman (uid 1000), then copy |
| App writes fail as root | Same root-squash | Run pods with PUID=1000 env (LSIO s6 drops privileges — keep compose parity) |
| `subPath` mount errors | SubPath dir must already exist on the share | NFS test pod (INSTALL.md §5) lists every subPath before wave deploys |
| NFS writes tear: files come back NUL-filled (`invalid load key, '\x00'` on reload), bursts of app-side I/O errors for ~1 min | **Failing array disk on the NAS** — Ratchet `sde` (WD80EFPX 8TB, array disk `bigmama8`) threw live read/write I/O errors from 2026-09-16 13:11; user-share I/O landing on it stalls/tears. Affected every NFS consumer, NOT a k8s regression | `ssh -p 2222 root@192.168.0.5 'dmesg -T | grep "I/O error"'`. NB: Ratchet's array is **parity-less** (7 independent single-device btrfs disks, both parity slots empty, mdNumDisks=0 — verified 2026-09-17; the believed "btrfs raid6" does not exist), so bigmama8's data was unrecoverable and was lost with the disk. Parity drive was recommended. Also: Ratchet's `/var/log/syslog` has been 0 bytes since 09-16 (rsyslogd running but writing nothing) — use `dmesg`, not syslog, on the NAS |
| After an Unraid **array stop/start** (system stays up!): every k8s pod with a ratchetmedia mount sees `Stale file handle`, sabnzbd PP fails (`Cannot create final folder ...`), queue pauses | Array restart invalidates NFSv3 file handles; the CSI mounts do not self-heal | `kubectl -n media rollout restart deploy/sabnzbd deploy/radarr deploy/sonarr deploy/lidarr deploy/bazarr deploy/titlecardmaker deploy/syncthing` (the nfs-ratchetmedia consumers), then resume the sabnzbd queue and Retry the failed history item — job data survives on the node-local `/incomplete`. Verify export health first: `ssh -p 2222 root@192.168.0.5 'exportfs -v; grep mdState /var/local/emhttp/var.ini'` |

Rule: **SQLite appdata stays on local-path PVCs, never NFS** (corruption risk);
**sabnzbd's incomplete dir is node-local too** (see §4) — the `__ADMIN__`
pickles + article assembly are the same class of must-not-tear state;
media files on the NFS PVs at compose-identical in-container paths.

### local-path PVCs

| Symptom | Cause | Fix |
|---|---|---|
| PVC `Pending` forever, no error | WaitForFirstConsumer — binds when a pod mounts | Normal; start the workload or a helper pod |
| Pod can't schedule with its PVC (`node affinity conflict`) | local-path PVs are **node-pinned** to wherever they first bound | The pod must run on that node (scheduler handles it); a helper mounting the same PVC must too — this is why `migrate-pvc.sh` uses one helper per PVC |
| Node lost = PVC lost | Directory lives on that node's disk | Accepted tradeoff (see INSTALL.md §12); etcd snapshots don't cover local-path data |

### Migrating data into PVCs

Small (<2G): `k8s/scripts/migrate-pvc.sh --ns NS --pvc PVC --src appdata/X --clear`.
Large multi-GB: the kubectl-exec tar stream is fragile — **rsync directly to
the PV's node directory**: get node+path via
`kubectl get pv $(kubectl -n NS get pvc PVC -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]} {.spec.local.path}'`
then `rsync -a --rsync-path="sudo rsync" src/ dnewman@NODE:PATH/` (run as
dnewman — sudo rsync uses root's missing ssh keys).

## 4. Downloaders (the deep water)

### gluetun in k8s (torrent pod)

| Symptom | Cause | Fix |
|---|---|---|
| DNS dead in pod, tunnel never comes up, log spams `adding ip rule 101 ... file exists` every 4 min | **K8s-specific**: stale `ip rule table 51820` in the pod netns (gluetun-wiki/kubernetes.md) | initContainer + postStart clear the rules (in torrent.yaml since 2026-09-16); Recreate strategy |
| `sendmmsg: message too long` in gluetun log; DNS works but big packets (trackers, HTTPS bodies) die | MTU sandwich: flannel VXLAN (1450) + WireGuard overhead < gluetun's discovered 1420 | `WIREGUARD_MTU=1320` env. Note: `VPN_MTU` does not exist; discovery re-runs on reconnects, so a postStart loop loses the race |
| gluetun OOM (exit 137) | 256Mi too small under userspace-wg load | 512Mi limit |
| WebUI unreachable through the Service | gluetun firewall INPUT | `FIREWALL_INPUT_PORTS=8181`; it also auto-allows the pod CIDR |
| Container won't stop / node acts weird after many restarts | An infinite background loop in postStart blocks container exit and can wedge containerd | Don't daemonize in lifecycle hooks; if wedged: `sudo systemctl restart k3s` on that node |
| GSP docker mod fails (`Invalid tarball`) | Its ghcr fetch is broken upstream | The port-sync sidecar replaces it (reads gluetun's apikey from its own volume, endpoint `/v1/portforward` — NOT `/v1/openvpn/portforwarded`, which the auth role doesn't cover) |

Tunnel health checks: `curl -4/-6 https://ifconfig.me` from the port-sync
container (both should show ProtonVPN); `ip link show tun0` for MTU.

### qbittorrent

| Symptom | Cause | Fix |
|---|---|---|
| Trackers stuck "Not contacted yet" for hours | `announce_to_all_trackers` defaults false; with ~20 tier-0 trackers qB announces ONE per interval | `POST /api/v2/app/setPreferences` `{"announce_to_all_trackers":true}` via localhost API (persists in conf) |
| Tracker errors "Operation not permitted" (stale-looking) | Cached failures from a broken-network window | Clear with a rollout restart once the network is verified healthy |
| Old eXoDOS-era trackers show dead | They ARE dead (2015 retrackers) | Working set: opentrackr, demonii, stealth.si, gbitt, bittor, exodus |
| Listening port never matches VPN forwarded port | NAT-PMP hasn't granted yet, or sidecar idle | `kubectl -n media logs deploy/torrent -c port-sync` — expect `set qBittorrent listen_port=NNNNN` |

### sabnzbd

| Symptom | Cause | Fix |
|---|---|---|
| Queue idle forever, log shows only `Found idle job` / `Resetting bad trylist` with **zero server lines** | **Parked servers**: sabnzbd deactivates news servers after a connection-failure burst and never retries | `kubectl -n media rollout restart deploy/sabnzbd` — servers reconnect, queue drains |
| 100%-downloaded jobs stuck "Downloading" + an unrar running with ~0 CPU for ages | Direct Unpack outran a stalled download; unrar hung at a missing volume boundary holding the single post-proc slot | `kubectl -n media exec deploy/sabnzbd -- sh -c 'ps aux | grep unrar'` then kill the PID; restart sabnzbd |
| "Article ... unavailable on all servers, discarding" | Retention misses — normal for old posts | Verify the release plays; let *arr import decide |
| After an NFS hiccup: jobs keep failing every retry, log shows `Loading .../__ADMIN__/SABnzbd_nzf_* failed` → `UnpicklingError: invalid load key, '\x00'` → `Error importing NzbFile` → `Ending job`; *arr re-grabs in a loop until one retry lands | NFS server lost in-flight writes (see §3 torn-writes row) NUL-filling the job's admin pickles; the poisoned `__ADMIN__` state fails to import on every retry | Incomplete dir is now node-local (`sabnzbd-incomplete` PVC, `download_dir=/incomplete`) so in-flight state never rides NFS. For already-poisoned jobs: delete the job's dir under the old incomplete path so the next re-grab starts clean |

## 5. *arr stack

| Symptom | Cause | Fix |
|---|---|---|
| "Download client unavailable" after migration | Client URLs use compose DNS names (`http://sabnzbd:8080`) that died when apps left the docker network | Selector-less Service+Endpoints stubs (pattern in git history, `vm-backends.yaml`); replaced automatically when the downloader itself migrates |
| Library paths broken after migration | Path parity violated | Mounts must reproduce compose's in-container paths exactly (radarr: /media,/ratchetmedia,/downloads,/torrentdownloads etc.) |
| titlecardmaker ImagePullBackOff on ghcr | Image is in a **private registry** | Secret `ghcr-tcm` (docker-registry type) in ns media, from the VM's `~/.docker/config.json` ghcr auth |
| recyclarr not running | It's a CronJob now (03:00 daily) | `kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual` |

## 6. Cluster core (k3s)

| Symptom | Cause | Fix |
|---|---|---|
| Joining server crashloops `failed to bootstrap cluster data: etcd disabled` | Node1 was installed WITHOUT `--cluster-init` (sqlite datastore, no etcd to join) | Uninstall k3s on all nodes, reinstall node1 with `--cluster-init --disable=traefik --disable=servicelb`, pin one version across nodes |
| Node NotReady, flannel errors | 8472/udp blocked between nodes | ufw rules (INSTALL.md §2) |
| Node image crashes citing `Unsupported CPU ... require v2 microarchitecture` | Proxmox CPU type `qemu64`-class lacks x86-64-v2 | Proxmox CPU type `host`, reboot nodes one at a time (etcd quorum) |
| Pods Pending after mass changes | etcd/controller churn | `kubectl get events --sort-by=.lastTimestamp | tail` |

## 7. Rancher (management VM 192.168.0.22)

| Symptom | Cause | Fix |
|---|---|---|
| Rancher crashloops; `cluster-admin` ClusterRole vanished | **2.15.1-on-k8s-1.36 deletes cluster-admin** ~60s after start (verified empirically; ≤2.14.3 refuses 1.36) | Run Rancher on its own VM at k8s ≤1.35 (current setup). Cleanup drill for an affected cluster: delete ns cattle-*, strip CRD finalizers + delete cattle CRDs, delete v1.ext.cattle.io APIService, recreate cluster-admin with wildcard rules |
| Bootstrap password 401 on a fresh install | Either first-login was interrupted (admin user exists with empty username — check `kubectl get users.management.cattle.io`) or the install predated completed setup | Delete the husk user, set `first-login=true`, restart rancher; test the password via the API before touching anything else |
| Agent won't connect: `x509: certificate signed by unknown authority` | Agent pinned Rancher's self-signed CA while the public edge serves Let's Encrypt | `tls=external` on the chart (clear `cacerts` setting via `--as=system:serviceaccount:cattle-system:rancher-webhook-sudo --as-group=system:masters` — the webhook otherwise blocks it) + setting `agent-tls-mode=system-store`; cached import manifests may still carry `STRICT_VERIFY=true` → `kubectl -n cattle-system set env deploy/cattle-cluster-agent STRICT_VERIFY=false` |

## 8. Docker-side (the VM)

| Symptom | Cause | Fix |
|---|---|---|
| `no such service: convertx` | The compose service key is typo'd `covertx` (container_name is convertx) | `docker compose stop covertx ...` |
| Restarted containers force re-login everywhere (pre-2026-09-14) | Authelia had no session backend | Fixed: authelia-valkey with AOF |
| gluetun wedges on healthcheck restarts in kernelspace wg | Known on this setup | `WIREGUARD_IMPLEMENTATION=userspace` (kept in k8s too) |
| Plex remote access broken behind bridge networking | Docker NAT traps UPnP | Plex stays on host networking, port-forward 32400/tcp → 192.168.0.9 — permanently on the VM |
| Manual fstab/sed surgery | See MISTAKES.md — dry-run against a copy first | Never hand-roll nested character classes |

**Rolling a service back to docker** (migration rollback): stop the k8s
deployment (`kubectl -n NS scale deploy/X --replicas=0`), restore its router
(ConfigMap vm-forward or docker labels), `docker compose start X`. Appdata
in `appdata/` is never deleted by migrations.

## 9. Cheat sheet

| Task | Docker | Kubernetes |
|---|---|---|
| Logs | `docker logs -f NAME` | `kubectl -n NS logs -f deploy/NAME` (add `-c CONTAINER` for pods) |
| Restart | `docker compose restart X` | `kubectl -n NS rollout restart deploy/X` |
| Shell in | `docker exec -it NAME sh` | `kubectl -n NS exec deploy/X -- sh` |
| Status | `docker compose ps` | `kubectl -n NS get pods` |
| Config | compose/*.yaml + appdata | k8s/*/  (kustomize; `kubectl apply -k`) |
| Secrets | .env | `k8s/*/env.txt` via gen-env.sh → k8s Secrets |
| Data | appdata/X | PVCs (local-path, node-pinned) + NFS PVs |

Rancher VM cluster: `KUBECONFIG=~/.kube/rancher-vm kubectl ...`
