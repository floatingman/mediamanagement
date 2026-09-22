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

### [2026-09-21] Triaged recyclarr 7.5.2 as a "safe patch" from a stale version boundary
**Mistake:** Recommended clicking/merging the renovate recyclarr 7.4.0→7.5.2 PR because the manifest header said "do not bump past 7.x", reading that as a guarantee for all 7.x. 7.5.2 fatals at startup ("unable to find config include 'radarr-quality-definition-movie'") even with the settings.yml sha1 pin intact — the include-resolution change landed inside the 7.x line.
**Root cause:** Treated a header comment documenting boundaries as of its writing as forward-looking; merged a config-coupled app's image bump without exercising the job once (the recyclarr header itself says the config model is version-coupled).
**Prevention:** For config-coupled apps (recyclarr especially): after merging ANY image bump, immediately run `kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual-$(date +%s)` and confirm a clean sync the same day; header "safe" statements only cover versions that existed when written.
**Verification:** Reverted to 7.4.0 (manifest + live), manual job Complete in 6s with clean Radarr sync; renovate.json pins recyclarr allowedVersions to /^7\.4\./ until the v8 config migration.

### [2026-09-22] exportarr OOM diagnosed from a comment, not the container
**Mistake:** exportarr-radarr/lidarr crash-looped (OOMKilled, 135/121 restarts) for 3 days without anyone noticing; when investigated, the manifest comment "ENABLE_ADDITIONAL_METRICS off" was treated as ground truth — but no env var was ever set, and the actual cause was Go GC heap-target arithmetic: ~130Mi live set → ~2x heap target against a 256Mi limit, so every post-ramp transient killed the pod.
**Root cause:** Comment documented intent, not state; restart counts on monitoring components themselves weren't monitored; OOM at a limit was read as "data too big" before measuring (`kubectl top` plateau + single-scrape delta took minutes and disproved both theories — output is 5.9KB, no leak).
**Prevention:** For any container OOM: read `lastState.terminated.reason` first, then watch `kubectl top` across one workload interval and one manual request before theorizing about payloads. Set GOMEMLIMIT (~75% of limit) on every Go app in a memory-limited pod. Treat "X is off" comments as unverified until the env/flag is shown set.
**Verification:** GOMEMLIMIT + 512Mi on radarr/lidarr (100MiB on the 128Mi pair): 0 restarts after 2 scrape intervals, memory 129Mi/103Mi vs old 222Mi plateau; committed 5944a8d.
