# libd-ai-sandbox

Run an AI agent (Codex, Claude Code) or a plain shell on JHPCE so that it **cannot
create, change or delete anything on LIBD/JHPCE storage** except in folders you name
for that run. It keeps your full *read* access, at the usual paths, with the usual
JHPCE modules.

Your account can usually write to many lab folders. Inside the sandbox the agent
cannot: the storage is mounted read-only by the kernel, so `rm`, `sed -i`, or a
script that writes next to its inputs fails with `Read-only file system`.

This protects data against accidents. It does not stop an agent from reading files
and sending their content to its AI service; that is governed by policy, not by this
tool.

## Contents

- [Quick start](#quick-start)
- [What is read-only, what is writable](#what-is-read-only-what-is-writable)
- [Writing into a folder inside read-only storage](#writing-into-a-folder-inside-read-only-storage)
- [Example: an agent that inventories R objects in a lab folder](#example-an-agent-that-inventories-r-objects-in-a-lab-folder)
- [Agents: login, settings, permissions](#agents-login-settings-permissions)
- [Your sandbox home and session setup](#your-sandbox-home-and-session-setup)
- [Profiles and defaults](#profiles-and-defaults)
- [Option reference](#option-reference)
- [Troubleshooting](#troubleshooting)
- [Planned: sandboxed Positron / VS Code sessions](#planned-sandboxed-positron--vs-code-sessions)
- [Reference](#reference)

## Quick start

The sandbox runs on a compute or transfer node, inside your Slurm allocation:

```bash
srun --pty -p shared --mem=16G -c 4 -t 8:00:00 bash
module use /dcs04/lieber/lcolladotor/dbDev_LIBD001/jhpce-singbox/modulefiles   # until installed site-wide
module load libd_ai_sandbox/0.1

libd-ai-sandbox --dry-run          # show what would be mounted, start nothing
libd-ai-sandbox                    # a shell inside the sandbox
```

At start it prints the writable locations. Try:

```bash
touch /dcs04/lieber/<lab>/x        # Read-only file system
module load conda_R/4.5.x          # modules work as usual
exit
```

## What is read-only, what is writable

| Inside the sandbox | Mode |
|---|---|
| `/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber` | read-only |
| `/jhpce/shared` (modules, shared software) | read-only |
| `/usr`, `/etc`, `/opt` (the node's own system) | read-only |
| `$MYSCRATCH` (`/fastscratch/myscratch/$USER`) | **writable** (`--no-scratch` to turn off) |
| `$HOME` | **writable**, but it is a separate sandbox home, not your real home ([details](#your-sandbox-home-and-session-setup)) |
| `/tmp` | **writable**, backed by `$MYSCRATCH/ai-sandbox/work/tmp` |
| each `--write PATH` | **writable** |
| each `--read PATH` | read-only |

Everything keeps its host path, so `/dcs04/lieber/marmaypag/...` is the same path
inside and outside. Paths not listed (other storage, your real home) are not visible.

**Symlinks** work as on the host when their target is mounted: a link from a
`/dcs04/lieber` project to `/dcs05/lieber/...` or to `../rds/x.rds` resolves normally.
A link into storage that is not mounted (another lab's `/dcs04/<lab>`, `/dcl01`, ...)
is a broken link inside, never an empty folder; add `--read <target>` if the agent
needs it.

Also disabled inside: `sbatch`, `srun`, `salloc`, `scancel`, `scontrol`, `ssh`, `scp`,
`sftp`. They could start work outside the sandbox. Local `rsync` and `cp` work.

**Keep login keys out of the sandbox.** What really stops an agent from leaving the
sandbox over ssh is that no login key is visible inside (your real `~/.ssh` is not
mounted). Other ssh clients do exist inside, for example the one in `conda_R`. Do not
copy `~/.ssh` into the sandbox home, do not `--read` it, and do not forward your ssh
agent into a sandboxed session: any passwordless key there lets a process log in to
another node with your full write access.

## Writing into a folder inside read-only storage

Yes: `--write` makes one existing folder writable, at its own path, while everything
around it stays read-only.

```bash
mkdir -p /dcs04/lieber/marmaypag/data-inventory        # on the host, once
libd-ai-sandbox --write /dcs04/lieber/marmaypag/data-inventory
```

Inside, `/dcs04/lieber/marmaypag/data-inventory` is writable; its parent
`/dcs04/lieber/marmaypag` and every sibling folder are not. `--write` can be given
several times.

The wrapper refuses targets that would undo the protection, and says why:

| Refused | Why |
|---|---|
| a folder that does not exist yet | create it yourself first, so a typo never creates folders on lab storage |
| `/dcs04/lieber`, `/dcs04`, `/fastscratch/myscratch` | a whole filesystem or storage root |
| your real home, `/`, `/usr`, `/etc`, `/jhpce/shared`, ... | system or shared software |
| a folder with another filesystem mounted inside it | the inner filesystem would not follow the rule |

Check before running with `--dry-run`: writable lines start with `rw`.

## Example: an agent that inventories R objects in a lab folder

Goal: let an agent walk every project under `/dcs04/lieber/marmaypag`, open the R
objects (`.rds`, `.RData`, HDF5-backed SummarizedExperiments) and write a table and a
summary into `/dcs04/lieber/marmaypag/data-inventory`, with no way to change the data.

`/dcs04/lieber` is already read-only by default, so the lab folder needs nothing extra;
only the output folder is opened for writing.

**1. Create the output folder and a profile** (once, on the host):

```bash
mkdir -p /dcs04/lieber/marmaypag/data-inventory
mkdir -p ~/.config/libd-ai-sandbox/profiles
cp $LIBD_AI_SANDBOX_ROOT/examples/profiles/marmaypag-inventory.conf ~/.config/libd-ai-sandbox/profiles/
```

The profile ([examples/profiles/marmaypag-inventory.conf](examples/profiles/marmaypag-inventory.conf)):

```text
description = R-object inventory of /dcs04/lieber/marmaypag
module = conda_R/4.5.x
write = /dcs04/lieber/marmaypag/data-inventory
```

**2. Get a node with enough memory.** R loads a whole `.rds` into memory to inspect it,
and Slurm is not available from inside the sandbox, so size the allocation for the
largest objects you want opened:

```bash
srun --pty -p shared --mem=64G -c 8 -t 2-00:00:00 bash
module use /dcs04/lieber/lcolladotor/dbDev_LIBD001/jhpce-singbox/modulefiles
module load libd_ai_sandbox/0.1
```

**3. Check, then start the agent** from the lab folder (the agent starts in the folder
you launch from):

```bash
cd /dcs04/lieber/marmaypag
libd-ai-sandbox --profile marmaypag-inventory --agent claude --dry-run
libd-ai-sandbox --profile marmaypag-inventory --agent claude --claude-seed ~/.claude
```

The first time, log in when the agent asks (see [Agents](#agents-login-settings-permissions)).
`--claude-seed ~/.claude` brings your Claude settings in; it is needed only once.

**4. Give it the task.** A ready-made prompt is in
[examples/prompts/r-object-inventory.md](examples/prompts/r-object-inventory.md): it
asks for a file list first, one R process per object with a timeout and a size limit,
resumable output (`objects.jsonl`, `objects.tsv`, `SUMMARY.md`) and its scripts saved
under `data-inventory/scripts/`. Paste it, or tell the agent:
`Read $LIBD_AI_SANDBOX_ROOT/examples/prompts/r-object-inventory.md and do it.`

**Unattended runs.** By default the agent asks before running commands. To let it run
without asking, add `--yolo`. The sandbox still blocks every write outside
`data-inventory`, `$MYSCRATCH`, the sandbox home and `/tmp`. Note that inside
`data-inventory` the agent can delete or overwrite its own earlier output.

With Codex instead: replace `--agent claude --claude-seed ~/.claude` with
`--agent codex --codex-seed ~/.codex`.

## Agents: login, settings, permissions

**Logging in.** The sandbox has its own agent logins, separate from the ones on your
host account; you log in once and it is remembered.

```bash
libd-ai-sandbox --agent codex -- login --device-auth    # Codex: prints a code to enter in a browser
libd-ai-sandbox --agent claude                          # Claude Code: offers /login on start
```

**Bringing your settings.** `--codex-seed ~/.codex` and `--claude-seed ~/.claude` copy
your settings and instructions (Codex: `config.toml`, `AGENTS.md`, skills; Claude:
`settings.json`, `CLAUDE.md`, commands, agents, skills) into the sandbox's agent
folders. History, sessions and logins are not copied. Files already there are kept;
`--reseed` overwrites them.

`--seed-credentials` copies the login too, so you skip logging in. The copy and your
host login then share one refresh token; if the provider rotates it, one of them may be
logged out. Logging in separately avoids that.

**What the agent is told.** Each launch writes a short block into the agent's global
instructions (`AGENTS.md` / `CLAUDE.md` in the sandbox) listing the writable folders and
saying that storage is read-only and Slurm/ssh are off. Your own text there is kept.

**Permissions.** Without `--yolo` the agents ask before acting, as usual (Codex's own
command sandbox cannot run inside the container and is off; the container replaces it).
With `--yolo` they do not ask.

**Passing arguments.** Everything after `--` goes to the agent:

```bash
libd-ai-sandbox --agent claude -- -p "summarize the README in this folder"
libd-ai-sandbox --agent codex -- exec "list the largest .rds files here"
```

The agent programs are taken from your `PATH` (`codex`, `claude`) and mounted read-only;
updates happen outside the sandbox.

## Your sandbox home and session setup

Inside, `$HOME` has your normal path (`/users/$USER`) but is a separate folder,
`~/.libd-ai-sandbox/home` on the host. It persists between sessions. Your real home
is not visible, so the agent cannot change your dotfiles, ssh keys or R setup.

**Session setup.** Each session runs the JHPCE login profile (default modules), then
the sandbox's `~/.bashrc`. Put `module load` lines, aliases and variables there:

```bash
nano ~/.libd-ai-sandbox/home/.bashrc      # from the host
nano ~/.bashrc                            # or from inside; then: source ~/.bashrc
```

To keep a template that survives `--reset-home`, put files in
`~/.config/libd-ai-sandbox/skel/` (for example `skel/.bashrc`); they are copied into the
sandbox home whenever missing there.

**Your installed R and Python packages** work inside: your real `~/R` and
`~/.local/lib` are mounted read-only and added after the sandbox's own libraries.
`install.packages()` and `pip install --user` install into the sandbox home.
`--no-personal-libs` turns this off.

**Real home instead.** `--home-mode real-ro` uses your real home read-only.
`--home-mode real-rw` makes it writable; the agent could then change files such as
`~/.bashrc` that your normal logins run, so use it only if you accept that. In both
modes `~/.ssh` appears empty inside, so your login keys stay out of reach.

## Profiles and defaults

A profile is a saved set of options for a kind of work, used with `--profile NAME`.
Files: `~/.config/libd-ai-sandbox/profiles/NAME.conf` (yours) or the module's
`etc/profiles/NAME.conf` (shared). `libd-ai-sandbox --list-profiles` lists them.

```text
description = spatial DLPFC metadata survey
module = conda_R/4.5.x
read = /dcs05/lieber/<lab>/<other-project>
write = /dcs04/lieber/<lab>/agent_outputs/spatial
home_mode = synthetic
codex_seed = ~/.codex
```

Keys: `description`, `module`, `read`, `write`, `home_mode`, `scratch`,
`personal_libs`, `agent`, `codex_seed`, `claude_seed`, `seed_credentials`. `module`,
`read` and `write` can repeat. Values may use `~`, `$HOME`, `$USER`, `$MYSCRATCH`.

`~/.config/libd-ai-sandbox/config` holds your defaults with the same keys, except
`write`: writable folders always come from a profile or the command line for that run.
Command-line options win over profiles, which win over the defaults.

Extra read-only storage for every session can be listed in
`~/.config/libd-ai-sandbox/mounts.tsv` (same format as the module's `etc/mounts.tsv`).

## Option reference

`libd-ai-sandbox --help` prints the same list with your actual paths.

### Command-line options

| Option | Effect |
|---|---|
| `--write PATH` | make an existing folder writable at its own path (repeatable). Refused: missing folders, whole filesystems or storage roots, system paths, `/jhpce/shared`, your real home or its parents, folders with other filesystems mounted inside |
| `--read PATH` | make a folder visible read-only at its own path (repeatable) |
| `--no-scratch` | do not make `$MYSCRATCH` writable (sandbox home, `/tmp` and cache stay writable) |
| `--profile NAME` | apply `profiles/NAME.conf` (repeatable, applied in order) |
| `--list-profiles` | list user and site profiles with their descriptions |
| `--module NAME` | load a module at session start, after the JHPCE defaults (repeatable) |
| `--no-personal-libs` / `--personal-libs` | hide / show your real `~/R` and `~/.local/lib` read-only (synthetic home only; default shown) |
| `--home-mode synthetic` | default: `$HOME` is the separate sandbox home |
| `--home-mode real-ro` | `$HOME` is your real home, read-only; `~/.ssh` appears empty |
| `--home-mode real-rw` | `$HOME` is your real home, writable (the agent can change your dotfiles); `~/.ssh` appears empty |
| `--cmd 'COMMAND'` | run one shell command (login shell) instead of an interactive shell |
| `-- CMD ARGS...` | run a program; with `--agent`, pass arguments to the agent |
| `--agent shell\|codex\|claude` | what to start (default `shell`) |
| `--yolo` | start the agent without its own permission prompts |
| `--codex-seed DIR` / `--claude-seed DIR` | copy agent settings from `DIR` into the sandbox's agent folder |
| `--seed-credentials` | also copy the agent logins (shared refresh token) |
| `--reseed` | overwrite previously seeded files |
| `--reset-home` | archive the sandbox home as `home.<timestamp>` and start fresh |
| `--dry-run` | check everything, print the mount table and the command, start nothing, create nothing |
| `--print-binds` | print the mount table only |
| `--quiet`, `-q` | no startup banner or warnings |
| `--version`, `--help` | |

### Files

| Location | Purpose |
|---|---|
| `~/.config/libd-ai-sandbox/config` | your defaults (`key = value`) |
| `~/.config/libd-ai-sandbox/profiles/NAME.conf` | your profiles |
| `~/.config/libd-ai-sandbox/mounts.tsv` | extra read-only mounts for every session (`src dest ro yes\|no`) |
| `~/.config/libd-ai-sandbox/skel/` | template files copied into the sandbox home when missing |
| `~/.libd-ai-sandbox/home/` | the sandbox home (`$HOME` inside) |
| `~/.libd-ai-sandbox/logs/` | one JSON record per launch |
| `~/.libd-ai-sandbox/agents/` | agent config folders when a real home is used |
| `$MYSCRATCH/ai-sandbox/work/`, `.../cache/` | `/tmp` and caches |
| `<module>/etc/mounts.tsv`, `etc/deny-commands.txt`, `etc/profiles/` | site settings |

### Keys in `config` and profiles

| Key | Values | In `config` | In profiles |
|---|---|---|---|
| `description` | text | no | yes |
| `module` | module name (repeatable) | yes | yes |
| `read` | absolute path (repeatable) | yes | yes |
| `write` | absolute path (repeatable) | **no** | yes |
| `home_mode` | `synthetic`, `real-ro`, `real-rw` | yes | yes |
| `scratch` | `yes`, `no` | yes | yes |
| `personal_libs` | `yes`, `no` | yes | yes |
| `agent` | `shell`, `codex`, `claude` | yes | yes |
| `codex_seed`, `claude_seed` | folder | yes | yes |
| `seed_credentials` | `yes`, `no` | yes | yes |

Values may use `~`, `$HOME`, `$USER`, `$MYSCRATCH`. Precedence for single values:
`config` < environment < profiles < command line. `module`, `read`, `write` add up.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LIBD_AI_SANDBOX_HOME` | `~/.libd-ai-sandbox/home` | sandbox home location |
| `LIBD_AI_SANDBOX_HOME_MODE` | `synthetic` | default `--home-mode` |
| `LIBD_AI_SANDBOX_STATE` | `~/.libd-ai-sandbox` | home, logs, agent folders |
| `LIBD_AI_SANDBOX_CONFIG_DIR` | `~/.config/libd-ai-sandbox` | your configuration folder |
| `LIBD_AI_SANDBOX_MOUNTS` | `<module>/etc/mounts.tsv` | site read-only mounts |
| `LIBD_AI_SANDBOX_MOUNTS_EXTRA` | none | one more mounts file |
| `LIBD_AI_SANDBOX_DENY` | `<module>/etc/deny-commands.txt` | host commands masked inside |
| `LIBD_AI_SANDBOX_CODEX`, `LIBD_AI_SANDBOX_CLAUDE` | `codex`/`claude` on `PATH` | agent programs to mount |
| `LIBD_AI_SANDBOX_RUNTIME` | SingularityCE 3.11.4 | container runtime binary |
| `LIBD_AI_SANDBOX_ROOTFS` | `<module>/share/rootfs` | container root skeleton |
| `LIBD_AI_SANDBOX_ROOT` | the module folder | install root |
| `LIBD_AI_SANDBOX_ANY_HOST` | unset | skip the node check (testing only) |

Inside the sandbox: `LIBD_AI_SANDBOX` (version), `LIBD_AI_SANDBOX_RW` (writable paths,
colon-separated), `LIBD_AI_SANDBOX_HOME_MODE`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`,
`XDG_CACHE_HOME`.

## Troubleshooting

| Message or symptom | Meaning |
|---|---|
| `run this on a compute or transfer node` | start an `srun --pty ... bash` session first |
| `--write path must be an existing directory` | `mkdir -p` it on the host, then retry |
| `refusing --write ...: it is a whole read-only mount` | pick a folder inside it |
| `... is an autofs map` | name the lab folder (`/dcs04/lieber`), not the storage root (`/dcs04`) |
| a path or symlink target is missing inside | it is outside the mounted storage; add `--read PATH` (or a line in `~/.config/libd-ai-sandbox/mounts.tsv`) |
| `sbatch is disabled inside the sandbox` | by design; run jobs from outside |
| `module: command not found` in a script | run it with `bash -l`, or via `--cmd` |
| R or the agent killed for memory | ask `srun` for more `--mem` |

## Planned: sandboxed Positron / VS Code sessions

Not implemented yet; design in [docs/positron_remote_plan.md](docs/positron_remote_plan.md).
A shipped sbatch template will run the remote `sshd` inside the sandbox, so Positron, its
terminals, R and the Posit Assistant all work under the same rules, with the writable
folders chosen in the script.

What to expect on your laptop:

- **Logins** keep working without prompts: your existing keys are accepted as today.
- **Host key.** The sandboxed sshd has its own host key, created once and kept in
  `~/.libd-ai-sandbox/sshd/`. It is not your `~/.ssh/id_rsa`: that key logs in to every
  JHPCE node, and an sshd host key is readable by everything inside the sandbox.
- **Why an alias is needed.** `known_hosts` stores keys per host *and* port. Each job
  lands on a different node and port, so even a stable key would look new every time,
  and Positron cannot answer a host-key prompt. Add to the ssh host entry you use for
  these sessions:

  ```text
  HostKeyAlias libd-ai-sandbox-<user>
  ```

  Then run one manual `ssh` to the first sandboxed session to accept the key. Every later
  job, on any node and port, matches without a prompt.
- **Keep sandboxed and unsandboxed entries apart.** Your current script uses `id_rsa` as
  the host key. Use a separate ssh host entry (with the alias) for sandboxed sessions,
  otherwise the two keys collide under one name.
- **If the sandbox host key changes** (deleted, regenerated), ssh refuses with
  `REMOTE HOST IDENTIFICATION HAS CHANGED`. Remove the old entry once:
  `ssh-keygen -R libd-ai-sandbox-<user>`, then connect manually again.
- If your ssh entry already disables host-key checking for compute nodes
  (`StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null`), nothing changes, at the
  cost of not detecting a wrong host.
- Positron installs a fresh server into the sandbox home (about 0.8 GB), separate from
  the one in your real home. Folders you edit in Positron must be writable in that job.

## Reference

- [docs/design.md](docs/design.md): how it works and why (mount rules, configuration
  layers, agents)
- [docs/runtime_findings.md](docs/runtime_findings.md): measured behaviour on JHPCE
- [docs/implementation_plan.md](docs/implementation_plan.md): status
- `tests/test_wrapper.sh`: the checks that back the claims above (run it after changes,
  on a transfer node and a compute node)
