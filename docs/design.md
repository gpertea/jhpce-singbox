# ai-singbox: Design (revision 7, 2026-10-09)

Supersedes `docs/initial/project_details.md`. Measured facts behind the choices here are in
`docs/runtime_findings.md`.

## 1. The one goal

> An AI agent (Codex, Claude Code, or a plain shell) running on JHPCE must be unable to create,
> modify, or delete anything on cluster storage except inside locations the user explicitly
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
| Writes to the real home | dotfile edits, `pip install --user`, R library installs, `.Rhistory` | Real home never mounted (default mode); a separate persistent session home at the same path |
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

The wrapper calls the runtime by absolute path (`AI_SINGBOX_RUNTIME`), never through
`module load` (the site runtime modulefiles fail when `HOSTNAME` is unset). Options go on the
command line only, never via `SINGULARITY_*`/`APPTAINER_*` variables. Running the host-root
container (§4) under a non-setuid runtime with `--userns` is not yet tested; until it is, the
fallbacks are documented, not supported.

The wrapper refuses to run anywhere but a compute or transfer node.

## 4. Host-root container: no image

The container root is a **skeleton directory** (`share/rootfs`, made by `libexec/make-rootfs`):
empty system mount points (`usr etc opt proc sys dev run tmp root var/...`) plus the host's
`bin -> usr/bin` style symlinks. Storage roots are deliberately *not* in the skeleton: the
runtime creates those that are bound, so a symlink into unmounted storage (`/dcl01/...`,
another lab's `/dcs04/<lab>`) is broken inside rather than pointing at an empty placeholder
folder, which a crawler would misreport as empty. Symlinks into mounted storage resolve as on
the host because every mount keeps its host path. The host's `/usr`, `/etc`, `/opt`, `/var/lib/sss` and `/var/lib/alternatives` are
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
| `read =` folders of the active profiles; site `default` profile includes site profile `libd`: `/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber` | host NFS exports | **ro** |
| any `--read PATH` | host | **ro**, at the path as typed |
| `$MYSCRATCH` | host | **rw** by default (`--no-scratch` to drop) |
| any `--write PATH` | host | **rw**, at the path as typed |
| `$HOME` | depends on `--home-mode` (§8) | synthetic rw / real ro / real rw |
| `/tmp`, `/var/tmp` | `$MYSCRATCH/ai-sandbox/work/{tmp,var_tmp}` | rw |
| `$XDG_CACHE_HOME` | `$MYSCRATCH/ai-sandbox/cache` | rw |
| everything else (skeleton) | `share/rootfs` | ro, empty |

`$MYSCRATCH` is writable because it is the user's own purge-able scratch space and the natural
staging area for intermediate results. Caches go there too (`XDG_CACHE_HOME`), so pip/R/agent
caches do not fill the home quota.

### 5.1 Mount rules (enforced by the wrapper at every launch)

1. **Automounts first.** Every source is looked up *inside* (`ls -d path/.`) before validation;
   `readlink` and `stat` do not trigger autofs. Then `/proc/mounts` is read once.
2. **A bind is recursive, but nested filesystems keep their own flags** (binding the autofs root
   `/dcs04` read-only left `/dcs04/lieber` writable, measured). Therefore:
   - a source that lies on an autofs map is refused (later automounts would arrive writable);
   - for read-only sources, every nested non-autofs mount is **rebound read-only** explicitly
     (e.g. `~/ceph_backup` FUSE in `--home-mode real-ro`); a nested autofs map is refused;
   - writable sources with anything mounted below them are refused (except the real home in
     `real-rw`, where nested mounts keep their host flags, as on the host).
3. The site system mounts file (`etc/mounts.tsv`: `/usr /etc /opt /var/lib/sss
   /var/lib/alternatives /jhpce/shared`) may only contain `ro` entries (`src dest mode
   required`). Data folders are not in it: they are `read =` lines in profiles (§9), so that a
   shared module carries no lab-specific storage in its system configuration.
4. A read-only mount nested inside a writable one is allowed only when it lands at the matching
   path inside it; otherwise the writable bind would expose the same data elsewhere.
5. Binds are ordered by destination depth so parents are mounted before children; duplicate
   destinations are dropped.
6. `--contain`, `--cleanenv`, `--no-mount cwd` always; `--home` or `--no-home` always explicit
   (under `--contain` with neither, the runtime mounts the real home read-write, measured). The
   container starts in the host's current directory when it is visible inside, else in `$HOME`.
7. `--dry-run` and `--print-binds` validate everything but create nothing.

## 6. Writable paths

`--write PATH` (repeatable) mounts an existing directory read-write at the path as typed (symlinks
are resolved for the source, not the destination, so `~/proj -> /dcs04/...` appears at `~/proj`).
The wrapper refuses a target that:

- does not exist (no runtime-created mount points on host storage; measured to happen otherwise),
- is `/`, or lies under `/usr /etc /opt /var /boot /proc /sys /dev /run /jhpce/shared`,
- is the real home or an ancestor of it (use `--home-mode real-rw` deliberately instead);
  directories *inside* the real home are allowed,
- equals a read-only mount source (`--write /dcs04/lieber`) or contains one at a different path,
- is the root of a whole filesystem (`--write /fastscratch/myscratch`, `--write /dcs04`),
- sits on an autofs map or has filesystems mounted below it.

Writable paths are printed at startup, recorded in the launch log, and exported inside as
`AI_SINGBOX_RW` (colon-separated).

## 7. Escape routes to unsandboxed writes

- `etc/deny-commands.txt` lists host binaries that would start processes outside the sandbox:
  `sbatch srun salloc scancel scontrol sbcast strigger scrontab ssh scp sftp slogin`. Each is
  masked by a read-only bind of `libexec/deny`, which prints a message and exits 126.
- `/run` is the skeleton's empty directory, so `/run/munge` is absent and no Slurm client can
  authenticate even if run from another path.
- No ssh keys in the synthetic home; setuid binaries (`sudo`, `su`, `ssh-keysign`) are inert
  because the container is mounted `nosuid`.
- The deny list is a convenience, not the barrier: other ssh clients are reachable inside
  (`conda_R/*/bin/ssh` is on `PATH` after `module load conda_R`; `paramiko` in the shared Python
  modules). The real barrier is that no login credential is visible inside (no `~/.ssh`, agent
  forwarding off): measured, an ssh from inside to another node fails with `Permission denied`.
  Nothing may put a passwordless login key inside the sandbox: `.ssh` is never seeded,
  in `--home-mode real-ro|real-rw` the real `~/.ssh` is masked by an empty read-only folder
  (`share/empty`), agent forwarding is off, and the planned `--sshd` mode uses a dedicated host key and
  refuses any key listed in `authorized_keys` (`docs/positron_remote_plan.md`).
- `rsync` stays available for local copies; remote rsync needs ssh and a key.
- In `--home-mode real-rw` the agent can edit dotfiles (`~/.bashrc`, `~/.ssh/authorized_keys`)
  that *host* sessions later execute. That is an escape route by delay; it is why `real-rw` is
  opt-in and announced with a warning.
- A controlled re-entry wrapper (`ai-singbox-sbatch`) is future work.

## 8. Home

### 8.1 Home modes (`--home-mode`, or `AI_SINGBOX_HOME_MODE`)

| Mode | `$HOME` inside | Use |
|---|---|---|
| `synthetic` (default) | separate sandbox home, rw | normal use; agent logins, history, configs persist without touching the real home |
| `real-ro` | real home, **read-only** (nested mounts rebound ro) | inspect with your own dotfiles, scripts and R libraries; tools that must write to `~` fail |
| `real-rw` | real home, **writable** | user accepts the risk; data normally is not in `$HOME`, but dotfiles are (§7) |

In `synthetic` mode, `--read ~/scripts` or `--write ~/proj` expose individual real-home
directories at their usual path inside the synthetic home.

### 8.2 Synthetic home

- Location: `~/.ai-singbox/home` (durable, backed-up home storage), overridable with
  `AI_SINGBOX_HOME` (e.g. a lab directory). Launch logs: `~/.ai-singbox/logs/`.
  Earlier versions used `$MYSCRATCH/ai-sandbox/home`, which fastscratch purging could delete;
  the wrapper points at it if found.
- The location is validated like a `--write` target (not the real home or its ancestor, not a
  system path, not a whole ro mount) and created on first launch.
- First launch: files from the user's skel directory (§9) are copied in without overwriting;
  then `.bashrc` (sources `/etc/bashrc`, `[sbx ...]` prompt, `EDITOR=nano`, commented
  `module load` example, header naming its host path), `.bash_profile`, `.config/`,
  `.local/bin/`, `R/` are created if still missing.
- **Customizing the session.** Every session is a login shell: the JHPCE site profile runs first
  (default modules), then `~/.bashrc`. Put `module load` lines, aliases and variables there. Edit
  from the host or inside (`nano ~/.bashrc`); apply in a running session with `source ~/.bashrc`.
  The wrapper never overwrites it. Avoid `set -u` before `module` commands.
- `--reset-home` archives the home as `home.<timestamp>`; the next launch rebuilds it from skel.
- The user's umask is inherited (files written into shared lab directories stay group-readable).
- **Personal libraries, read-only** (default on; `--no-personal-libs` or `personal_libs = no`).
  The real `~/R` is mounted read-only at `/host_home/R` and `~/.local/lib` at
  `/host_home/.local/lib`. R: `R_PROFILE_USER` points at `share/R/sandbox-Rprofile.R`, which runs
  after the site `Rprofile.site` (which creates and puts the writable sandbox library
  `~/R/<conda_R version>` first), inserts the matching real libraries
  (`/host_home/R/<version>`, `/host_home/R/<platform>-library/<x.y>`) right after it, then sources
  the synthetic `~/.Rprofile`. Python: for each `pythonX.Y/site-packages` in the real home, a
  `ai-singbox-host.pth` in the synthetic user site appends the real one. Result: installed
  packages load; `install.packages` and `pip install --user` write to the sandbox home.
- Agent configuration: see §10. `.ssh`, `.aws`, `.netrc`, `.git-credentials` are never copied.

## 9. Configuration layers

| Layer | Who | Location | Content |
|---|---|---|---|
| Site | module maintainers | `$AI_SINGBOX_ROOT/etc/` | `mounts.tsv` (system only), `deny-commands.txt`, `profiles/*.conf` incl. `default.conf` (data folders) |
| User | each user | `~/.config/ai-singbox/` (`AI_SINGBOX_CONFIG_DIR`) | `profiles/*.conf` (a user `default.conf` replaces the site one), `config`, `skel/` |
| Environment | user, per shell | `AI_SINGBOX_*` | home location and mode, runtime, rootfs |
| Command line | user, per run | options | `--profile`, `--write`, `--read`, `--home-dir`, `--module`, `--home-mode`, ... |

**User entry points**, documented first in the README: data folders (`read =`), writable
folders (`write =` / `--write`), and the session home (`home =`, whose `.bashrc` is the session
startup file). All three live in profiles. Without `--profile`, the profile `default` is applied
(user's copy if present, else the site's), so the standard storage is visible with no setup.
The site `default` only does `include = libd`; lab- or institute-specific storage lives in its own
profile (`libd`), so the tool carries no LIBD assumptions in code or system configuration.

Single values resolve in the order built-in, `config`, environment, profiles (in the order
given), command line; the last one wins. Lists (`module`, `read`, `write`) accumulate.

### 9.1 `config` and profiles

Both are `key = value` files, parsed and never sourced; unknown keys abort the launch.

| Key | `config` | profile | Meaning |
|---|---|---|---|
| `home_mode` | yes | yes | `synthetic`, `real-ro`, `real-rw` |
| `scratch` | yes | yes | `yes`/`no`: mount `$MYSCRATCH` writable |
| `personal_libs` | yes | yes | `yes`/`no` |
| `agent` | yes | yes | `shell`, `codex`, `claude` |
| `codex_seed`, `claude_seed` | yes | yes | settings source folder |
| `seed_credentials` | yes | yes | `yes`/`no` |
| `module` | yes | yes | module to load at session start (repeatable) |
| `read` | yes | yes | read-only path (repeatable) |
| `write` | **no** | yes | writable path (repeatable) |
| `description` | no | yes | shown by `--list-profiles` |
| `include` | no | yes | apply another profile first (repeatable; each profile once; depth ≤ 8) |
| `home` | yes | yes | session home folder; precedence `config` < `AI_SINGBOX_HOME` < profile < `--home-dir` |

A missing `read` folder from a profile or `config` is skipped with a warning (storage may be
absent on some nodes); a missing `write` folder stops the launch. Per-profile homes separate
`.bashrc`, agent logins and installed packages; homes under the real home or `$MYSCRATCH` are
created on first use, others must exist.

Values may use `~`, `$HOME`, `$USER`, `$MYSCRATCH`; nothing else is expanded. `write` is refused
in `config` so that nothing becomes writable without an explicit per-run choice (`--write` or
`--profile`). Every profile path goes through the same validation as the command line.
`--profile NAME` looks for `~/.config/ai-singbox/profiles/NAME.conf`, then the site
`etc/profiles/NAME.conf`. `--list-profiles` lists both. Launch logs record the profile files and
modules used.

Example `~/.config/ai-singbox/profiles/spatial.conf`:

```text
description = spatialDLPFC metadata survey
include = default
module = conda_R/4.5.x
read = /dcs05/lieber/marmaypag/spatialDLPFC_LIBD4035
write = /dcs04/lieber/lcolladotor/dbDev_LIBD001/agent_runs/spatial
```

Modules from `module`/`--module` are loaded after the login profile and before the command; an
interactive session then continues in an interactive shell that inherits them.

### 9.2 Candidate customizations (not implemented)

- **Carry host modules**: `--keep-modules` reloads `$LOADEDMODULES` inside.
- **Real-home dotfile pass-through** in synthetic mode: an allow-list (`.Rprofile`, `.gitconfig`,
  `.condarc`) copied or bound read-only into the synthetic home.
- **Site policy knobs**: forbid `real-rw`, cap `--write` to an allow-list of roots
  (e.g. `*/agent_outputs/*`), require a reason string recorded in the log.
- Per-project `AGENTS.md` injection.
- **`ai-singbox-sbatch`**: submit a job that re-enters the same sandbox with the same binds.

## 10. Agents

`--agent shell|codex|claude`. Arguments after `--` go to the agent
(`--agent codex -- login --device-auth`, `--agent claude -- -p "..."`).

### 10.1 Decoupled from the user's own agent setup

- **Own config folder per agent, per sandbox.** `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are always set:
  `~/.codex` and `~/.claude` of the synthetic home, or `~/.ai-singbox/agents/{codex,claude}`
  with `--home-mode real-ro|real-rw` (made writable in `real-ro`). With `CLAUDE_CONFIG_DIR` set,
  Claude Code keeps its `.claude.json` inside the folder (verified), so nothing lands in `$HOME`.
- **Separate login by default.** The user logs in once inside the sandbox; it persists with the
  durable home. The tokens are independent of the host logins, so no refresh-token sharing.
  Codex on a cluster node: `ai-singbox --agent codex -- login --device-auth`. Claude Code
  offers `/login` (URL + pasted code) on first start. The startup banner says when no login exists.
- The user's real `~/.codex`, `~/.claude`, `~/.claude.json` are never read unless named as a seed,
  and never written.

### 10.2 Seeding settings (`--codex-seed DIR`, `--claude-seed DIR`)

Done on the host by `libexec/agent-config` before the container starts. Copies an allow-list:

| Agent | Copied | Never copied |
|---|---|---|
| Codex | `config.toml`, `AGENTS.md`, `skills/` (minus agent-managed `.system/`), `prompts/`, `rules/` | sessions, history, SQLite state, logs, caches, memories |
| Claude | `settings.json`, `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `keybindings.json`, `output-styles/`; from `.claude.json` only `hasCompletedOnboarding`, `lastOnboardingVersion`, `theme` | projects, history, sessions, caches, every other `.claude.json` key |

- Existing files are kept; `--reseed` overwrites. An instructions file that holds only the sandbox
  notes block counts as empty, so a later seed still fills it.
- `--seed-credentials` adds `auth.json` / `.credentials.json` (mode 600) and the `oauthAccount`,
  `userID` keys of `.claude.json`. The banner warns that original and copy share one refresh token:
  if a provider rotates refresh tokens, whichever side refreshes first may log out the other.
- Config/profile keys: `codex_seed`, `claude_seed`, `seed_credentials`.

### 10.3 Sandbox notes

At every launch a marked block (`<!-- ai-singbox:begin ... end -->`) in the agent's global
instructions (`AGENTS.md` for Codex, `CLAUDE.md` for Claude) is regenerated: read-only storage,
the session's writable paths, Slurm/ssh disabled, use modules. Text outside the block is kept.

### 10.4 Agent CLIs and permissions

- CLIs are found on the user's `PATH` at launch (or `AI_SINGBOX_CODEX`, `AI_SINGBOX_CLAUDE`)
  and mounted read-only under `/.ai-singbox/agents/`, first on `PATH` inside. For Codex
  installed with npm, the native `vendor/<triple>/` folder (binary plus bundled ripgrep) is
  mounted, so no Node.js is needed. Claude Code must be the native binary. Auto-update is disabled
  inside (`DISABLE_AUTOUPDATER=1`); updating stays a host action.
- Codex's own command sandbox (bwrap) cannot nest in the container (`bwrap: Can't bind mount
  /oldroot/ on /newroot/`, measured), so Codex always starts with `--sandbox danger-full-access`;
  its approval prompts still apply. The container is the boundary.
- `--yolo` drops the agents' prompts: Codex `--dangerously-bypass-approvals-and-sandbox`, Claude
  `--dangerously-skip-permissions`. Writes remain limited to the writable paths.

## 11. Wrapper and module

```text
--write PATH        rw at the path as typed (repeatable)
--read PATH         ro at the path as typed (repeatable)
--no-scratch        do not mount $MYSCRATCH rw
--home-mode MODE    synthetic | real-ro | real-rw
--profile NAME      apply a profile (repeatable; default: 'default'); --list-profiles
--home-dir DIR      session home for this run
--module NAME       module to load at session start (repeatable)
--no-personal-libs  do not expose real ~/R and ~/.local/lib read-only
--cmd STRING        bash -lc STRING
-- CMD ARGS...      run CMD in a login environment
--agent NAME        shell | codex | claude  (agent args after --)
--yolo              agents without their own permission prompts
--codex-seed DIR    copy Codex settings into the sandbox's Codex folder
--claude-seed DIR   copy Claude Code settings likewise
--seed-credentials  also copy the logins
--reseed            overwrite previously seeded files
--reset-home        archive and recreate the synthetic home
--dry-run           print bind table and runtime command; creates nothing
--print-binds       print bind table
--quiet
```

Each launch writes `~/.ai-singbox/logs/<timestamp>-<pid>.json`: time, user, host, Slurm job
id, wrapper and runtime versions, host OS, rootfs, mounts files, home mode, writable paths, bind
table with notes, full command. Logs are a record, not tamper-proof evidence.

`modulefiles/ai-singbox/0.1.lua` (development) derives its root from its own location,
prepends `bin` to `PATH`, sets `AI_SINGBOX_ROOT` and `AI_SINGBOX_RUNTIME`, and guards
against an unset `HOSTNAME`.

## 12. Open questions

- Which lab exports beyond `*/lieber` belong in the default site mounts file?
- Which of §9.2 to implement before sharing the module?
- Validate the host-root container under SingularityCE 4.5.1 `--userns` as a fallback.
- Agent CLIs from per-user installs work; should the shared module also ship site-installed
  copies under `/jhpce/shared/libd` (set via `AI_SINGBOX_CODEX/_CLAUDE` in the modulefile)?
