# 2026-10-07 — Phase 0 runtime review and design revision

## Done

- Inventoried JHPCE container runtimes: `singularity/3.11.4` (setuid, default),
  `singularity/4.5.1` (non-setuid, needs `--userns`), `apptainer/1.5.3` (non-setuid, no
  squashfuse). Details in `docs/runtime_findings.md`.
- Ran containment probes on `transfer-01` with a `rockylinux:9-minimal` SIF against all three
  runtimes (`tests/runtime_probe.sh`). Read-only binds, synthetic home, nested rw-under-ro,
  `/agent_out`, payload, `--workdir`, `--cleanenv` all behave as needed on all three.
- Found and recorded three hazards:
  1. `--contain` without `--home` mounts the real home read-write.
  2. A ro bind of an autofs root (`/dcs04`) leaves the nested export (`/dcs04/lieber`) writable.
  3. The runtime creates a missing same-path bind destination on host storage.
  All stray test files were removed from the host.
- Verified shared `conda_R/4.5.x` (Bioconductor loads) and Node 24 + Codex CLI run inside the
  image from a ro bind of `/jhpce/shared`, once `which` and `hostname` exist in the image.
- Reframed the project: write safety only, network untouched, agent credentials provisioned.
  Rewrote `AGENTS.md`, wrote `docs/design.md` and `docs/implementation_plan.md`; moved first
  drafts to `docs/initial/`.
- Repository attached to `github.com/gpertea/jhpce-singbox`, default branch `devel`.

## Next

- Phase 1–3 of `docs/implementation_plan.md`: layout, `etc/mounts.tsv` with nested-mount
  validation, wrapper skeleton with `--dry-run`.
- Try building the thin image with Apptainer `--fakeroot` on a transfer node.
