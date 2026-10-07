# 2026-10-07 — Durable home, home modes, per-user customization

## Changes (wrapper 0.2.0-dev)

- Synthetic home moved from `$MYSCRATCH/ai-sandbox/home` (fastscratch purge risk) to
  `~/.libd-ai-sandbox/home`; logs to `~/.libd-ai-sandbox/logs`. Override: `LIBD_AI_SANDBOX_HOME`.
  The author's existing scratch home was moved there.
- Caches: `XDG_CACHE_HOME=$MYSCRATCH/ai-sandbox/cache`, so caches do not fill the home quota.
- Per-user config dir `~/.config/libd-ai-sandbox/`: `mounts.tsv` (extra ro mounts) and `skel/`
  (copied into the synthetic home without overwriting; durable `.bashrc` template).
- `--home-mode synthetic|real-ro|real-rw`. `real-rw` prints a warning: dotfiles edited by the
  agent run later in host sessions.
- Nested mounts under ro sources are now rebound ro instead of refused (measured: explicit ro
  rebind of the `~/ceph_backup` FUSE mount works). Nested autofs maps are still refused.
- `--read`/`--write` mount at the path as typed; symlinked paths (`~/gscripts`) appear where
  expected.
- ro mounts nested in rw ones allowed when the paths line up.
- `--dry-run`/`--print-binds` no longer create the synthetic home.
- Fixed two silent exits under `set -e` caused by `cond && action` as a function's last line.

## Tests

`tests/test_wrapper.sh` now uses an isolated home/config/state under `$MYSCRATCH/.sbx_test_<pid>`
and removes it afterwards. 45/45 on transfer-01, 42/42 on compute-147 (no nested home mount there).

## Open

Candidate customizations for sharing the module are listed in `docs/design.md` §9.1.
