# Implementation Plan (revision 3, 2026-10-07)

Supersedes `docs/initial/initial_plan_proposal.md`. Design: `docs/design.md`.
Measured facts: `docs/runtime_findings.md`. Test suite: `tests/test_wrapper.sh`.

| Phase | Content | Status |
|---|---|---|
| 0 | Runtime inventory and containment probes | done (`tests/runtime_probe.sh`) |
| 1 | Repository layout | done |
| 2 | `etc/mounts.tsv`, automount trigger, nested/autofs mount validation | done, tested |
| 3 | Wrapper skeleton: binds, synthetic home, `--write`/`--read`, deny binds, `--dry-run`, logging | done, tested |
| 3b | Durable synthetic home, skel, user mounts file, `--home-mode`, nested ro rebind | done, tested (45 checks) |
| 3c | Profiles, `config`, `--module`, read-only personal R/Python libraries | done, tested (56 checks) |
| 4 | Agent modes, per-sandbox agent config folders, settings seeding, sandbox notes | done, tested (71 checks) |
| 5 | Lua modulefile (development copy) | done, tested with `module use` |
| 6 | Validate on compute nodes | done: compute-148, compute-092, compute-147, compute-162 |
| 7 | Non-setuid fallback: host-root container under SCE 4.5.1 `--userns` | open |
| 8 | Codex and Claude modes | done (launch, args, `--yolo`); interactive login to be exercised by a user |
| 9 | Deliberate negative tests through an agent | open |
| 12 | Sandboxed Positron/VS Code remote sessions (`--sshd`), see `docs/positron_remote_plan.md` | planned, feasibility verified |
| 10 | Metadata inspectors | optional |
| 11 | README, deployment to `/jhpce/shared/libd` and `jhpce_module_config` | open |

## Layout

```text
bin/libd-ai-sandbox            wrapper
etc/mounts.tsv                 read-only mounts (ro only)
etc/deny-commands.txt          host binaries masked inside
libexec/deny                   the mask
libexec/make-rootfs            creates share/rootfs (not committed)
modulefiles/libd_ai_sandbox/0.1.lua
tests/test_wrapper.sh          refusal + live tests (28)
tests/runtime_probe.sh         raw runtime probe against a SIF (phase 0)
docs/  worklogs/
```

## Phase 4: agent config

For `--agent codex`: copy `~/.codex/{auth.json,config.toml}` into the synthetic home when missing,
or always with `--refresh-agent-config`; strip `[projects."..."]` trust entries that point at
paths not writable in the sandbox. For `--agent claude`: `~/.claude/{.credentials.json,settings.json}`
and `~/.claude.json`. Generate the agent hint file listing `$LIBD_AI_SANDBOX_RW`.
Tests: files present in synthetic home, real home unchanged, `.ssh` absent.

## Phase 7: non-setuid fallback

Run `tests/test_wrapper.sh` with `LIBD_AI_SANDBOX_RUNTIME` pointing at SCE 4.5.1 after adding
automatic `--userns` when the runtime's `starter-suid` is not setuid-root.

## Phase 8: agents

Resolve the agent binary (per-user install bound read-only, or a copy under `/jhpce/shared/libd`),
launch with relaxed agent-side permissions. Test: authenticates, reads `/dcs04/lieber/...`, write
there fails, write to a `--write` target succeeds.

## Phase 9: negative tests through an agent

Ask the agent to create, modify and delete under `/dcs04/lieber`, submit a Slurm job, ssh to a
node, and write into a `--write` target. Only the last may succeed; nothing else changes on host.
