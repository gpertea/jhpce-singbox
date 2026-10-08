# Plan: sandboxed Positron / VS Code remote sessions (draft, 2026-10-07)

Status: **feasibility verified, not implemented.** Decisions after review are listed below.

## Today

`~/bin/get_vscode_session.sh` (sbatch, 4 CPUs, 48 GB, 6 h) picks a free port, stores it in the
job comment, and runs a user-level `sshd -D -p PORT -f /dev/null -h ~/.ssh/id_rsa` on the compute
node. Positron connects through a tunnel, installs its server under `~/.positron-server`
(807 MB today), and everything it starts (R, terminals, extensions, the Posit Assistant) runs
with the user's full write access.

## Idea

Run that `sshd` *inside* libd-ai-sandbox. Every ssh session is then a child of a process inside
the container, so the Positron server, its terminals, R sessions and the AI assistant all see
read-only storage, the synthetic home, and only the configured writable folders. Which folders
are writable becomes a per-job choice (profile or `--write` in the sbatch script).

## Verified on transfer-01 (SCE 3.11.4, OpenSSH 8.7p1)

A throwaway sshd (own host key, throwaway client key, localhost only) inside the sandbox:

| Check | Result |
|---|---|
| non-root `sshd -D` inside the container, publickey login | works |
| session `$HOME` | synthetic home |
| write to `/dcs04/lieber/...` from the session | `Read-only file system` |
| `module load conda_R/4.5.x`, `/host_home`, sbatch denied, no munge | same as normal sandbox |
| script piped to `bash` over ssh (how VS Code/Positron bootstrap) | runs inside |
| `ssh -L` forward to a server started inside the session | works (same network namespace) |
| container `--env` variables in ssh sessions | **lost** (sshd builds a fresh environment) |
| `SetEnv` in sshd_config, and a `ForceCommand` script | both applied |
| processes left running after the container exits | survive without `--pid`; none with `--pid` |

## Design

### Wrapper: `--sshd PORT` mode

`libd-ai-sandbox [usual options] --sshd PORT` runs `/usr/sbin/sshd -D -e -f <generated config>`
as the container command, with `--pid` so that ending the job (or sshd) ends every session.

Generated per launch under `~/.libd-ai-sandbox/sshd/` (host side, before start):

- `ssh_host_ed25519_key`: created once, kept (default). `--sshd-host-key FILE` overrides; see
  the decisions below about `~/.ssh/id_rsa`.
- `authorized_keys`: copied from the real `~/.ssh/authorized_keys` at each launch (public keys
  only; the real `~/.ssh` is never mounted). Optional `--sshd-authorized-keys FILE`.
- `sshd_config`:

  ```text
  Port PORT
  HostKey ~/.libd-ai-sandbox/sshd/ssh_host_ed25519_key
  AuthorizedKeysFile ~/.libd-ai-sandbox/sshd/authorized_keys
  PidFile ~/.libd-ai-sandbox/sshd/sshd.pid
  StrictModes no
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  AllowTcpForwarding local
  AllowAgentForwarding no
  X11Forwarding no
  SetEnv LIBD_AI_SANDBOX=... LIBD_AI_SANDBOX_RW=... CODEX_HOME=... CLAUDE_CONFIG_DIR=...
         XDG_CACHE_HOME=... R_PROFILE_USER=... DISABLE_AUTOUPDATER=1
  ForceCommand /.libd-ai-sandbox/ssh-session
  Subsystem sftp internal-sftp
  ```

- `ssh-session` (mounted read-only in the container): adds the agent CLI folders to `PATH`,
  loads the profile's modules, then `exec bash -lc "$SSH_ORIGINAL_COMMAND"` or `exec bash -l`.
  `ForceCommand` also covers sftp (`internal-sftp` runs in-process, inside the container).

Notes:

- `AllowAgentForwarding no` keeps the laptop's ssh agent out of reach of the sandbox: with it,
  code inside could use the user's keys to ssh to another node and escape the sandbox.
- `AllowTcpForwarding local`: Positron needs local forwards to its server; remote forwards are
  not needed.
- The sshd listens on all interfaces like today (the tunnel arrives via the node's address); only
  the user's own keys are accepted.
- `UsePAM` cannot work for a non-root sshd; it logs a harmless warning on RHEL.

### sbatch template: `bin/libd-ai-positron-session` (or an example script)

Same shape as the current script, with sandbox options at the top:

```bash
#!/bin/bash
#SBATCH --job-name=positron-sbx
#SBATCH --output=positron-sbx-%j.log
#SBATCH --time=06:00:00
#SBATCH -c 4
#SBATCH --mem=48G

SANDBOX_OPTS=(--profile marmaypag-inventory)     # or: --write /dcs04/lieber/<lab>/<project>

module use /path/to/libd_ai_sandbox/modulefiles
module load libd_ai_sandbox
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
scontrol update JobId="$SLURM_JOB_ID" Comment="$PORT"
exec libd-ai-sandbox "${SANDBOX_OPTS[@]}" --sshd "$PORT"
```

The `scontrol` call runs on the host, before the container; inside, Slurm is unavailable.

### Positron side

- No client change beyond accepting a new host key (the sandbox's own) the first time.
- The Positron server is installed fresh into the synthetic home
  (`~/.libd-ai-sandbox/home/.positron-server`, ~0.8 GB, durable home storage). Extensions and
  settings installed in sandboxed sessions stay separate from unsandboxed ones.
- Editing project files in Positron is subject to the same rules: folders you edit must be
  `--write` targets (or in a profile). This is the point, but users should expect it.

## Decisions and findings (2026-10-07, after review)

- **Shipped command/template.** `bin/libd-ai-positron-session` is an sbatch script the user copies
  and adapts (resources, profile or `--write` folders). `--sshd` stays a wrapper option.
- **Host key: dedicated, decided.** The sandbox sshd uses its own host key, generated once
  (`ssh-keygen -t ed25519`, no passphrase) at `~/.libd-ai-sandbox/sshd/ssh_host_ed25519_key` and
  kept. It is used for nothing else, so being readable inside the sandbox is harmless.
  `--sshd-host-key FILE` may point at another dedicated key, but the wrapper **refuses** a key
  whose public half is listed in `~/.ssh/authorized_keys`. Reason (measured): such a key is a
  passwordless login to every JHPCE node (`ssh -i ~/.ssh/id_rsa transfer-01` logs in without a
  prompt), an sshd host key must be readable by every process in the sandbox, and ssh clients
  exist inside despite the deny list (`conda_R/*/bin/ssh` on `PATH` after `module load
  conda_R`; `paramiko` in the shared Python modules). Today an ssh from inside fails only
  because no key is visible (`Permission denied (publickey,...)`); the user's `~/.ssh/id_rsa`
  as host key would undo that.
- **No prompts on the client.** Positron expects a connection without prompts. Logins already
  use the user's keys. For the host key, the laptop's `known_hosts` is keyed by host *and* port,
  and both change with every job, so a stable key alone is not enough. Add one line to the
  laptop's ssh host entry used for these sessions:

  ```text
  HostKeyAlias libd-ai-sandbox-<user>
  ```

  Then one manual `ssh` to the first sandboxed session records the key under that alias, and
  every later job (any node, any port) matches it without a prompt. Setups that already skip
  host-key checking for compute nodes need no change.
- **`--pid` is not needed for the sbatch session.** A PID namespace gives the container its own
  process tree; when its first process exits, the kernel ends every other process in it. In a
  Slurm job, ending the job already kills all of its processes, so the template does not need
  it. It only matters for interactive sandbox runs inside a longer allocation (leftover
  background processes keep running, still confined, until the allocation ends). Left as a
  possible `--pid` option, not a default.
- `AllowAgentForwarding no` stays: a forwarded laptop agent is the same escape as a visible key.

## Open questions

- Copy all of `~/.ssh/authorized_keys`, or only keys marked for the sandbox
  (e.g. `~/.config/libd-ai-sandbox/authorized_keys`)?
- Does the Posit Assistant need anything beyond network access from the node? To verify in a
  real session.

## Tests to add with the implementation

Start `--sshd` on a free localhost port with a throwaway client key, then over ssh: synthetic
home, ro write fails, `$LIBD_AI_SANDBOX_RW` present (SetEnv), modules from the profile loaded,
agent CLIs on `PATH`, sbatch denied, local forward works, agent forwarding refused, and no
process left after the sandbox is stopped. Refusals: `--sshd-host-key` pointing at a key listed
in `authorized_keys`; `--sshd` without a port. The host key is created once and reused (same
fingerprint across launches).
