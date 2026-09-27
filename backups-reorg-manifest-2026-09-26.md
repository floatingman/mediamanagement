# /mnt/backups reorganization manifest (2026-09-26)

Approved scheme: three new parents; curated and active-job paths untouched.
All moves were same-volume renames (metadata-only, atomic).

## Moves performed

| Old path (/mnt/backups/…) | New path (/mnt/backups/…) |
|---|---|
| Misc/hostgator | Cloud/hostgator |
| hostgator | Cloud/hostgator-archive |
| Onedrive | Cloud/Onedrive |
| googledrive | Cloud/googledrive |
| WPThemes | Cloud/WPThemes |
| BlurrBackup | PC-Backups/BlurrBackup |
| backup | PC-Backups/backup |
| sunstreakerbackup | PC-Backups/sunstreakerbackup |
| AliceBackup | PC-Backups/AliceBackup |
| WindowsImageBackup | PC-Backups/WindowsImageBackup |
| Framework12 | PC-Backups/Framework12 |
| outbackbackup | PC-Backups/outbackbackup |
| usbbackup | PC-Backups/usbbackup |
| ISOs | Software/ISOs |
| WindowsSetup | Software/WindowsSetup |
| Misc Apps | Software/Misc Apps |
| MAD | Software/MAD |
| FPGA_Programming | Software/FPGA_Programming |
| tools | Software/tools |

## Deliberately untouched

- Curated: `Books/Sorted`, `Books/Magazines`, `Games/Roms/Core_Roms` (per user), rest of Books/ and Games/ internals
- Active job targets: `ha_backup_home`, root `automatic_backup_*.tar`, `music_assistant_*.tar`,
  `kopia` (backup repo), `monerodata`, `StorageAnalyzerReports`, `#recycle` (Synology recycle bin)
- Clean categories already: `Games`, `Books`, `Photos`, `Music`, `AI`, `Misc` (now only Apps + strays)

## Known consequences

- Any SMB mapped drive, script, or scheduled job referencing the old paths must be repointed.
  `ISOs` and `googledrive` moved despite recent activity per user instruction ("move them too").
- `backups-duplicates-2026-09-26.json/.md` and `backups-dedup-manifest-2026-09-26.tsv` contain
  pre-move paths; 1,014 of 1,254 verified groups and most presumed groups live under moved
  subtrees — re-run analysis before acting on Tier 2.
- File-count drift vs the 09-25 inventory (e.g. ISOs +38, WindowsSetup +107) is live-tree
  activity, not move loss: renames are atomic.
