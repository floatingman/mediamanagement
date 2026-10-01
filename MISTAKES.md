# MISTAKES.md
Review relevant entries before planning or editing code.
Add an entry after a confirmed mistake or user correction.
Keep entries short, specific, and project-related.
Merge repeated mistakes instead of creating duplicates.
Do not record transient tool failures or unverified guesses.
## Entry format
### [YYYY-MM-DD] [Short title]
**Mistake:** [What the agent did wrong]
**Root cause:** [Why the decision failed]
**Prevention:** [The rule to apply next time]
**Verification:** [How to confirm the mistake was avoided]

### [2026-09-04] sed bracket-class nesting bug in switch-perceptor-to-nfs.sh
**Mistake:** Wrote `[^[#[:space:]]]` in the fstab-commenting sed pattern; it silently matched nothing, so the flip script would have appended NFS lines while leaving the old CIFS lines active.
**Root cause:** POSIX bracket expressions do not nest — the inner `]` closes the class. Intended "not # and not whitespace" is `[^#[:space:]]`.
**Prevention:** Never hand-roll nested-looking character classes; dry-run every fstab/sed mutation against a copy of the real file before shipping a script that edits it.
**Verification:** Dry-run of the script's seds on `/tmp/fstab.test` now prefixes both perceptormedia CIFS lines with `#`.

### [2026-09-04] `grep -c` fallthrough doubled gate output in switch-ratchet-to-nfs.sh
**Mistake:** `$(cmd 2>/dev/null || echo 0)` printed `0` from grep AND `0` from the fallback (grep exits 1 on zero matches), making `[[` throw a syntax error and silently skip the unrar gate.
**Root cause:** grep -c always prints a count; the `|| echo 0` fallback was redundant and corrupted the variable.
**Prevention:** For count-style probes use `VAR=$(cmd) || VAR=0` so the fallback replaces, never appends.
**Verification:** Re-ran gate logic: single numeric value, `[[` comparison clean.

### [2026-09-04] Whole-file write followed chezmoi symlink and clobbered settings
**Mistake:** Treated `~/.omp/agent/config.yml` as a new empty file (dir listing showed `0B`) and overwrote it, destroying 31 lines of live omp settings (model roles, memory backend, theme).
**Root cause:** The path is a symlink into the chezmoi source tree (`files/omp/agent/config.yml`); writes follow it, and the `0B` listing was the link's display size, not the target's.
**Prevention:** Before any home-dir config write, `ls -la`/`readlink -f` the path and check `chezmoi managed`. Never assume a 0-byte listing means empty regular file.
**Verification:** `git diff HEAD~2 HEAD -- files/omp/agent/config.yml` shows only the intended +3 lines; `omp config get modelRoles` returns all three roles.

### [2026-09-15] Unvalidated k8s YAML/manifests shipped half-checked
**Mistake:** Wrote traefik dynamic-config flow mappings as `titlecardmaker:{rule: ...}` (no space after the colon, so YAML parsed `titlecardmaker:{rule` as the key), and guessed helm values keys (`ports.web.redirections`, `extraVolumes`) that the current chart schema rejects.
**Root cause:** Embedded YAML inside ConfigMaps and helm chart schemas were never parsed against a real consumer — eyeballing flow-style YAML hides key errors, and chart values keys move between chart versions.
**Prevention:** For every k8s scaffold: `kubectl kustomize` the overlays, yaml-parse any ConfigMap-embedded config, and `helm template` with the exact values file BEFORE calling it done.
**Verification:** kustomize renders clean, pyyaml round-trips external-services.yml (22 routers ↔ 22 services), helm template succeeds against traefik chart 41.5.0 and csi-driver-nfs with the shipped values.

### [2026-09-15] Kustomize namespace circular dependency with helm --create-namespace
**Mistake:** Removed the Namespace object from k8s/foundation (to fix a kustomize ID conflict) and relied on `helm --create-namespace` to create it — but the ConfigMap/Secret the chart consumes must land in that namespace BEFORE the helm install, so `kubectl apply -k` failed with "namespaces traefik not found".
**Root cause:** Split the create-order between two tools; the apply order in the runbook depended on a namespace only helm would make.
**Prevention:** A kustomization with `namespace: X` may ship a single same-named Namespace object (the transformer no-ops on it); only multiple different namespaces in one kustomization collide. Prefer declaring the namespace in manifests over deferring to helm.
**Verification:** `kubectl apply -k k8s/foundation` now creates namespace/traefik first; full §6 deploy succeeded on the live cluster.

### [2026-09-15] Installed rancher helm chart without templating prerequisites first
**Mistake:** Ran `helm install rancher` directly (skipped the helm-template-first rule) — hit three serial failures: chart requires cert-manager CRDs even with tls.source=rancher, values file was missing `hostname` (invalid empty Ingress TLS host), and the aborted installs left CRDs + a stale v1.ext.cattle.io APIService that kept cattle-system Terminating for minutes.
**Root cause:** Chart's external prerequisites (CRDs, other controllers) are invisible to local kustomize checks and only surface at install time; aborted Rancher installs strand non-namespaced objects (CRDs/APIServices) that helm uninstall never removes.
**Prevention:** For any new chart: `helm template` first (surfaces client-side kind resolution like missing Issuer CRDs), check chart kubeVersion against the cluster, and when an install fails partway expect to clean CRDs/APIServices + strip stuck finalizers before retrying.
**Verification:** Fresh install after cleanup rolled out clean; rancher 1/1 Running, ingress registered, HTTPS 200 via port-forward.

### [2026-09-15] Wave-1 k8s gotchas: AUTHELIA_* service-link collision and stale transition routers
**Mistake:** (1) Named the session store Service `authelia-valkey`; kubelet injects `AUTHELIA_VALKEY_SERVICE_HOST` etc. as env, and authelia parses ANY `AUTHELIA_*` env as config — fatal startup conflict. (2) Left convertx/auth/zipline routers in the k8s edge transition ConfigMap after their IngressRoutes went live — duplicate Host rules let the dead VM-forward win, producing 502/404s that looked like app failures.
**Root cause:** (1) Kubernetes service-link env injection interacts with apps that claim broad env prefixes. (2) Violated the migration runbook's own rule (delete the VM-forward block the moment a service gets an IngressRoute) during a multi-service wave.
**Prevention:** For env-greedy apps (authelia): `enableServiceLinks: false` in the pod spec, or avoid the prefix in service names. After each service cutover, immediately prune its router from BOTH edge configs and re-run the full subdomain sweep.
**Verification:** enableServiceLinks=false rollout healthy (authelia 1/1, health 200); after ConfigMap prune, all 26 subdomains answer with expected codes and dash gates through the cluster authelia.

### [2026-09-15] Rancher 2.15.1 on k3s 1.36 deletes the cluster-admin ClusterRole
**Mistake:** Diagnosed the user's rancher login failure as a bootstrap-state problem and burned many cycles re-arming bootstrap, resetting passwords, and reinstalling — while the real fault was rancher itself deleting `cluster-admin` and fataling on its own RBAC; the 401s were a symptom of the auth stack never finishing init.
**Root cause:** Empirically verified: role survives with rancher scaled to 0, is deleted ~60s after the pod runs (also on a fully clean reinstall), and older chart lines (≤2.14.3) refuse k8s 1.36. Own kubectl kept working because the k3s kubeconfig authenticates as system:masters, masking cluster-wide RBAC breakage.
**Prevention:** When a packaged platform's auth/bootstrap misbehaves, check CLUSTER-WIDE health (default ClusterRoles, CRDs, APIServices) before iterating on the app's own state; a system:masters kubeconfig hides RBAC damage. Pin web-GUI choice to versions with real (not ceiling-bumped) k8s support.
**Verification:** Rancher fully uninstalled (ns + CRDs + APIService), cluster-admin recreated and stable, Headlamp deployed and verified as the replacement GUI.

### [2026-09-17] kubectl apply -f on a kustomize-namespaced manifest created duplicates in default ns
**Mistake:** Applied `k8s/media/sabnzbd.yaml` with `kubectl apply -f` (no `-n`, no `-k`) — the file carries no explicit namespace (the kustomization injects `media`), so it created a parallel sabnzbd Deployment/PVCs/Service/IngressRoute in the `default` namespace, including a duplicate `Host(sabnzbd.thenewmans.casa)` IngressRoute (the exact duplicate-Host-rule hazard TROUBLESHOOTING.md §0 warns about).
**Root cause:** Context namespace silently became the target; "created" output looked like success. Per-file applies bypass every namespace guarantee the kustomization provides.
**Prevention:** Always `kubectl apply -k k8s/<dir>` for these manifests; if a single file must be applied, `kubectl apply -n <ns> -f`. Treat any `created` (vs `configured`/`unchanged`) for an existing service as a red flag. **Repeat 2026-09-19** (exportarr.yaml, same cause): standalone manifests under k8s/ now carry explicit `namespace:` metadata so a bare `kubectl apply -f` lands correctly anyway.
**Verification:** Deleted the default-ns duplicates within ~25s (never went Ready, no watch-folder race); real IngressRoute held — `curl https://sabnzbd.thenewmans.casa` still 303s through the media-ns route; correct apply via `-k` succeeded.

### [2026-09-17] Set sabnzbd size_limit assuming GB semantics; it parsed as 20 BYTES and force-paused the whole queue
**Mistake:** Added `size_limit=20` intending a "pause when free disk < 20GB" floor for the new node-local incomplete dir. `size_limit` is actually a maximum-job-size guard whose OptionStr value parses as raw bytes ("20" = 20 bytes), so every added job failed `bytes > limit`, got flagged TOO LARGE, and was force-paused with LOW_PRIORITY.
**Root cause:** Configured an unfamiliar app setting via API from memory instead of reading the app's behavior; verified the value echoed back but never exercised it with a real job after the change.
**Prevention:** For app settings set outside the app's own UI, check the app's source/docs for the exact semantics (source was readable in-container at /app/sabnzbd), and prove the setting with a test job before walking away. The free-space floor knob is `download_free` (suffix syntax, e.g. "8G"; auto-pause + auto-resume, checked every few minutes).
**Verification:** `size_limit=0`, `download_free=8G` persisted in sabnzbd.ini; all 18 force-paused jobs resumed via per-nzo_id API resume and are Downloading.

### [2026-09-19] Recorded "verified: no btrfs RAID6 exists" from the md layer only
**Mistake:** The 2026-09-17 TROUBLESHOOTING.md row claimed Ratchet's disks were "7 independent single-device btrfs disks, parity-less, the believed btrfs raid6 does not exist — verified". Live check on 2026-09-19 shows `/mnt/bigmama` is one btrfs pool, Data RAID6 + Metadata RAID1C3 across 8 devices with devid 8 MISSING (mounted `degraded`) — the claim was false and materially changed the recovery story (RAID6 parity CAN repair the corruption once the disk is replaced).
**Root cause:** Verified topology from the Unraid md-array state (`mdNumDisks=0`, empty parity slots) and per-device listings instead of querying the mounted filesystem itself; `btrfs filesystem show` lists fs membership but the "7 independent disks" reading came from the md layer, which is a separate (empty) thing in this box.
**Prevention:** To verify storage topology, interrogate the MOUNT: `mount | grep degraded` + `btrfs fi usage /mnt/<pool>` + `btrfs device stats /mnt/<pool>`. Never record a doc-level "verified" claim about redundancy from a layer that isn't the one serving the data.
**Verification:** `btrfs fi usage /mnt/bigmama` shows `Data,RAID6: Size:27.24TiB` over 7 present + 1 MISSING device; TROUBLESHOOTING.md §3 row corrected same day.

### [2026-09-19] Declared "Synology has no SSH" after probing only ports 22/2222
**Mistake:** Concluded the Synology (192.168.0.6) had no SSH and built a VM-relay rsync (NAS→VM→NAS, ~half line rate) around that assumption. User correction: SSH listens on port **2323** — direct NAS-to-NAS copy was possible all along.
**Root cause:** Port probe covered the default (22) and the port used by the OTHER NAS (2222, Ratchet's) and stopped there; no check of ~/.ssh/config, group_vars, or known_hosts entries that hinted at 2323.
**Prevention:** Before declaring a service absent on a known-good host, probe the common alt-port set (22/2222/2323/2200/22022) AND grep the environment's configs (`~/.ssh/config`, dotfiles, docs) for the host's port. Absence of evidence on two ports is not evidence of absence.
**Verification:** `ssh -p 2323 dnewman@192.168.0.6` keys in from the VM; direct pull rsync (perceptor→Ratchet) now running per TROUBLESHOOTING.md §4 runbook.

### [2026-09-19] kustomization resource line SWAPPED instead of added — radarr invisible to applies for days
**Mistake:** Commit 1eee020 replaced `- radarr.yaml` with `- vm-backends.yaml` in `k8s/media/kustomization.yaml` instead of adding the new file. Every subsequent `kubectl apply -k k8s/media` silently skipped radarr (no error, no "configured" line anyone noticed), so radarr's Deployment drifted days behind the manifests — during the 2026-09-19 downloads-share cutover its `/downloads` still pointed at the corrupt Ratchet pool while sabnzbd/sonarr/lidarr had moved, stranding ~6 finished movies in the import queue.
**Root cause:** One-line resource edit swapped rather than appended; `kubectl apply -k` output for a missing resource is simply absent (not an error), and nothing diffs the kustomization's resources against the directory.
**Prevention:** After touching any `kustomization.yaml` resources block, verify sets match: `diff <(ls k8s/<dir>/*.yaml | xargs -n1 basename | grep -v kustomization | sort) <(grep -oE "^  - [a-z-]+\.yaml" k8s/<dir>/kustomization.yaml | sed "s/^  - //" | sort)`. Treat a manifest file on disk that never appears in apply output as a red flag.
**Verification:** radarr.yaml restored to resources (with comment); sets diff empty; `kubectl apply -k k8s/media` shows `deployment.apps/radarr configured`, new pod, `/downloads/nzb/complete/movies` lists all releases, queue items `ok` and history shows imports (Fiend 21:43:55Z).

### [2026-09-20] Piping a mutating kubectl apply through head SIGPIPE-killed it mid-apply
**Mistake:** Ran `kubectl apply -k k8s/media ... | grep ... | head -10` to trim output; head closed the pipe after 10 lines, kubectl died of SIGPIPE, and the PersistentVolumeClaim updates (the excluded_from_alerts labels) were never sent — while the visible "success-looking" output masked the skip.
**Root cause:** Truncated the display of a mutating command with `head`, which terminates the upstream producer. Apply emits objects in stream order, so the objects after the first ~10 lines (PVCs sort after services) were silently dropped.
**Prevention:** Never pipe a mutating kubectl command through `head`/`grep -m`; capture full output to a file or filter read-only (`grep` without early-exit on a file), and verify mutations with a follow-up read (`kubectl get -o ...`).
**Verification:** `kubectl -n media get pvc -l excluded_from_alerts=true --no-headers | wc -l` → 5 only after re-running apply without the head pipe.

### [2026-09-20] edit-tool hunk anchored on remembered line numbers patched the wrong block
**Mistake:** After rewriting kube-prometheus-stack-values.yaml with `write`, issued `PUT 36.=37:` using line numbers from memory; lines 36-37 were actually alertmanagerSpec's resources keys, so a grafana help comment got spliced into alertmanagerSpec (orphaning a `limits:` key) while the intended broken comment stayed unfixed.
**Root cause:** Line anchors from a stale mental model — a full-file write renumbers everything.
**Prevention:** After any full-file `write`, re-read the file before the first line-anchored edit; never target ranges not seen in a post-write read.
**Verification:** Fresh read exposed both damage sites; repaired both; `helm template` parsed and rendered clean with expected object counts.
**Repeat 2026-09-22:** cut CLAUDE.md line 90 (the just-added nostalgiatv row) instead of the tunarr row at 89 — anchor came from a grep run BEFORE an earlier edit renumbered the file. Rule extends to grep/sed-derived line numbers, not just post-write reads: re-read (or re-grep) immediately before any line-anchored edit. Caught by reading the edit response listing; fixed by replacing the row in the next edit.
**Repeat 2026-09-25:** three related failures in one session: (1) a multi-line edit whose old_string carried wrong indentation (10 vs 14 spaces) was fuzzy-ACCEPTED and demoted `volumeMounts` to an invalid pod-spec field in nfs-probe.yaml — `kubectl kustomize` rendered it happily (kustomize does NOT schema-validate) and only the live apply rejected it with "unknown field"; (2) the compose/media-server.yaml fix then fuzzy-matched a sibling line, turning a stray anonymous-volume entry into a duplicate ratchetmedia bind; (3) both were caught only by reading the edit response listings. Prevention extensions: after ANY multi-line block edit, re-read the changed section and treat the response listing as the first diff check; validate changed k8s manifests with `kubectl apply --dry-run=server`, never kustomize-build alone.

### [2026-09-21] Triaged recyclarr 7.5.2 as a "safe patch" from a stale version boundary
**Mistake:** Recommended clicking/merging the renovate recyclarr 7.4.0→7.5.2 PR because the manifest header said "do not bump past 7.x", reading that as a guarantee for all 7.x. 7.5.2 fatals at startup ("unable to find config include 'radarr-quality-definition-movie'") even with the settings.yml sha1 pin intact — the include-resolution change landed inside the 7.x line.
**Root cause:** Treated a header comment documenting boundaries as of its writing as forward-looking; merged a config-coupled app's image bump without exercising the job once (the recyclarr header itself says the config model is version-coupled).
**Prevention:** For config-coupled apps (recyclarr especially): after merging ANY image bump, immediately run `kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual-$(date +%s)` and confirm a clean sync the same day; header "safe" statements only cover versions that existed when written.
**Verification:** Reverted to 7.4.0 (manifest + live), manual job Complete in 6s with clean Radarr sync; renovate.json pins recyclarr allowedVersions to /^7\.4\./ until the v8 config migration.
**Repeat 2026-09-25:** romm (`:latest`, config-coupled) crash-looped when an UNRELATED rollout re-created its pod: the re-pull brought 5.3.1, which fatals on legacy config.yml keys (`filesystem.roms_folder`, then `firmware_folder`). Floating tags mean ANY pod recreation is an implicit image bump — for :latest config-coupled apps, verify startup health after any rollout that recreates them. Fixed forward per the in-log migration hint (`structure.default` / `structure.firmware`) via a one-off PVC-mounted helper pod.

### [2026-09-22] exportarr OOM diagnosed from a comment, not the container
**Mistake:** exportarr-radarr/lidarr crash-looped (OOMKilled, 135/121 restarts) for 3 days without anyone noticing; when investigated, the manifest comment "ENABLE_ADDITIONAL_METRICS off" was treated as ground truth — but no env var was ever set, and the actual cause was Go GC heap-target arithmetic: ~130Mi live set → ~2x heap target against a 256Mi limit, so every post-ramp transient killed the pod.
**Root cause:** Comment documented intent, not state; restart counts on monitoring components themselves weren't monitored; OOM at a limit was read as "data too big" before measuring (`kubectl top` plateau + single-scrape delta took minutes and disproved both theories — output is 5.9KB, no leak).
**Prevention:** For any container OOM: read `lastState.terminated.reason` first, then watch `kubectl top` across one workload interval and one manual request before theorizing about payloads. Set GOMEMLIMIT (~75% of limit) on every Go app in a memory-limited pod. Treat "X is off" comments as unverified until the env/flag is shown set.
**Verification:** GOMEMLIMIT + 512Mi on radarr/lidarr (100MiB on the 128Mi pair): 0 restarts after 2 scrape intervals, memory 129Mi/103Mi vs old 222Mi plateau; committed 5944a8d.

### [2026-09-23] Four shipped bugs in the cephx aes256k migration script, each from unverified assumptions
**Mistake:** The phase-1 key-rotation script for the PVE cluster failed four times in production runs: (1) `systemctl cat ceph-mon@<id>` resolves the template unit on ANY node, so mon restarts targeted the wrong host; (2) jq gate compared `ceph osd dump`'s integer `up`/`in` fields against boolean `true` (never passes, guaranteed 300s FATAL); (3) remote script line used `\$id` so a loop variable expanded on the remote (unset) instead of locally — device discovery silently matched nothing; (4) writing the bluestore `osd_key` label with the upstream doc's keyring-file-path value left the OSD running-but-unjoinable for 20+ minutes.
**Root cause:** Each bug was an assumption about an interface I never exercised: systemd template semantics, ceph JSON field types, local-vs-remote variable expansion inside double-quoted ssh strings, and an upstream doc example taken on faith. Integration-tested the pure-jq logic but never the ssh-rendered remote script or the JSON it would actually receive.
**Prevention:** For cluster-surgery scripts: (a) render the exact remote command locally (echo it through the same quoting) and bash -n that before shipping; (b) validate every jq predicate against a sample of the REAL command's JSON captured on the target; (c) resolve daemon placement with `systemctl is-active --quiet` (state, not unit-file existence); (d) treat doc-recommended mutations on running daemons as guilty until proven innocent — prefer the path already proven working on this cluster (keyring file) over belt-and-suspenders additions (label write).
**Verification:** After each fix, live probes (unit ActiveEnterTimestamp, mon audit log boots, key fingerprint md5s mon-vs-file) confirmed the intended state before proceeding; final health shows both AUTH_INSECURE errors cleared with 6/6 OSDs up and 33/33 PGs active+clean.

### [2026-09-26] `pkill -f <pattern>` over ssh killed its own session three times
**Mistake:** While stopping a runaway hasher on the Synology, ran `ssh nas 'pkill -f nas-duphash.py; ps w | grep nas-duphash ...'` — pkill matched the REMOTE SHELL's own cmdline (it contains the literal pattern), killed the shell mid-command, and every verification probe after it returned empty output / ssh exit 255, which I then misread as "NAS unresponsive" and re-derived twice.
**Root cause:** `pkill -f` matches ANY process whose full cmdline contains the pattern, including the very shell running the pkill. Empty probe output was the killed session, not a dead NAS.
**Prevention:** Bracket the pattern so the shell's own cmdline can't match: `pkill -f 'nas[-]duphash'`. When a verification probe returns empty, check whether the probe command itself would match the kill pattern before concluding anything about the target.
**Verification:** With `nas[-]duphash`, the probe returned cleanly (0 matching processes, load decaying) on the first try; hasher confirmed dead and NAS recovered.

### [2026-09-26] Burned ~30 min of client-side forensics on the rbd-create hang before asking the OSDs directly
**Mistake:** While diagnosing the cluster-wide `rbd create` hang (disk-add hanging on VMs 108/109/110), went deep into client-side evidence first: strace, thread/wchan dumps, librbd debug logs, fresh-pool bisects — all of which showed only "op never completes". The server-side view (`ceph daemon osd.N dump_ops_in_flight`) answered in one call: client writes queued 600+s at "waiting for peered" on stuck PGs whose primary was a heartbeat-dead OSD.
**Root cause:** Treated the hang as a client/library mystery instead of a placement lottery: each new rbd object hashes to a random PG, so `rados put` succeeded (healthy PG) while `rbd create` (several objects, decent odds of hitting a stuck PG) hung — a coin-flip symptom that looked like a deterministic library fault.
**Prevention:** For any ceph client-op hang: FIRST run `ceph daemon osd.<N> dump_ops_in_flight` on all OSDs (and check `heartbeat_check: no reply` in OSD logs) before touching strace/debug-logs. A "works sometimes, hangs sometimes" pattern on keyed ops = per-PG health, not client bugs. Also: `grep '^key'` never matches ceph keyring files/auth dumps (key lines are TAB-indented) — use `grep key`, or it produces false "missing/empty key" alarms.
**Verification:** After restarting the dead-auth OSDs (3/4), all 65 PGs went active+clean and the previously hanging `rbd create` returned in 0.035s.

### [2026-09-26] Misread non-root ssh symptoms on PVE nodes as cluster faults
**Mistake:** First diagnostics ran as `dnewman` over ssh; concluded "pve1 pmxcfs broken / ceph unreadable" from `pvecm` ipcc errors and `ceph -s` conf_read_file failures — all of which are normal root-only access boundaries on PVE (pmxcfs IPC socket, 0640 root:www-data /etc/pve/ceph.conf), not faults. Cost several probes and a wrong working theory before checking `whoami`.
**Prevention:** On any PVE/cluster host, run `whoami` in the FIRST probe batch; treat ipcc_send_rec, "Unable to load access control list", and conf/keyring read failures from a non-root session as identity symptoms. Root access on pve1-3 now exists via dnewman's workstation key (installed 2026-09-26 into /root/.ssh/authorized_keys on all three nodes; remove that line to revoke).
**Verification:** Root `ceph -s`/`pvecm status` on the same nodes returned clean, healthy output minutes later.

### [2026-09-26] Rancher→Headlamp cutover left nothing deployed and nothing persisted
**Mistake:** The 2026-09-15 "Headlamp deployed and verified as the replacement GUI" was never committed as a manifest under k8s/ and its workloads are gone from the cluster entirely (no deploy/svc/pod/ns) — when the user tried `rancher.thenewmans.casa` later, they got a zombie Steve-API JSON from the old mgmt VM (192.168.0.22) and no GUI existed anywhere.
**Root cause:** Verified-by-hand kubectl apply of upstream YAML with no repo manifest is indistinguishable from never having deployed it; the first pod eviction or node churn silently deletes it.
**Prevention:** Every service that matters lives as a manifest under k8s/<ns>/ + kustomization resources line (append, then run the sets-diff check from 2026-09-19). "Deployed and verified" only counts if `git grep <name> k8s/` finds it.
**Verification:** headlamp.yaml now in k8s/apps/ (deploy+svc+IngressRoute+SA), sets-diff clean, headlamp.thenewmans.casa 302s through Authelia; token via `kubectl -n apps create token headlamp-admin`.
**Update 2026-09-26 later same day:** User decided against Headlamp — Rancher (VM 111 "rancher" on pve2, 192.168.0.22, its own k3s, v2.15.1) is the GUI of record. Headlamp deployment/route reverted. UI lives at rancher.thenewmans.casa/dashboard/ (bare / serves steve apiRoot JSON by design in 2.15).

### [2026-09-26] find -printf %P stripped the start-point names and produced a meaningless cross-tree diff
**Mistake:** Built the Ratchet Media→USB verification with `find Movies TVShows Syncs Downloads -printf '%P\t%s'`; %P removes the start-point itself, so all four trees merged into one prefix-less namespace (`Downloads/nzb/x` and `Syncs/nzb/x` collided on the same join key) — the join inflated to 135k phantom "extra" lines, and my awk MISSING/EXTRA labels were also swapped, so the first summary read backwards.
**Root cause:** Assumed %P keeps the top-level directory; never sanity-checked a sample of the list against `ls` before joining, and the totals (16082 dst files vs 135755 "extra") were an obvious impossibility I almost reported through.
**Prevention:** For multi-root finds, use absolute start points and re-prefix manually (`find "$SRC/$t" -printf "$t/%P..."`). Before trusting a diff, reconcile counts (src = matched + src_only + size_diff must hold exactly) and eyeball one list entry against a known path.
**Verification:** Per-tree diff reconciled exactly (15890 = 15884 matched + 5 missing + 1 size-diff); each anomaly individually confirmed on-box (5 post-copy Jeopardy episodes, 1 truncated file, Cougar Town deleted-on-source).

### [2026-09-26] Four Unraid array-surgery traps during the bigmama→XFS rebuild
**Mistake:** (1) Pre-unmounted `/mnt/user` "to help" before the UI Stop — emhttpd's stop then retried `umount /mnt/user` forever (its umount exits 32 on *not mounted*), wedging the stop. (2) With `/mnt/user` down, an `rc.docker start` created a fresh EMPTY sparse docker.img on the root fs at `/mnt/user/system/docker/`, which later risked shadow-mounting instead of the real 15G img on cache. (3) The array Stop/Start swept the unassigned USB mount (`/mnt/disks/Expansion` gone) and the first restore run failed instantly with rc 23. (4) Set Media's `shareCachePool=""` expecting cache exclusion — shfs treats empty as "default cache pool" and kept merging the nvme slice into the share view.
**Root cause:** emhttpd drives array ops through a strict state machine that assumes it performed every mount itself; side-channel mounts/deletions desync it. Unraid 7 empty-string config keys fall back to defaults rather than meaning "none".
**Prevention:** Let emhttpd do its own unmounts — if a stop wedges on user shares, stage a throwaway `mount -t tmpfs none /mnt/user` so its next umount succeeds. After ANY array stop/start, re-verify unassigned-device mounts. To exclude a pool from a share view, remove the pool's actual directory (after verifying backup coverage) rather than fighting cfg keys. Check `losetup -a` + the resolved backing path of `/var/lib/docker` before trusting dockerd.
**Verification:** Stop completed within 15s of staging the tmpfs; cache flag cleared (fsNumUnmountable 0) after one clean Start; USB remounted and restore running (rsync alive, files landing on disk1); Media view shows array only; Plex up on the real img (`/mnt/cache/system/docker/docker.img`, 15G data).

### [2026-09-26] k8s-edge ConfigMap file provider: v2 cert syntax silently 404'd every VM-resident host
**Mistake:** The k8s edge (traefik helm release, ns traefik) routes VM-resident subdomains (search/torrent/minecraft/rancher) from the `traefik-external-services` ConfigMap file provider. Its routers used v2-style per-router `tls.certificates` — Traefik v3 removed that field, so the whole file failed with "field not found, node: certificates" and every fresh traefik pod served 404 for ALL file routes while looking perfectly healthy (CRD routes unaffected). Masked for hours because the 10h-old sibling pods still ran the pre-update in-memory config, so direct-vs-node probes gave contradictory answers.
**Prevention:** (1) File-provider dynamic config for Traefik v3: never use per-router `tls.certificates`; set `tls.stores.default.defaultCertificate` (certFile/keyFile from the mounted secret) once, and routers use `tls: {}`. (2) After ANY change to a ConfigMap-backed traefik file provider, verify per-REPLICA: `curl -k -H 'Host: <host>' https://<each-node-ip>/` — node results can differ even with identical mounted files, because watchers miss kubelet rename-swaps and old pods keep stale in-memory routes. (3) The router port-forwards for 80/443 pointed at 192.168.0.19 (media-k8s-1) exclusively — a pod reschedule or node loss silently took VM-resident services off the internet. Fixed 2026-09-26 with keepalived edge VIP **192.168.0.23** (unicast VRRP, priorities 150/100/50 on media-k8s-1/2/3, health script `/usr/local/bin/edge-health.sh`): point the router forwards at the VIP once; failover is then automatic (verified: VIP floats master→media-k8s-2 and back). See k8s/INSTALL.md §9c-VIP.
**Verification:** Fixed syntax applied via kubectl apply, kubelet synced within ~45s (no pod restart needed once node I/O recovered), then search/torrent/rancher all returned 200 from the ingress node AND from two external check-host nodes.

### [2026-09-26] Longhorn migration script: four failures from untested shell assumptions
**Mistake:** The migrate-to-longhorn.sh flow failed four separate ways on first runs: (1) `du -sb` byte-verify compared directory-inode sizes that legitimately differ between ext4 variants → false verify failure on an intact copy; (2) swapped to `find -printf` without testing it on the target busybox (1.36 Debian build has no -printf) → byte verify silently degenerated to counts-only and "passed"; (3) the printf readiness smoke test asserted `PRINTF_OK` appeared without noticing `find` had failed and awk had printed 0; (4) edited the script WHILE a bash process was executing it — the zombie later resumed from stale offsets, raced the fresh run's tar extraction ("File exists"), and interleaved scale/cleanup steps.
**Root cause:** Every verify/test layer was asserted against what the code SHOULD do, never executed against what the actual busybox build does; and the edit-while-running hazard of incrementally-read bash scripts was ignored.
**Prevention:** (a) Execute a migration script's verify snippet against a real populated directory in the real target image BEFORE the first real run; (b) verify regular-file CONTENT bytes only — tar-stream `tar -cf - | wc -c` is exact, deterministic and ARG_MAX-immune (dir inodes are not); (c) never edit a bash script while any process is executing it — cancel, fix, relaunch.
**Verification:** Final flow completed 30/30 PVC migrations to Longhorn with strict byte-exact stage→final verification on every volume (e.g. lidarr 26,392,250,880 bytes both copies).

### [2026-09-30] `PUT N.:` replaces line N — used it three times where insert was intended
**Mistake:** While editing gen-env.sh, cognee.yaml, and CLAUDE.md, issued `PUT N.:` with a body meant to be ADDED after line N; each call instead consumed line N (dropping `val=$(get "$key")`, `value: http`, the mcsmanager-daemon and jellyfin rows), caught only by reading each edit response.
**Root cause:** `PUT N.:` is a REPLACE of line N; insertion after N is `PUT >N:`. Repeated for insert-after-single-line cases because the range form felt like the default.
**Prevention:** Inserting → `PUT >N`; replacing → `PUT N.=M`. After every edit, diff the response listing against intent (count lines: body lines should equal range size for replaces, and no neighbor line should vanish).
**Verification:** Subsequent edits in the session used `PUT >N` for inserts; re-reads confirmed no further dropped lines.

### [2026-09-30] Misdiagnosed z.ai error 1113 as "no account balance"
**Mistake:** Validating a z.ai key against https://api.z.ai/api/paas/v4 returned error 1113 "Insufficient balance or no resource package"; concluded the account needed a recharge and told the user to top up. User correction: the key is a Coding Plan key — the correct base URL is https://api.z.ai/api/coding/paas/v4, where the same key works immediately.
**Root cause:** Treated a billing-shaped error as a billing problem without considering that the endpoint selects the plan; z.ai serves coding-subscription keys on a different path than pay-as-you-go keys.
**Prevention:** For provider API errors on third-party endpoints, check the endpoint/key-type matrix (same provider often runs multiple plans on different base URLs) before recommending account actions. Ask which plan/product the key belongs to when auth passes but billing fails.
**Verification:** Same key returned a 200 completion with glm-5.3-flash on the coding base URL; cognee flipped and PipelineRunCompleted through it.

### [2026-10-01] Assumed paired upstream images carried the same library version
**Mistake:** Pinned cognee's API and MCP containers to `cognee/cognee:1.6.2` and `cognee/cognee-mcp:main-ba3631f` believing "same-day build = same commit = same version". Hermes then hit "Relational DB Migrations failed" on every MCP write: the mcp image bundles cognee 1.5.4 from PyPI (its uv.lock pins the published wheel), while the api image builds the monorepo source (1.6.2-local) — the 1.5.4 migration chain cannot read the alembic head 1.6.2 stamped.
**Root cause:** Verified image pairing by build DATE, not by the embedded library version. A monorepo's subproject images can lag the release tag by whole minor versions when their lockfile pins an external registry instead of the workspace source.
**Prevention:** When two services must share a schema/migration state, verify the embedded library version in both images (`python -c "import pkg; print(pkg.__version__)"` via kubectl exec) before pairing tags. Alembic "Can't locate revision" across services = version skew, not a broken DB.
**Verification:** Rebuilt the mcp image from the v1.6.2 tag with `uv lock --upgrade-package cognee` (→ PyPI 1.6.2), imported to all nodes; MCP remember/recall round-trip verified live.
