# Plan: sandboxed Positron / VS Code remote sessions (draft, 2026-10-07)

Status: **feasibility verified, not implemented.**

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

- `ssh_host_ed25519_key`: created once, kept. A dedicated host key; the user's own private
  key is never used as a host key.
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

## Open questions

- Should `--pid` become the default for every sandbox session, not just `--sshd`? It makes
  background processes started by an agent end with the session.
- Copy all of `~/.ssh/authorized_keys`, or only keys marked for the sandbox
  (e.g. a separate `~/.config/libd-ai-sandbox/authorized_keys`)?
- Ship the sbatch script as a command (`libd-ai-positron-session`) or as an example to copy?
- Does the Posit Assistant need anything beyond network access from the node? To verify in a
  real session.

## Tests to add with the implementation

Start `--sshd` on a free localhost port with a throwaway client key, then over ssh: synthetic
home, ro write fails, `$LIBD_AI_SANDBOX_RW` present (SetEnv), modules from the profile loaded,
agent CLIs on `PATH`, sbatch denied, local forward works, agent forwarding refused, and no
process left after the sandbox is stopped.
