# AGENTS.md

## Project: ai-singbox, a customizable Singularity container sandbox for AI agents (JHPCE)

A Singularity/Apptainer-based wrapper for running AI agents (Codex, Claude Code, plain shell)
on JHPCE so that the agent **cannot create, modify, or delete anything on cluster storage**
except inside locations the user explicitly designated for that run. The agent keeps the
invoking user's full *read* access at the same absolute paths.

The invoking user typically has write permission across many shared project directories. The
container takes that power away from the agent. That is the whole purpose.

Authoritative documents, in order:

0. `README.md` — user guide; keep it in step with the wrapper's behaviour.
1. `docs/design.md` — current design. Supersedes the first drafts.
2. `docs/implementation_plan.md` — phased plan with test expectations.
3. `docs/roadmap.md` — remaining work toward a shared module.
4. `docs/runtime_findings.md` — measured behaviour of the JHPCE runtimes; cite it rather than
   re-deriving facts.
5. `docs/initial/` — first drafts, kept for history only; do not follow them where they
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

1. **Read-only by default, kernel-enforced.** Host system dirs and `/jhpce/shared` (site
   `etc/mounts.tsv`) and the data folders (`read =` lines in profiles; the site `default`
   profile includes the site `libd` profile, which lists the LIBD exports) are bind-mounted `ro`; nested mounts under a ro source are
   rebound ro. Writable: `$MYSCRATCH` (default), the session home, scratch `/tmp`, the
   `write =` folders of the chosen profiles and each `--write PATH`; never from `config` or a
   mounts file.
2. **Bind real mount points, never autofs roots.** A read-only bind protects exactly one
   filesystem; mounts nested below it keep their own flags. Binding `/dcs04` ro left
   `/dcs04/lieber` writable (measured). The wrapper triggers automounts, checks `/proc/mounts`,
   and aborts on violation.
3. **Synthetic home by default.** `$HOME` keeps its real path inside, backed by
   `~/.ai-singbox/home` (durable). `--home-mode real-ro|real-rw` exposes the real home
   instead, rw only by explicit choice. Always pass `--home` or `--no-home`; under `--contain`
   with neither, the runtime mounts the real home read-write (measured).
4. **Write targets must already exist and are checked.** `--write` refuses `/`, system and
   `/jhpce/shared` paths, the real home, whole filesystems, read-only mount roots and their
   ancestors. The runtime must never create a mount point on host storage (measured to happen).
5. **No scheduler or remote-shell escape.** Host `sbatch`/`srun`/`salloc`/`scancel`/`scontrol`/
   `ssh`/`scp`/`sftp` are masked by a deny script (`etc/deny-commands.txt`); `/run/munge` and
   `~/.ssh` are never mounted.
6. **Scratch-backed tmp.** Always pass `--workdir`; the runtime's default `/tmp` is a 64 MB tmpfs.
7. **Host-root container, no image.** The container root is an empty skeleton directory with the
   host's `/usr`, `/etc`, `/opt` and SSSD sockets bound read-only, so the environment, Lmod and
   modules match the node exactly. Do not reintroduce a built image without a measured reason.
8. **SingularityCE 3.11.4 by absolute path.** Setuid is not needed for safety; 3.11.4 is preferred
   for speed and correct group display. Call runtimes by absolute path; the site runtime
   modulefiles fail in non-interactive shells.
9. **Inspectable.** `--dry-run` prints the bind table and exact command; every launch is logged as
   JSON under `~/.ai-singbox/logs`.
10. **Tests before features.** `tests/test_wrapper.sh` must pass on a transfer node and on a
    compute node. Tests that attempt writes to read-only paths check the host afterwards and
    remove any leak.

## Working style

- Prefer conservative defaults; make destructive behaviour impossible, not discouraged.
- Use configuration files for paths; no hard-coded storage roots in the wrapper.
- Build commands as bash arrays, no `eval`.
- When a probe writes test files, put them under `$MYSCRATCH` or a directory the user owns, and
  clean up.
- Lua modules follow `LieberInstitute/jhpce_module_config` conventions (hostname guard,
  `LmodMessage`). Develop under `modulefiles/` here with `module use` before committing to the
  LieberInstitute repositories (`/jhpce/shared/libd/modulefiles`, `/jhpce/shared/libd/core`).

## Default invocation

```bash
module use /dcs04/lieber/lcolladotor/dbDev_LIBD001/jhpce-singbox/modulefiles   # development
module load ai-singbox/0.1
ai-singbox --dry-run --write /dcs04/lieber/<lab>/<project>/agent_out
ai-singbox --write /dcs04/lieber/<lab>/<project>/agent_out
```

Inside, paths are identical to the host; only `$MYSCRATCH`, the synthetic home, `/tmp` and the
`--write` directories are writable (listed in `$AI_SINGBOX_RW`).
