# 2026-10-07 — Phases 1–3: wrapper skeleton

## Decisions

- **No container image.** The container root is an empty skeleton directory (`libexec/make-rootfs`)
  with host `/usr /etc /opt /var/lib/sss /var/lib/alternatives` bound read-only. The environment
  matches the node: site profile, Lmod, default JHPCE modules, `module load conda_R/4.5.x`.
- **`$MYSCRATCH` writable by default** (`--no-scratch` to drop). It was not in the earlier plan,
  which only made `ai-sandbox/home` and the `/tmp` backing writable.
- **`--write PATH` / `--read PATH`, repeatable, same path inside.** `/agent_out` and `/payload`
  dropped. `--write` targets must exist and pass the refusal rules in `docs/design.md` §6.
- **Automounts are triggered by the wrapper before validation and launch**; `readlink`/`stat` do not
  trigger autofs, a lookup inside the directory does.
- Slurm submit/control and ssh/scp/sftp masked by a deny script bound over the host binaries.

## Tests

`tests/test_wrapper.sh`: 12 refusal checks, 16 live checks (synthetic home, scratch rw, `--write`
rw, scratch `/tmp`, writes blocked under `/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber`,
`/jhpce/shared/libd` and the repo, sbatch/ssh denied, munge absent, user lookup, conda_R +
SummarizedExperiment). 28/28 on transfer-01, compute-148, compute-092.

## Next

Phase 4 (agent config into the synthetic home) and phase 8 (Codex/Claude modes).
