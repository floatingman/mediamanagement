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
