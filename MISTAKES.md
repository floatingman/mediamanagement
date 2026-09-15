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
