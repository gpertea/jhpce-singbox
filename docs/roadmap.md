# Roadmap: from development copy to a shared JHPCE module

Status 2026-10-07: the wrapper works from this repository for its author (`module use
<repo>/modulefiles`). It is already decoupled from any one account: it locates its own files
relative to its install location, takes each user's home from `getent`, keeps per-user state in
`~/.libd-ai-sandbox` and `~/.config/libd-ai-sandbox`, and relies on `$MYSCRATCH`, which the JHPCE
default environment module (`JHPCE_ROCKY9_DEFAULT_ENV`) sets for every user.

What remains is packaging, a more generic agent model, and validation by other users.
Order below is the suggested order of work.

## 1. Agents as software you load, not something the wrapper mounts

Today `--agent codex|claude` finds the CLI on the user's host `PATH` and mounts it read-only into
the container. That ties the sandbox to per-user installs and to two hard-coded agents. The
generic model:

**The sandbox is a normal JHPCE environment, so agents come from where all software comes from.**
`/jhpce/shared` is mounted and Lmod works inside, so an agent installed as a module is available
with `module load` from the sandbox's `~/.bashrc`, a profile (`module = codex/0.161.0`), or by hand
inside the session. Two sources, both generic:

1. **Agent modules** maintained like other LIBD software:
   `/jhpce/shared/libd/core/{codex,claude_code,...}/<version>` with modulefiles in
   `jhpce_module_config`. Usable inside and outside the sandbox. npm-based agents can depend on
   the existing `node` module. Trade-off: agents release weekly; someone has to keep modules
   current.
2. **Installs in the persistent sandbox home.** The synthetic home is durable and writable, so a
   user can install any agent there once, from inside the sandbox
   (`npm install -g --prefix ~/.local @openai/codex`, the Claude Code native installer into
   `~/.local`, `pip install --user ...`). `~/.local/bin` is on `PATH` through the site profile.
   The agent can then update itself inside the home. Isolated from the user's host installs.

Wrapper changes:

- `--agent NAME` runs `NAME` *inside* the container after the login profile and module loads; the
  wrapper no longer needs to find or mount the binary. Mounting from the host `PATH` stays as an
  explicit fallback (`--agent-from-host`), the current behaviour.
- Drop `DISABLE_AUTOUPDATER=1` for agents not mounted from the host (home installs must be able to
  update); keep it for host-mounted ones.
- **Per-agent descriptors** instead of code: `etc/agents/<name>.conf` (site) and
  `~/.config/libd-ai-sandbox/agents/<name>.conf` (user), parsed like profiles:

  ```text
  command = codex
  config_env = CODEX_HOME            # env var pointing at the agent's config folder
  config_dir = .codex                # folder name in the sandbox home
  notes_file = AGENTS.md             # where the sandbox notes block goes
  default_args = --sandbox danger-full-access
  yolo_args = --dangerously-bypass-approvals-and-sandbox
  seed = config.toml AGENTS.md skills prompts rules
  seed_credentials = auth.json
  module = codex                     # optional: module to load for this agent
  ```

  Codex and Claude Code ship as descriptors; others (Hermes, pi, Gemini CLI, opencode, ...) are
  added by writing a descriptor, no wrapper change. An agent with no descriptor still runs
  (`--agent NAME` = plain command), just without seeding, notes or yolo mapping.
- Tests: a fake agent descriptor + script exercising config env, notes block, seed allow-list.

## 2. Install layout, permissions, versioning

- Install path: `/jhpce/shared/libd/core/libd_ai_sandbox/<version>/`, group `lieber_modules`,
  readable by everyone (`a+rX`). The development repository is `0770` with group
  `lieber_lcolladotor`, and `etc/*.tsv|txt` are `0660`: not readable by other users as is.
- `libexec/install <prefix>`: copy tracked files (`git archive` of a tag), run `libexec/make-rootfs`
  into `<prefix>/share/rootfs`, `chmod -R a+rX,go-w`, write `<prefix>/VERSION`. Refuse to install
  over an existing version.
- One version number: wrapper `VERSION`, git tag `v<version>`, modulefile name `<version>.lua`
  (today the modulefile is `0.1` and the wrapper `0.4.0-dev`). Keep `CHANGELOG.md`.
- The skeleton root (`share/rootfs`) and the wrapper's `ROOT` are on `/jhpce/shared`, already
  visible on every node; nothing else needs deploying per node.
- Lab-specific storage lives only in `etc/profiles/default.conf` (`read = /dcs04/lieber`, ...);
  `etc/mounts.tsv` holds system mounts only. A deployment for another group changes the default
  profile, nothing else. Users override it with their own `profiles/default.conf`.

## 3. Production modulefile (`jhpce_module_config`)

- `libd_ai_sandbox/<version>.lua` with `local root = "/jhpce/shared/libd/core/libd_ai_sandbox/<version>"`
  (the development modulefile derives `root` from its own path, which does not hold when
  modulefiles live in a separate tree).
- Same conventions as other LIBD modules: `help`, `whatis`, `LmodMessage` on load/unload,
  hostname guard that tolerates an unset `HOSTNAME`.
- Sets `PATH`, `LIBD_AI_SANDBOX_ROOT`, `LIBD_AI_SANDBOX_RUNTIME`; optionally site defaults such as
  `LIBD_AI_SANDBOX_MOUNTS` for a different mounts file.
- Source and install notes under `jhpce_module_source` (`README.md` with the install commands and
  the reproducibility block, as for other LIBD modules).

## 4. Documentation for two audiences

- `README.md` (users): replace `module use <repo>/modulefiles` with `module load libd_ai_sandbox`;
  keep the worked example; add "installing an agent in your sandbox home" and "agent modules".
- `docs/admin.md` (maintainers): site mounts file, deny list, site profiles and agent descriptors,
  install/upgrade/rollback, how to run the tests, where users' state lives
  (`~/.libd-ai-sandbox`, `~/.config/libd-ai-sandbox`, `$MYSCRATCH/ai-sandbox`).

## 5. Tests that run for any maintainer

- `tests/test_wrapper.sh` writes a `--write` target inside its own repository; in a read-only
  install that fails. Make the location configurable (`SBX_TEST_WRITE_DIR`, default: a folder under
  `$MYSCRATCH`) and keep one test that targets a directory under `/dcs04/lieber` the tester owns
  when given.
- `tests/runtime_probe.sh` defaults to the author's repository path; require the argument.
- Skip agent tests cleanly when no agent is available (already done for missing CLIs).
- Run the suite as a second user (different groups, no `~/R`, no agents) on a transfer node and a
  compute node before the first release.

## 6. Positron / VS Code remote sessions

See `docs/positron_remote_plan.md`: `--sshd PORT`, generated sshd config with `SetEnv` and
`ForceCommand`, `bin/libd-ai-positron-session` as an adaptable sbatch template, a dedicated
persistent host key (keys listed in `authorized_keys` are refused), `HostKeyAlias` on the client.
Tests: refusal of a login key as host key; a session over the alias needs no prompt.

## 7. Hardening and options, as needed

- Non-setuid fallback: host-root container under SingularityCE 4.5.1 `--userns`; add `--userns`
  automatically when the runtime is not setuid.
- Optional `--pid` for interactive sessions.
- Site policy knobs (forbid `real-rw`, restrict `--write` roots), `--keep-modules`.
- Deny list: it masks `/usr/bin/ssh` etc. but other ssh clients exist in shared software; the
  real barrier is that no login key is visible inside. Keep it that way by default (see
  `docs/design.md` §7).

## 8. Release

- Tag `v0.5.0` (first shared version) after sections 1-5, install, announce to LIBD users with the
  README link; collect feedback in GitHub issues.
