# 2026-10-09 — Data folders and session home move into profiles (wrapper 0.5.0-dev)

## Why

The "site mounts file" (`etc/mounts.tsv` in the module folder) held both system mounts and the
LIBD storage. Users could not find or edit it, and a shared module should not carry
lab-specific storage in its system configuration.

## Changes

- `etc/mounts.tsv`: system only (`/usr /etc /opt /var/lib/sss /var/lib/alternatives
  /jhpce/shared`).
- `etc/profiles/default.conf`: `read = /dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber`, with
  sections for read-only folders, writable folders, home. Applied when no `--profile` is given;
  a user's `~/.config/libd-ai-sandbox/profiles/default.conf` replaces it.
- New profile keys: `include = NAME` (each profile once, depth ≤ 8) and `home = PATH`
  (also allowed in `config`); new option `--home-dir DIR`. Home precedence: `config` <
  `LIBD_AI_SANDBOX_HOME` < profile < `--home-dir`.
- Removed: per-user `~/.config/libd-ai-sandbox/mounts.tsv` and `LIBD_AI_SANDBOX_MOUNTS_EXTRA`
  (one place for data folders: profiles).
- A missing `read` folder from a profile is skipped with a warning; a missing `write` folder stops.
- Banner shows the active profiles and the session home; `--dry-run` lists the profile files;
  the bind table tags each mount with the profile it came from.
- README: new first section "Where to customize (read this first)"; reference, troubleshooting,
  example profile (`include = default`, optional per-project `home`) updated. Design rev 7.

## Tests

85/85 on transfer-01, 82/82 on compute-159.
