# Implementation Plan (revision 2, 2026-10-07)

Supersedes `docs/initial/initial_plan_proposal.md`. Design: `docs/design.md`.
Measured facts: `docs/runtime_findings.md`.

## Phase 0: Confirm local assumptions — DONE

See `docs/runtime_findings.md`. Decisions taken from it:

- Default runtime SingularityCE 3.11.4 by absolute path; Apptainer 1.5.3 / SCE 4.5.1 `--userns`
  as fallbacks.
- Bind real NFS exports, never autofs roots; verify nested mounts from `/proc/mounts`.
- Always `--home`, always `--workdir`, always `--contain --cleanenv --no-mount cwd`.
- Writable targets must pre-exist; the wrapper creates them, the runtime never does.
- Network is left alone.

## Phase 1: Repository layout

```text
jhpce-singbox/
├── AGENTS.md
├── README.md
├── docs/
│   ├── design.md
│   ├── implementation_plan.md
│   ├── runtime_findings.md
│   └── initial/                 # superseded first drafts, kept for history
├── bin/libd-ai-sandbox
├── etc/mounts.tsv
├── modulefiles/libd_ai_sandbox/0.1.lua
├── container/libd-ai-rocky9.def
├── images/README.md             # images are not committed; where they live
├── tools/                       # metadata inspectors (later)
└── tests/
    ├── runtime_probe.sh         # exists
    ├── test_mounts.sh
    ├── test_home.sh
    ├── test_write_targets.sh
    └── test_escape_routes.sh
```

## Phase 2: Mount configuration and validation

- `etc/mounts.tsv` as in design §4.1.
- Wrapper function `validate_ro_sources`: for each ro source, from `/proc/mounts` find the
  mount point that contains it; require that no other mount point has it as a strict prefix.
  Abort with a clear message naming the offending nested mount.
- Reject `rw` entries in any mounts file.
- `tests/test_mounts.sh`: positive (`/dcs04/lieber`), negative (`/dcs04` must be refused),
  and an in-container write attempt under each bound root must fail.

## Phase 3: Wrapper skeleton

Implement the launch sequence of design §10 with `--agent shell` only, plus `--dry-run` and
`--print-binds`. Use `set -euo pipefail`, no `eval`; build the command as a bash array and
`exec` it. Print the array verbatim for `--dry-run`.

Runtime detection: `LIBD_AI_SANDBOX_RUNTIME` must be an executable; print its `--version` in
the log. Refuse to run when `$HOSTNAME` does not match `compute|transfer`.

## Phase 4: Synthetic home and agent config

Design §5. Create the directory tree, generated `.bashrc`, generated `AGENTS.md`/`CLAUDE.md`
hint file, agent config copy with the allow-list only. `--reset-home`, `--refresh-agent-config`.
`tests/test_home.sh`: `$HOME` path unchanged inside, write lands in scratch, `.ssh` absent,
real home unchanged after a run.

## Phase 5: Writable targets

Design §6: `--write`, `--write-same-path`, marker file, ancestor check, `--write-force`.
`tests/test_write_targets.sh`: `/agent_out` writable; same-path writable; parent still ro;
`--write /dcs04/lieber` refused; non-empty dir without marker refused.

## Phase 6: Lua modulefile

Design §11, in `modulefiles/`, loaded with `module use $PWD/modulefiles` during development.

## Phase 7: Container image

Design §8. Build order of attempts: Apptainer `--fakeroot` on a transfer node → Docker/Podman
elsewhere and `pull docker://`. Verify inside: `module avail` sees the three JHPCE module trees,
`module load conda_R/4.5.x` then the Bioconductor load test from `runtime_findings.md`,
`node --version`, Codex `--version`, Claude Code `--version`.

## Phase 8: Shell-mode validation on a compute node

`srun --pty bash`, `module use …; module load libd_ai_sandbox; libd-ai-sandbox --dry-run;
libd-ai-sandbox`. Re-run `tests/runtime_probe.sh` with the real image. All tests in `tests/`
must pass on a compute node, not only on `transfer-01`.

## Phase 9: Escape-route tests

`tests/test_escape_routes.sh`: scheduler and ssh binaries absent; `/run/munge` absent; `~/.ssh`
absent; attempt `python3 -c 'import socket'` to a login node port 22 is allowed to connect but
there must be no key material to use.

## Phase 10: Launch logging

Design §10 log record; copy into the write target when present.

## Phase 11: Codex and Claude modes

Only after Phase 8 passes. Default commands:

- `codex --sandbox danger-full-access` (or `--yolo` if that is the current flag) with the
  generated `AGENTS.md` in the synthetic home.
- `claude --dangerously-skip-permissions` with the generated `CLAUDE.md`.

Test that both authenticate from the copied config, read `/dcs04/lieber/...`, fail to write
there, and write to `/agent_out`.

## Phase 12: Deliberate negative tests with an agent

Ask the agent to: create a file under `/dcs04/lieber`; modify and delete an existing file there;
submit a Slurm job; write into `/payload`; write into `/agent_out`. Expected: first four fail,
last succeeds, nothing changes on the host outside the designated target.

## Phase 13: Metadata inspectors (optional for v1)

`tools/libd-ai-inspect-{h5ad,h5,rse}` emitting JSON without materializing matrices, using the
shared conda R and a small Python environment. Can live in the image or in `/jhpce/shared/libd`.

## Phase 14: README and release

README covers purpose, the one goal, what is and is not protected, invocation examples, where
the synthetic home lives and how to reset it, how to read launch logs, known limitations.
Release when Phases 2–10 have passing tests on a compute node.
