# 2026-10-07 — Login keys out of the sandbox; full option reference

## Findings

- `~/.ssh/id_rsa` (author) has no passphrase and is in `~/.ssh/authorized_keys`: a login key for
  every JHPCE node. `conda_R/*/bin/ssh` and `paramiko` are reachable inside the sandbox, so the
  deny list is not a barrier; the absence of any login key inside is.
- Gap found and fixed: `--home-mode real-ro|real-rw` exposed the real `~/.ssh`. It is now masked
  by an empty read-only folder (`share/empty`, created by `libexec/make-rootfs`).
- `--help` failed (unbound `HOME_MODE` after the config refactor); fixed, test added.

## Decisions

- Positron sessions (planned): dedicated sshd host key, keys listed in `authorized_keys` refused;
  clients use `HostKeyAlias libd-ai-sandbox-<user>`; shipped adaptable sbatch template;
  `--pid` not needed under Slurm.

## Docs

- README: complete option reference (CLI, files, config/profile keys, environment), "keep login
  keys out of the sandbox", Positron client usability (aliases, first connection, key change).
- `docs/positron_remote_plan.md`: client usability table. `docs/design.md` §7 aligned.

## Tests

77/77 on transfer-01, 74/74 on compute-124.
