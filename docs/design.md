# libd-ai-sandbox: Design (revision 2, 2026-10-07)

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
| Escape to an unsandboxed process | `sbatch`/`srun`/`salloc`, `ssh`/`scp`/`rsync` to a login node | Binaries absent from the image, `/run/munge` and `~/.ssh` not mounted. Credentials are excluded **because they enable writes outside the sandbox**, not for secrecy |
| Network services that write to JHPCE storage on the user's behalf | Globus, a mounted cloud share, a web app with storage access | Out of scope; requires user credentials the agent does not have by default |

## 3. Runtime

JHPCE ships both forks of the original Singularity:

| Module | What it is | Status on JHPCE |
|---|---|---|
| `singularity/3.11.4` (default) | SingularityCE (Sylabs fork) | setuid install; fastest start; **default runtime** |
| `singularity/4.5.1` | SingularityCE | non-setuid; works only with `--userns`; acceptable fallback |
| `apptainer/1.5.3` | Apptainer (Linux Foundation fork) | non-setuid; converts SIF to a sandbox in `/tmp` per launch; acceptable fallback |

Naming: the documentation says "Singularity/Apptainer" or "the container runtime" generically,
and "SingularityCE 3.11.4" when it means the default. All three accept the same `exec` flags
and the same `src:dst:ro` bind syntax, and all three enforce read-only binds correctly, so the
wrapper is runtime-agnostic and selects via `LIBD_AI_SANDBOX_RUNTIME` (absolute path), defaulting
to SingularityCE 3.11.4. Environment prefixes differ (`SINGULARITY_*` vs `APPTAINER_*`); the
wrapper passes options on the command line only and never relies on prefixed variables.

The runtime modulefiles only load on compute/transfer nodes, so the wrapper refuses to run on a
login node with a message pointing at `srun --pty bash`.

## 4. Filesystem model

Inside the container the agent sees:

| Path | Backing | Mode | Notes |
|---|---|---|---|
| `/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber`, further lab exports from `etc/mounts.tsv` | the real NFS exports | **ro** | same absolute paths as the host |
| `/jhpce/shared` | real | **ro** | modules, shared software, LIBD module trees |
| `/users/<user>` (`$HOME`) | `$MYSCRATCH/ai-sandbox/home` | rw | persistent across runs; see §5 |
| `/tmp`, `/var/tmp` | `$MYSCRATCH/ai-sandbox/work/{tmp,var_tmp}` via `--workdir` | rw | without `--workdir` the runtime gives a 64 MB tmpfs |
| `/agent_out` and/or a same-path directory | the user's `--write` target | rw | §6 |
| `/payload` | the user's `--payload` path | ro | optional inputs outside the standard roots |
| `/host_home` | the real `/users/<user>` | ro | optional, `--read-home`, for the user's own scripts |
| image root (`/usr`, `/opt`, …) | SIF | ro | |

Nothing else from the host is visible: `--contain` is always set, `mount hostfs = no` site-wide,
and the current directory is never auto-bound (`--no-mount cwd`, `--pwd $HOME`).

### 4.1 Mount rules (hard requirements)

1. **A read-only bind protects exactly one filesystem.** Mounts nested below it keep their own
   flags, whether pre-existing or automounted later. Binding the autofs root `/dcs04` read-only
   left `/dcs04/lieber` writable (measured). Therefore `etc/mounts.tsv` lists real export
   mount points (`/dcs04/lieber`), never autofs roots, and the wrapper verifies from
   `/proc/mounts` at launch that each ro source is a mount point (or lies within exactly one)
   and that no other mount point exists strictly below it. Any violation aborts the launch.
2. The runtime creates missing bind *destination* directories, and for a same-path target
   nested under a read-only parent it did so **on the host** (measured). Writable targets must
   exist on the host before launch; the wrapper creates them itself with `mkdir -p` only when the
   user passed `--write`, and never lets the runtime do it.
3. The wrapper always passes `--home`. Under `--contain` without `--home`/`--no-home` the real
   home is mounted read-write (measured).
4. `mounts.tsv` columns: `src dest mode required`. Missing `required=no` sources are skipped with
   a warning; missing `required=yes` sources abort. Mode `rw` is rejected in this file; writable
   paths come only from the command line.

Default `etc/mounts.tsv`:

```tsv
# src            dest             mode  required
/jhpce/shared    /jhpce/shared    ro    yes
/dcs04/lieber    /dcs04/lieber    ro    no
/dcs05/lieber    /dcs05/lieber    ro    no
/dcs07/lieber    /dcs07/lieber    ro    no
# /dcs06/lieber and /dcs10/lieber do not exist on current nodes; add when they do
```

Users who need another lab's export can add a line in a personal override file
(`$LIBD_AI_SANDBOX_MOUNTS_EXTRA`) with the same format and the same `rw`-rejection rule.

## 5. Synthetic home

- Location: `$MYSCRATCH/ai-sandbox/home`, mounted at the real `$HOME` path so tools and the
  agent's own config find what they expect.
- Persistent across runs so agent logins, caches, and installed user packages survive. `--reset-home`
  moves it aside (`home.<timestamp>`) and starts fresh.
- First run creates `.bashrc` (minimal, generated), `.cache/`, `.config/`, `.local/`, `R/`
  (the shared R site profile tries to create `$HOME/R/<version>`), and sets `TMPDIR`,
  `XDG_CACHE_HOME`, `PIP_CACHE_DIR`, `R_LIBS_USER`, `umask 077`.
- **Agent configuration is provisioned by default**, limited to the selected agent's own directory:
  `~/.codex/{auth.json,config.toml,AGENTS.md}` for Codex; `~/.claude/{.credentials.json,settings.json}`
  and `~/.claude.json` for Claude Code. These files let the agent authenticate to its LLM service,
  which is required for it to work at all, and they confer no write capability on JHPCE storage.
  Copies are refreshed only when missing or when `--refresh-agent-config` is given.
- **Never copied**: `.ssh/`, `.aws/`, `.gcp/`, `.azure/`, `.netrc`, `.git-credentials`, `.Renviron`,
  `.Rprofile`, conda tokens. They are excluded because they are escape routes to unsandboxed
  writes (ssh to a login node has full write access) or they change tool behaviour unpredictably.
- The real home is never writable. `--read-home` exposes it read-only at `/host_home` for users who
  keep scripts there. It is not mounted at `$HOME` because the synthetic home occupies that path.

## 6. Writable output

Two forms, both explicit per run:

- `--write PATH` mounts PATH read-write at `/agent_out` (unambiguous, recommended default).
- `--write-same-path PATH` mounts PATH read-write at the same absolute path, nested under its
  read-only parent. Measured to work; preferred when the agent must write next to a project it is
  also reading. Both may be given.

Safeguards, since the write target is the one place the agent *can* destroy things:

1. PATH must not be, or contain, any ro root from `mounts.tsv` (rejects `--write /dcs04/lieber`).
2. PATH must be empty on first use, or carry the marker file `.libd_ai_sandbox_out` written by the
   wrapper on first use. A non-empty directory without the marker is refused unless
   `--write-force` is given. This stops `--write` from being pointed at an existing data directory
   by mistake.
3. PATH is created with `mkdir -p` by the wrapper when absent (after check 1).
4. The launch log entry is also copied into PATH as `.libd_ai_sandbox_launch.<timestamp>.json`.

## 7. Escape routes to unsandboxed writes

- Slurm: `sbatch srun salloc scancel squeue` are not in the image and `/run/munge` is never
  bound, so even a user-installed client cannot authenticate. No deny-wrapper directory is
  needed; a test asserts absence. A controlled re-entry wrapper (`libd-ai-sbatch`, submitting a
  job that re-launches the same sandbox) is future work.
- ssh/scp/rsync/sftp: not in the image, no keys in the synthetic home. JHPCE requires 2FA for
  password logins, so an agent cannot open a session even if it installs a client.
- Host software reachable through the ro `/jhpce/shared` bind must be checked for Slurm or ssh
  clients when the mount list grows; today none are there (they live in `/usr/bin` on the host).

## 8. Container image

Keep the image thin and get software from the host:

- Base: Rocky Linux 9 (matches compute nodes), plus the userland the shared tools shell out to:
  `which hostname procps-ng util-linux findutils file less tree jq git tar gzip bzip2 xz zstd
  ca-certificates glibc-langpack-en`. `rockylinux:9-minimal` lacks `which` and `hostname`, which
  breaks the shared R's startup (measured).
- `Lmod` (EPEL) plus `MODULEPATH` pointing at the ro-bound `/jhpce/shared/{libd,jhpce,community}/modulefiles`,
  so `module load conda_R` works inside and the environment matches a compute node. Shared
  `conda_R/4.5.x` and Node 24 were verified to run from the ro bind.
- No R or Python stack baked in at first. If Lmod-in-container proves fragile, fall back to a
  second, fatter image; the wrapper does not care.
- Agent CLIs: Codex is a Node script and runs from a ro bind of the user's install
  (`~/.local/lib/node_modules/@openai/codex`) or from a copy in `/jhpce/shared/libd`. Claude Code
  is a self-contained binary and runs the same way. Preferred: install both under
  `/jhpce/shared/libd/core/libd_ai_sandbox/<ver>/agents/` so the wrapper does not depend on
  per-user installs.
- Building: SingularityCE 3.11.4 `--fakeroot` needs `/etc/subuid` entries, which users do not
  have. Apptainer 1.5.3 `--fakeroot` works without them (measured `uid=0` in build-like mode) and
  is the first thing to try for `%post` with `dnf`. Otherwise build from a Dockerfile elsewhere and
  pull the OCI image.

## 9. Agents

`--agent codex | claude | shell`, default `shell` until Codex/Claude modes are validated.

Because the container is the safety boundary, the agents' own permission prompts may be relaxed
inside it. That is the point of the project: `claude --dangerously-skip-permissions` and
`codex --sandbox danger-full-access` (or `--yolo`) become acceptable because every write they can
make lands in scratch or in the designated output. The agent's own sandbox (Codex uses Landlock
plus seccomp on Linux) may still be left on as a second layer if it works inside the container;
this is a test item, not a requirement.

The agent is told where it is via a generated `AGENTS.md`/`CLAUDE.md` in the synthetic home:

```text
You are running inside libd-ai-sandbox on JHPCE.
All of /dcs*/lieber and /jhpce/shared is mounted read-only; do not try to write there.
Durable outputs go to /agent_out (if present). Temporary files go to $HOME or /tmp (scratch).
Slurm and ssh are unavailable here by design.
Prefer metadata inspection over loading full datasets.
```

## 10. Wrapper

`libd-ai-sandbox` (bash). Options for the first version:

```text
--agent codex|claude|shell       default shell
--write PATH                     rw at /agent_out
--write-same-path PATH           rw at PATH
--write-force                    skip the empty-or-marker check
--payload PATH                   ro at /payload
--read-home                      real home ro at /host_home
--reset-home                     archive and recreate the synthetic home
--refresh-agent-config           re-copy the agent's config files
--cmd 'COMMAND' | -- ARGS...     run instead of the agent's default command
--dry-run                        print the full runtime command and bind table, exit
--print-binds                    print the resolved bind table, exit
--help
```

Launch sequence: refuse on login nodes → resolve runtime → validate image → load and verify
mounts (§4.1) → prepare scratch dirs and synthetic home (§5) → validate write targets (§6) →
assemble command → log → exec.

Flags always passed:

```text
--contain --cleanenv --no-mount cwd
--home $MYSCRATCH/ai-sandbox/home:$HOME
--workdir $MYSCRATCH/ai-sandbox/work
--pwd $HOME
--env TERM=$TERM --env LANG=C.UTF-8
```

Launch log (`$MYSCRATCH/ai-sandbox/logs/<timestamp>.json`): timestamp, user, host, Slurm job id,
runtime path and version, image path and sha256, mounts file path, resolved bind table, agent,
write/payload paths, command, dry-run flag.

## 11. Lua module

Thin, following `LieberInstitute/jhpce_module_config` conventions (hostname guard, `LmodMessage`
on load/unload):

```lua
local root = "/jhpce/shared/libd/core/libd_ai_sandbox/0.1"
prepend_path("PATH", pathJoin(root, "bin"))
setenv("LIBD_AI_SANDBOX_ROOT", root)
setenv("LIBD_AI_SANDBOX_IMAGE", pathJoin(root, "images", "libd-ai-rocky9.sif"))
setenv("LIBD_AI_SANDBOX_MOUNTS", pathJoin(root, "etc", "mounts.tsv"))
setenv("LIBD_AI_SANDBOX_RUNTIME", "/jhpce/shared/jhpce/core/singularity/3.11.4/bin/singularity")
```

Developed and tested from this repository (`modulefiles/`) with `module use` before being
committed to the LieberInstitute repositories.

## 12. Open questions

- Which additional lab exports beyond `*/lieber` should ship in the default mounts file?
- Should `--write-same-path` be the default when the user is inside a project directory?
- Does Lmod inside the container reproduce the compute-node environment closely enough, or is a
  fat image needed anyway for Python (the shared conda has no `anndata`/`h5py`)?
- Does Codex's Landlock sandbox function inside the setuid-started container?
- Where should the agent CLIs live: per-user installs or `/jhpce/shared/libd`?
