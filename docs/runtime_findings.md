# Phase 0: Runtime Findings on JHPCE (2026-10-07)

Measured on `transfer-01` (Rocky Linux 9.4, kernel 5.14.0-427); Slurm reports the same
OS/kernel line on `shared` partition compute nodes. Test image: `docker://rockylinux:9-minimal`
pulled to SIF. Probe script: `tests/runtime_probe.sh`.

> Network isolation rows are informational only. The sandbox goal is write safety; agents need
> network access to reach their LLM service, so the wrapper never requests `--network none`.

## Available runtimes

| Module | Version | Mode | Verdict |
|---|---|---|---|
| `singularity/3.11.4` (module default) | singularity-ce 3.11.4 | **setuid** (root-owned `starter-suid`) | **Use this.** All containment checks pass. |
| `singularity/4.5.1` | singularity-ce 4.5.1 | non-setuid (`starter-suid` present but mode 0755) | Plain `exec` fails: `No setuid installation found`. Works only with `--userns`; then `--network none` is silently ignored. |
| `apptainer/1.5.3` | 1.5.3 | non-setuid, no bundled `squashfuse` | Converts the SIF to a temp sandbox under `/tmp` on every launch. `--network none` silently ignored. `--fakeroot` works. |

All three modulefiles refuse to load unless `$HOSTNAME` matches `compute|transfer|cms`.
In non-interactive shells `HOSTNAME` is often unset and Lmod dies with a nil `string.match`
error. The wrapper should resolve the runtime by absolute path
(`/jhpce/shared/jhpce/core/singularity/3.11.4/bin/singularity`) rather than `module load`.

## Is setuid needed? No, not for write safety

Measured 2026-10-07, same flags on all three runtimes, ro bind of `/dcs04/lieber`:

| Check | SCE 3.11.4 setuid | SCE 4.5.1 `--userns` | Apptainer 1.5.3 |
|---|---|---|---|
| ro bind enforced (create/modify/delete) | yes | yes | yes |
| `mount -o remount,bind,rw` inside | denied | denied | denied |
| `unshare -rm` then remount rw, then write | denied, EROFS | denied, EROFS | denied, EROFS |
| read a dir accessible only via a supplementary group | works | works | works |
| supplementary group *names/ids* shown by `id`, `ls -l`, `stat` | correct | `nobody` (65534) | `nobody` (65534) |
| startup, 45 MB image | 0.5 s | 0.7 s | 1.9 s (SIF unpacked to /tmp each run; grows with image size) |

The kernel keeps the real supplementary gids for access checks and the NFS server sees them,
so unprivileged mode loses no read access. It only loses the *display* of group ownership,
which matters if an agent is asked to report file group ownership during a crawl.
Read-only flags on binds made by the runtime are locked against remount from any namespace the
agent can create.

## Containment behaviour verified with singularity/3.11.4

| Check | Result |
|---|---|
| `--bind /dcs04/lieber:/dcs04/lieber:ro` then create / append / delete inside a dir the user owns | all fail with `Read-only file system`; nothing appears on the host |
| `--contain` without a bind | `/dcs04`, `/dcs05` absent inside; `mount hostfs = no` site-wide |
| cwd auto-bind | skipped under `--contain` (`addCwdMount: contain was requested`); keep `--no-mount cwd --pwd $HOME` anyway |
| `--home $MYSCRATCH/.../home:/users/<u>` | `$HOME` keeps the real path, writes land in scratch, `.ssh` / `.codex` invisible |
| `--contain` **without** `--home`/`--no-home` | **real home is mounted read-write** (confirmed write). The wrapper must always pass `--home` |
| rw bind of a deep group-only `drwxrws---` dir under `/dcs04` to `/agent_out`, parent bound ro | write to `/agent_out` succeeds, write elsewhere under `/dcs04/lieber` still fails |
| same-path rw bind nested under ro parent | works; rw child does not loosen the parent |
| same-path rw bind whose destination dir does not exist | Singularity **creates the destination directory on the host storage** (observed: empty `testout/` left in this repo). The wrapper must require `--write`/same-path targets to already exist and never let the runtime create them |
| payload bind `:ro` | writes fail |
| `--bind /dcs04:/dcs04:ro` (the **autofs root**) | **NOT protected.** The nested NFS export `/dcs04/lieber` shows `rw` inside and a write under it succeeded. The `ro` flag applies only to the filesystem bound, never to mounts nested below it (pre-existing or automounted later via `mount slave`). Bind each real export (`/dcs04/lieber`) and verify from `/proc/mounts` that nothing is mounted strictly below each ro source |
| `/tmp` under `--contain` | 64 MB tmpfs (`sessiondir max size = 64`); 100 MB write fails. With `--workdir $MYSCRATCH/...`, `/tmp` is scratch-backed |
| `sbatch srun salloc scancel ssh scp rsync` | absent in image; `/run/munge` not mounted, so Slurm cannot work even if binaries were added |
| `--net --network none` | only `lo` visible |
| `--cleanenv` with `OPENAI_API_KEY` set on host | not propagated; env contains only `HOME PATH SINGULARITY_*` |
| image root (`/usr`, `/opt`) | read-only |

Same checks on `apptainer/1.5.3` and `singularity/4.5.1 --userns`: read-only binds, synthetic
home, nested mounts and `/tmp` behave identically, but network isolation does **not** apply
and files owned by groups outside the user namespace display as `nobody`.

## Host compatibility through read-only `/jhpce/shared`

- `/jhpce/shared/jhpce/core/node/24.11.0` works inside the image; Codex CLI 0.161.0 runs from a
  read-only bind of `~/.local/lib/node_modules/@openai/codex`. Claude Code is a static-ish ELF and
  should behave the same. Credentials (`~/.codex/auth.json`, `~/.claude/.credentials.json`) are
  not visible unless explicitly copied into the synthetic home.
- `conda_R/4.5.x` R 4.5.3 starts inside a Rocky 9 minimal image. Its site profile and `utils`
  shell out to `hostname` and `which`, both missing from `rockylinux:9-minimal`. With those
  present, SummarizedExperiment / SpatialExperiment / rhdf5 / HDF5Array load. The image must
  include `which`, `hostname`, `procps-ng`, `util-linux`, `findutils`, `file`, `less`.
- `conda_R`'s Python 3.12 has no `h5py`/`anndata`; the image needs its own Python stack.
- The site profile tries to create `$HOME/R/4.5.x`; the synthetic home should pre-create `R/`.

## Storage roots

`/dcs04/lieber`, `/dcs05/lieber`, `/dcs07/lieber`, `/jhpce/shared` exist (autofs for `/dcs*`).
`/dcs06/lieber`, `/dcs10/lieber`, `/dcl01/lieber`, `/dcl02/lieber` do not exist on this node;
keep them `required=no` in `etc/mounts.tsv`. `$MYSCRATCH=/fastscratch/myscratch/<user>`
(NFS, 0700). User `~/work` is a symlink into `/dcs04`; symlinks from the real home are not
present in the synthetic home, so agents must use absolute `/dcs04/...` paths.

## Autofs layout on JHPCE

`/dcs04 /dcs05 /dcs06 /dcs07 /dcs10 /dcl01 /dcl02 /legacy /dcl02/leased` are autofs indirect
maps (`/etc/auto.dcs04` etc.); each lab directory is its own NFS export. `/jhpce/shared` and
`/users` are single NFS mounts, but `/users/<u>/ceph_backup` is a nested FUSE mount in at least
one home, which is one more reason never to bind the real home.

## Implications for the wrapper

1. Default runtime: `singularity/3.11.4` by absolute path. Apptainer 1.5.3 and 4.5.1 with
   `--userns` are acceptable fallbacks for write safety; they are slower to start and show
   foreign groups as `nobody`.
1. **Bind real mount points only.** Read `/proc/mounts`; for every ro source require that it is
   itself a mount point (or inside exactly one) and that no other mount point lies strictly
   below it. Refuse to launch otherwise. Never bind an autofs root.
2. Mandatory flags: `--contain --cleanenv --no-mount cwd --home <scratch>:<real-home>
   --workdir <scratch>/work --pwd <real-home>`. Never launch without `--home`.
3. `--writable-tmpfs` is unnecessary; the 64 MB session tmpfs is the thing to avoid.
4. Deny-wrappers for Slurm/ssh are belt-and-braces; the image simply must not ship them and
   `/run/munge` must never be bound.
5. Record `sha256sum` of the SIF and `singularity sif list` in the launch log; neither runtime
   prints a digest on `exec`.

## Host-root container (2026-10-07)

- `singularity exec ... /` fails: `FATAL: / as sandbox is not authorized`.
- A skeleton directory as the container with host `/usr /etc /opt` bound read-only works under
  SCE 3.11.4. Without `/var/lib/sss` bound, user lookups fail (`id: cannot find name`), the site
  profile computes `MYSCRATCH` from the numeric uid, and startup takes ~15 s on lookup timeouts.
  With it bound, names resolve and startup is 0.2 s bare, 1.0 s with a login shell.
- Inside: site profile runs, `JHPCE_ROCKY9_DEFAULT_ENV` and `JHPCE_tools/3.0` load,
  `module load conda_R/4.5.x` then `library(SummarizedExperiment)` works.
- Slurm clients fail without `/run/munge` (`squeue: error: If munged is up...`); `sudo` fails
  (`nosuid`). A file bind of a deny script over `/usr/bin/sbatch` inside the ro `/usr` bind works.
- Lmod shell functions break under `set -u`; scripts run inside must not set it before `module`.
- `readlink -f` / `stat` on an unmounted autofs entry (`/dcs07/lieber` on a fresh compute node)
  does not trigger the automount; the wrapper's check then sees the autofs map. Listing
  `"$path/."` triggers it. Verified on compute-092 with `/dcs07/lieber` initially unmounted.

## Symlinks (2026-10-07)

- Links under `/dcs04/lieber/marmaypag` are relative or point into `/dcs04/lieber`; all resolve
  inside. Absolute links to `/dcs05/lieber` and `/dcs07/lieber` resolve.
- With the first skeleton (host top level mirrored), a link to unmounted `/dcl01` resolved to an
  empty directory. The skeleton now omits storage roots; such links are broken, as they should be.
- Codex's bwrap sandbox fails inside SCE 3.11.4: `bwrap: Can't bind mount /oldroot/ on /newroot/:
  Unable to mount source on destination: Invalid argument`.

## sshd inside the sandbox (2026-10-07)

- Non-root `/usr/sbin/sshd -D` (OpenSSH 8.7p1) runs inside the host-root container; publickey
  login, sessions inside the sandbox (ro storage, synthetic home, modules), stdin bootstrap
  scripts and `ssh -L` forwarding all work. Details: `docs/positron_remote_plan.md`.
- sshd discards container `--env` variables; `SetEnv` and `ForceCommand` in sshd_config work.
- `UsePAM no` logs "not supported in RHEL" (harmless for a non-root sshd).
- Without `--pid`, a background process started in the container survives the container's exit;
  with `--pid` it does not.

## ssh escape routes (2026-10-07)

- `conda_R/{4.3.x,4.4,4.4.x,4.5,4.5.x}/bin/ssh` exist; after `module load conda_R/4.5.x` inside the
  sandbox `ssh` resolves there, not to the masked `/usr/bin/ssh`. `paramiko` is installed in
  `/jhpce/shared/jhpce/core/python/{3.12.12,3.14.6}`.
- Inside the sandbox (no `~/.ssh`), `ssh -o BatchMode=yes transfer-01 true` fails:
  `Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password,keyboard-interactive)`.
- The author's `~/.ssh/id_rsa` has no passphrase and is in `~/.ssh/authorized_keys`; on the host,
  `ssh -i ~/.ssh/id_rsa transfer-01` logs in without a prompt. Any key like that, if visible
  inside, is a route out of the sandbox.
