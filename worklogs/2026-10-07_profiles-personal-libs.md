# 2026-10-07 — Profiles and read-only personal libraries (wrapper 0.3.0-dev)

## Profiles and config

- `~/.config/libd-ai-sandbox/config` (defaults) and `profiles/NAME.conf` (user) or
  `etc/profiles/NAME.conf` (site); `key = value`, parsed, never sourced; unknown keys abort.
- Keys: `home_mode scratch personal_libs agent module read write description`; `write` only in
  profiles. `~ $HOME $USER $MYSCRATCH` expanded, nothing else.
- `--profile NAME` (repeatable), `--list-profiles`, `--module NAME` (repeatable).
- Modules load after the login profile; interactive sessions continue with `exec bash -i`.

## Personal libraries (synthetic home, default on)

- Real `~/R` -> `/host_home/R` ro, real `~/.local/lib` -> `/host_home/.local/lib` ro.
- R: `R_PROFILE_USER=/.libd-ai-sandbox/Rprofile.R` (from `share/R/sandbox-Rprofile.R`). Verified
  `.libPaths()` = sandbox `~/R/4.5.x`, `/host_home/R/4.5.x`, `/host_home/R/x86_64-conda-linux-gnu-library/4.5`,
  site, base. The hook sources the synthetic `~/.Rprofile` afterwards.
- Python: `libd-ai-sandbox-host.pth` per `pythonX.Y` user site; verified with `/usr/bin/python3`
  (3.9): sandbox user site then `/host_home/.local/lib/python3.9/site-packages`.
- Note: conda_R's Python is 3.12 and the author has no `python3.12` user site, so nothing is
  added there; the mechanism is per version.

## Tests

56/56 on transfer-01, 53/53 on compute-162.
