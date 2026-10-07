# libd-ai-sandbox: Design (revision 3, 2026-10-07)

Supersedes `docs/initial/project_details.md`. Measured facts behind the choices here are in
`docs/runtime_findings.md`.

## 1. The one goal

> An AI agent (Codex, Claude Code, or a plain shell) running on JHPCE must be unable to create,
> modify, or delete anything on LIBD/JHPCE storage except inside locations the user explicitly
> chose for that run.

The invoking user typically has write permission across many project directories. The container
removes that power from the agent while preserving the user's full *read* access at the same
absolute paths.

### What this is not about

- **Confidentiality / exfiltration.** Codex and Claude Code need network access to their LLM
  service; whatever the agent can read, it can send there. That is accepted and governed by
  institutional policy, not by this wrapper. The wrapper never restricts the network.
- **Malicious code.** The agent is treated as a careless but not adversarial automated user.
- **Multi-user separation, quotas, account policy.**

Everything in the design is judged by one question: *can this lead to an unintended write to
storage the user did not designate?*

## 2. Threat model, concretely

Unintended writes happen through four channels. The design closes the first three and documents
the fourth.

| Channel | Example | Control |
|---|---|---|
| Direct filesystem writes | `rm -rf`, `sed -i`, tools writing caches or indexes next to inputs, scripts assuming inputs are writable | Kernel-enforced read-only bind mounts; only designated paths writable |
| Writes to the real home | dotfile edits, `pip install --user`, R library installs, `.Rhistory` | Real home never mounted; synthetic scratch-backed home at the same path |
| Escape to an unsandboxed process | `sbatch`/`srun`/`salloc`, `ssh`/`scp` to another node | Deny script bound over each such host binary, `/run/munge` and `~/.ssh` never mounted. Credentials are excluded **because they enable writes outside the sandbox**, not for secrecy |
| Network services that write to JHPCE storage on the user's behalf | Globus, a mounted cloud share, a web app with storage access | Out of scope; requires user credentials the agent does not have by default |

## 3. Runtime

JHPCE ships both forks of the original Singularity:

| Module | What it is | Status on JHPCE |
|---|---|---|
| `singularity/3.11.4` (default) | SingularityCE (Sylabs fork) | setuid install; fastest start; correct group display; **default runtime** |
| `singularity/4.5.1` | SingularityCE | non-setuid; works only with `--userns`; groups display as `nobody`; fallback |
| `apptainer/1.5.3` | Apptainer (Linux Foundation fork) | non-setuid; slow SIF start (no squashfuse); fallback |

Setuid is **not** required for the safety goal: all three runtimes enforce read-only binds,
refuse remounts, and keep supplementary-group read access (`docs/runtime_findings.md`).
SingularityCE 3.11.4 is the default because it is fastest and shows correct group ownership.

The wrapper calls the runtime by absolute path (`LIBD_AI_SANDBOX_RUNTIME`), never through
`module load` (the site runtime modulefiles fail when `HOSTNAME` is unset). Options go on the
command line only, never via `SINGULARITY_*`/`APPTAINER_*` variables. Running the host-root
container (§4) under a non-setuid runtime with `--userns` is not yet tested; until it is, the
fallbacks are documented, not supported.

The wrapper refuses to run anywhere but a compute or transfer node.

## 4. Host-root container: no image

The container root is a **skeleton directory** (`share/rootfs`, made by `libexec/make-rootfs`):
empty mount-point directories mirroring the host's top level plus the `bin -> usr/bin` style
symlinks. The host's `/usr`, `/etc`, `/opt`, `/var/lib/sss` and `/var/lib/alternatives` are
bind-mounted **read-only** on top. Consequences:

- The environment *is* the node's environment: same OS packages, same `/etc/profile.d`, same
  Lmod and `MODULEPATH`, `JHPCE_ROCKY9_DEFAULT_ENV` and `JHPCE_tools` loaded at login,
  `module load conda_R/4.5.x` works, user and group names resolve through the SSSD socket.
  On a compute node it is that compute node's OS.
- Nothing to build or maintain; no image digest to track. OS updates on the nodes flow through.
- Singularity refuses `/` itself as a container (`/ as sandbox is not authorized`), hence the
  skeleton. Startup is about 0.2 s, 1 s including the login profile.
- Host software can now include escape tools (`sbatch`, `ssh`), so these are masked (§7).

Modules loaded in the user's host shell are **not** carried in (`--cleanenv`, fresh login); the
session starts from the site default modules. Carrying `LOADEDMODULES` over is a possible
follow-up.

## 5. Filesystem model

Inside the container the agent sees:

| Path | Backing | Mode |
|---|---|---|
| `/usr`, `/etc`, `/opt`, `/var/lib/sss`, `/var/lib/alternatives` | host | **ro** |
| `/jhpce/shared` | host | **ro** |
| `/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber` (`etc/mounts.tsv`) | host NFS exports | **ro** |
| any `--read PATH` | host | **ro**, same path |
| `$MYSCRATCH` (`/fastscratch/myscratch/<user>`) | host | **rw** by default (`--no-scratch` to drop) |
| any `--write PATH` | host | **rw**, same path |
| `$HOME` (`/users/<user>`) | `$MYSCRATCH/ai-sandbox/home` | rw (synthetic) |
| `/tmp`, `/var/tmp` | `$MYSCRATCH/ai-sandbox/work/{tmp,var_tmp}` | rw |
| everything else (skeleton) | `share/rootfs` | ro, empty |

`$MYSCRATCH` is writable because it is the user's own purge-able scratch space, it is where the
agent's home and temp already live, and it is the natural staging area for intermediate results.
It holds nothing that is shared or irreplaceable by policy.

### 5.1 Mount rules (enforced by the wrapper at every launch)

1. **A read-only bind protects exactly one filesystem.** Nested mounts keep their own flags
   (binding the autofs root `/dcs04` read-only left `/dcs04/lieber` writable, measured). For every
   bind source the wrapper first triggers its automount (a name lookup *inside* it; `readlink` and
   `stat` do not trigger autofs), then reads `/proc/mounts` and refuses the launch if the source lies
   on an autofs map or if any filesystem is mounted below it.
2. Mounts files (`etc/mounts.tsv`, optional `$LIBD_AI_SANDBOX_MOUNTS_EXTRA`) may only contain
   `ro` entries. Format `src dest mode required`; missing `required=no` sources are skipped.
3. The wrapper always passes `--home`; under `--contain` without it the real home is mounted
   read-write (measured).
4. Bind arguments are ordered by destination depth so parents are mounted before children.
5. `--contain`, `--cleanenv`, `--no-mount cwd` always. The container starts in the host's current
   directory when that directory is visible inside, otherwise in `$HOME`.

## 6. Writable paths

`--write PATH` (repeatable) mounts an existing directory read-write at its own path, nested inside
its read-only parent. The wrapper refuses a target that:

- does not exist (no runtime-created mount points on host storage; measured to happen otherwise),
- is `/`, or lies under `/usr /etc /opt /var /boot /proc /sys /dev /run /jhpce/shared`,
- overlaps the real home (the synthetic home occupies that path),
- equals or contains a read-only mount source (`--write /dcs04/lieber`, `--write /dcs04`),
- is the root of a whole filesystem (`--write /fastscratch/myscratch`),
- sits on an autofs map or has filesystems mounted below it.

The list of writable paths is printed at startup, recorded in the launch log, and exported inside
as `LIBD_AI_SANDBOX_RW` (colon-separated) so the agent can be told where it may write.

The earlier `/agent_out` and `/payload` aliases are dropped: same-path `--write`/`--read` keep paths
identical to the host, which is what scripts, notebooks and agents expect.

## 7. Escape routes to unsandboxed writes

- `etc/deny-commands.txt` lists host binaries that would start processes outside the sandbox:
  `sbatch srun salloc scancel scontrol sbcast strigger scrontab ssh scp sftp slogin`. Each is
  masked by a read-only bind of `libexec/deny`, which prints a message and exits 126.
- `/run` is the skeleton's empty directory, so `/run/munge` is absent and no Slurm client can
  authenticate even if run from another path. `squeue`/`sinfo` simply fail.
- No ssh keys exist in the synthetic home; setuid binaries (`sudo`, `su`, `ssh-keysign`) are
  inert because the container is mounted `nosuid`.
- `rsync` stays available for local copies; remote rsync needs `ssh`, which is masked.
- A controlled re-entry wrapper (`libd-ai-sbatch`, a job that re-launches the same sandbox) is
  future work.

## 8. Synthetic home

- `$MYSCRATCH/ai-sandbox/home`, mounted at the real `$HOME` path, persistent across runs;
  `--reset-home` archives it as `home.<timestamp>`.
- First run creates `.bashrc` (sources `/etc/bashrc`, sets a `[sbx ...]` prompt), `.bash_profile`,
  `.cache/`, `.config/`, `.local/bin/`, `R/`.
- The user's umask is inherited, not forced to 077: files written into shared lab directories via
  `--write` must stay group-readable.
- Agent configuration (Codex `auth.json`/`config.toml`, Claude `.credentials.json`/`settings.json`,
  `.claude.json`) will be copied in by default for the selected agent (phase 4). These confer no
  write capability on JHPCE storage. `.ssh`, `.aws`, `.netrc`, `.git-credentials` are never copied.
- Personal R libraries in the real `~/R/<ver>` are not visible. Exposing them read-only is an
  open question (§12).

## 9. Agents

`--agent shell` is implemented. `codex` and `claude` are planned (phase 11). Because the container
is the safety boundary, their own permission prompts can be relaxed inside it
(`claude --dangerously-skip-permissions`, Codex full-access mode). They will be told where they
are via generated `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md` naming the writable paths.

## 10. Wrapper (`bin/libd-ai-sandbox`, implemented)

```text
--write PATH        rw at same path (repeatable)
--read PATH         ro at same path (repeatable)
--no-scratch        do not mount $MYSCRATCH rw
--cmd STRING        bash -lc STRING
-- CMD ARGS...      run CMD in a login environment
--agent shell       (codex|claude planned)
--reset-home        archive and recreate the synthetic home
--dry-run           print bind table and runtime command
--print-binds       print bind table
--quiet
```

Configuration by environment: `LIBD_AI_SANDBOX_RUNTIME`, `LIBD_AI_SANDBOX_MOUNTS`,
`LIBD_AI_SANDBOX_MOUNTS_EXTRA`, `LIBD_AI_SANDBOX_ROOTFS`, `LIBD_AI_SANDBOX_DENY`.

Each launch writes `$MYSCRATCH/ai-sandbox/logs/<timestamp>-<pid>.json`: time, user, host, Slurm
job id, wrapper and runtime versions, host OS, rootfs, mounts files, writable paths, bind table,
full command. The log lives in writable scratch, so it is a record, not tamper-proof evidence.

## 11. Lua module

`modulefiles/libd_ai_sandbox/0.1.lua` (development): derives its root from its own location,
prepends `bin` to `PATH`, sets `LIBD_AI_SANDBOX_ROOT` and `LIBD_AI_SANDBOX_RUNTIME`, and guards
against an unset `HOSTNAME`. For deployment the root becomes an explicit
`/jhpce/shared/libd/core/libd_ai_sandbox/<ver>` path in `jhpce_module_config`.

## 12. Open questions

- Which lab exports beyond `*/lieber` belong in the default mounts file?
- Expose the real `~/R/<ver>` and `~/.local` read-only so personal packages work?
- Carry the host shell's loaded modules into the session?
- Validate the host-root container under SingularityCE 4.5.1 `--userns` as a fallback.
- Does Codex's own Landlock sandbox work inside the container?
- Where should agent CLIs live: per-user installs or `/jhpce/shared/libd`?
