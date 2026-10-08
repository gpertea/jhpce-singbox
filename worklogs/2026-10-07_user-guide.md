# 2026-10-07 — User guide, crawler example, symlink fix

- `README.md`: user guide (quick start, read-only vs writable, nested `--write`, agents, home,
  profiles, troubleshooting) built around a worked example: an agent inventorying R objects
  under `/dcs04/lieber/marmaypag` with output to `.../marmaypag/data-inventory`.
- `examples/profiles/marmaypag-inventory.conf`, `examples/prompts/r-object-inventory.md`.
  Validated with dry runs and a stand-in output folder; the real `data-inventory` folder was
  intentionally not created.
- Symlinks: links into mounted storage resolve (same paths inside). The skeleton root used to
  mirror host top-level dirs, so a link to unmounted `/dcl01` looked like an empty folder; the
  skeleton now holds only system mount points and such links are broken. Regression tests added.
- Tests: 73/73 on transfer-01, 70/70 on compute-177.
