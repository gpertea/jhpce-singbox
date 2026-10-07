# AGENTS.md

## Project: LIBD/JHPCE AI Agent Data-Protection Sandbox (`libd-ai-sandbox`)

A Singularity/Apptainer-based wrapper for running AI agents (Codex, Claude Code, plain shell)
on JHPCE so that the agent **cannot create, modify, or delete anything on LIBD/JHPCE storage**
except inside locations the user explicitly designated for that run. The agent keeps the
invoking user's full *read* access at the same absolute paths.

The invoking user typically has write permission across many shared project directories. The
container takes that power away from the agent. That is the whole purpose.

Authoritative documents, in order:

1. `docs/design.md` — current design. Supersedes the first drafts.
2. `docs/implementation_plan.md` — phased plan with test expectations.
3. `docs/runtime_findings.md` — measured behaviour of the JHPCE runtimes; cite it rather than
   re-deriving facts.
4. `docs/initial/` — first drafts, kept for history only; do not follow them where they
   disagree with the above.

`worklogs/` holds dated plans and work logs (`YYYY-MM-DD_<topic>.md`) written on request.

## Scope: write safety, nothing else

In scope: every path by which an unintended write could reach storage the user did not
designate — direct filesystem writes, writes to the real home, and escape to an unsandboxed
process (Slurm submission, ssh/scp/rsync to another node).

Explicitly **out of scope**: data exfiltration, confidentiality, malicious code, multi-user
separation. Codex and Claude Code need network access to their LLM service; the wrapper never
restricts the network. Agent credentials for those services are provisioned into the sandbox
by default because they confer no write capability on JHPCE storage. `.ssh`, `.aws`, `.netrc`
and similar are excluded because they *do* (they are escape routes), not for secrecy.

Judge every design choice by one question: can this lead to an unintended write to storage the
user did not designate?

## Operating principles

1. **Read-only by default, kernel-enforced.** LIBD/JHPCE exports are bind-mounted `ro`.
   Writable paths come only from the command line, never from the mounts file.
2. **Bind real mount points, never autofs roots.** A read-only bind protects exactly one
   filesystem; mounts nested below it keep their own flags. Binding `/dcs04` ro left
   `/dcs04/lieber` writable (measured). The wrapper verifies this from `/proc/mounts` and aborts
   on violation.
3. **Synthetic home, not the real home.** `$HOME` keeps its real path inside, backed by
   `$MYSCRATCH/ai-sandbox/home`. Always pass `--home`; under `--contain` without it the real home
   is mounted read-write (measured).
4. **Writable targets pre-exist and are checked.** The wrapper creates `--write` targets itself,
   refuses targets that are or contain a read-only root, and refuses non-empty targets without
   the wrapper's marker file unless forced. The runtime must never create a mount point on host
   storage (measured to happen for same-path targets).
5. **No scheduler or remote-shell escape.** `sbatch`/`srun`/`salloc`/`scancel`/`ssh`/`scp`/`rsync`
   are absent from the image; `/run/munge` and `~/.ssh` are never mounted.
6. **Scratch-backed tmp.** Always pass `--workdir`; the runtime's default `/tmp` is a 64 MB tmpfs.
7. **Thin image, host software.** Rocky 9 plus basic userland (`which`, `hostname`, …) and Lmod;
   R/Python/Node come from the read-only `/jhpce/shared` bind.
8. **Runtime-agnostic, SingularityCE 3.11.4 by default.** Setuid is not needed for safety;
   3.11.4 is preferred for speed and correct group display. SingularityCE 4.5.1 `--userns` is the
   supported fallback; Apptainer 1.5.3 works but is slow without squashfuse. Call runtimes by
   absolute path; the modulefiles fail in non-interactive shells.
9. **Inspectable.** `--dry-run` prints the exact command; every launch is logged with image
   sha256, bind table, user, host, command.
10. **Tests before features.** Each phase in `docs/implementation_plan.md` names its tests. Tests
    that attempt writes to read-only paths must check the host afterwards and remove any leak.

## Working style

- Prefer conservative defaults; make destructive behaviour impossible, not discouraged.
- Use configuration files for paths; no hard-coded storage roots in the wrapper.
- Build commands as bash arrays, no `eval`.
- When a probe writes test files, put them under `$MYSCRATCH` or a directory the user owns, and
  clean up.
- Lua modules follow `LieberInstitute/jhpce_module_config` conventions (hostname guard,
  `LmodMessage`). Develop under `modulefiles/` here with `module use` before committing to the
  LieberInstitute repositories (`/jhpce/shared/libd/modulefiles`, `/jhpce/shared/libd/core`).

## Default invocation (target)

```bash
module load libd_ai_sandbox
libd-ai-sandbox --agent codex --write /dcs04/lieber/<project>/agent_outputs/$USER/run_001
```

Inside the container the durable output appears at `/agent_out`; everything under
`/dcs*/lieber` and `/jhpce/shared` is read-only.
