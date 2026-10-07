# project_details.md

## Background

LIBD users working on JHPCE may have write permissions across many shared project and data directories. AI coding agents and filesystem-crawling agents are useful for large exploratory tasks, but they can also execute arbitrary shell commands, generate scripts, test workflows, write caches, modify files in place, or accidentally delete data.

This project proposes a Singularity/Apptainer-based wrapper that gives an AI agent broad read access to relevant JHPCE/LIBD storage while minimizing accidental write risk.

The container acts as a protective execution layer: most shared storage is mounted read-only, while only a small number of explicitly configured paths are writable.

## Threat Model

### In Scope

The design should protect against accidental damage such as:

- Recursive deletes in shared storage.
- Accidental overwrite of project files.
- Tools that write index/cache/temporary files next to inputs.
- AI-generated scripts that assume they may modify input directories.
- Exploratory commands that mutate files during testing.
- Misconfigured pipelines writing outputs into protected source data directories.

### Out of Scope

The design does not fully protect against:

- Data exfiltration by an agent that has read access and network access.
- Misuse of data by a cloud-hosted AI provider.
- Malicious code intentionally trying to bypass containment.
- User credentials intentionally provided to the agent.
- Errors in site-wide Singularity/Apptainer configuration.
- Host-level privilege escalation.
- Confidentiality enforcement beyond normal JHPCE account permissions.

The practical assumption is that the agent should be treated as an automated process acting with the invoking user's read permissions.

## Key Design Choice: Data Protection, Not Data Security

The goal is not to claim that the AI agent is secure or isolated from all risk. Instead, the goal is narrower and operationally useful:

> Prevent accidental writes to LIBD/JHPCE data volumes while allowing broad read-only discovery and metadata extraction.

This distinction matters. Many AI agents require online communication with an external LLM service. If such an agent is allowed to inspect files, there may be residual confidentiality and policy risk. That risk must be managed through user behavior, institutional policy, agent configuration, and possibly future local-LLM work. It should not be misrepresented as solved by read-only filesystem binds.

## Filesystem Exposure Model

### Read-Only Mounts

The wrapper should mount selected JHPCE/LIBD paths read-only. The intended pattern is to preserve absolute paths inside the container, for example:

```text
Host path:
  /dcs04/lieber/marmaypag/spatialDLPFC_mdd_bpd_LIBD4100/spatialDLPFC_mdd_bpd/

Container path:
  /dcs04/lieber/marmaypag/spatialDLPFC_mdd_bpd_LIBD4100/spatialDLPFC_mdd_bpd/

Mount mode:
  read-only
```

Candidate read-only mounts should include major LIBD/JHPCE storage roots, subject to local verification:

```text
/dcs04/lieber
/dcs05/lieber
/dcs06/lieber
/dcs07/lieber
/dcs10/lieber
/jhpce/shared
```

The actual list should live in a configuration file, not only inside the wrapper.

Example configuration:

```tsv
# src           dest          mode   required
/jhpce/shared   /jhpce/shared ro     yes
/dcs04/lieber   /dcs04/lieber ro     no
/dcs05/lieber   /dcs05/lieber ro     no
/dcs06/lieber   /dcs06/lieber ro     no
/dcs07/lieber   /dcs07/lieber ro     no
/dcs10/lieber   /dcs10/lieber ro     no
```

### Writable Paths

The default writable paths should be limited to:

- Synthetic home directory.
- Container temporary/work directories.
- Optional durable output path provided by the user.

The durable output path should be mounted inside the container as:

```text
/agent_out
```

The wrapper may also support same-path writable mounting later, but `/agent_out` should be the default because it is explicit and avoids ambiguity when a writable subdirectory lives under a read-only mounted parent.

## Synthetic Home Directory

The wrapper should avoid writing to the user's real JHPCE home directory.

Instead, it should create a synthetic home under scratch, for example:

```text
$MYSCRATCH/ai-sandbox/home
```

If the real JHPCE home is:

```text
/users/gpertea1
```

then the synthetic home should be mounted inside the container at:

```text
/users/gpertea1
```

This preserves compatibility with tools that expect `$HOME` to be the normal JHPCE home path, while ensuring writes go to scratch-backed storage.

### Recommended Synthetic Home Contents

The synthetic home should be initialized conservatively:

```text
.bashrc
.cache/
.config/
.local/
R/
```

The generated `.bashrc` should be minimal and should not automatically copy sensitive host configuration.

Example `.bashrc`:

```bash
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

export PS1="[libd-ai-sandbox \u@\h \W]\\$ "
export TMPDIR=/tmp
export XDG_CACHE_HOME="$HOME/.cache"
export PIP_CACHE_DIR="$HOME/.cache/pip"
export R_USER="$HOME"
export R_LIBS_USER="$HOME/R/%p-library/%v"

umask 077
```

### Files Not to Copy by Default

Do not copy these into the synthetic home by default:

```text
.ssh/
.aws/
.gcp/
.azure/
.netrc
.git-credentials
.Renviron
.Rprofile
full .codex/ credentials
conda tokens or private channels
cloud provider credentials
```

If the user explicitly requests credential provisioning, it should be treated as an opt-in action with clear consequences.

## Shell and Tool Execution

The AI agent is expected to have shell access inside the container. It may also use R and Python tools for metadata inspection.

The wrapper should assume that the agent can execute arbitrary commands within its environment. Therefore, protection should rely on mount permissions and conservative environment construction rather than trusting the agent to behave.

## R and Python Metadata Tooling

The image should support metadata-oriented inspection of common genomics data formats without loading large datasets into memory unnecessarily.

Potential Python packages:

```text
anndata
h5py
zarr
numpy
pandas
scipy
pyarrow
```

Potential R packages:

```text
SummarizedExperiment
GenomicRanges
SingleCellExperiment
SpatialExperiment
HDF5Array
DelayedArray
rhdf5
data.table
jsonlite
```

Potential helper commands:

```text
libd-ai-inspect-h5ad
libd-ai-inspect-rse
libd-ai-inspect-h5
libd-ai-inspect-bam
libd-ai-inspect-vcf
libd-ai-inspect-parquet
```

The first version of these commands should emit structured JSON summaries where feasible.

Example metadata to report:

- Object class.
- Dimensions.
- Assay/layer names.
- Row/column metadata fields.
- HDF5 group/dataset structure.
- Dataset shapes and dtypes.
- File size and modification time.
- Sample names where safe and useful.
- Whether large matrix data were intentionally not loaded.

## Scheduler and Escape-Path Considerations

The agent should not be able to accidentally bypass the sandbox by submitting a new unsandboxed Slurm job from inside the container.

Default behavior should be one of:

1. Do not expose Slurm commands.
2. Place deny wrappers for `sbatch`, `srun`, `salloc`, `scancel`, and related commands early in `PATH`.
3. Require an explicit `--enable-slurm` option for advanced users.

A future controlled scheduler integration could provide a wrapper such as:

```bash
libd-ai-sbatch <jobscript>
```

That wrapper would rewrite or wrap the job so that it re-enters the same sandbox configuration.

## Network Considerations

Cloud-hosted AI agents often require network access to communicate with their provider-side LLM service. This project does not fully solve network-mediated data disclosure.

Possible future mitigations include:

- Documenting acceptable-use boundaries.
- Adding a no-network mode for local-only workflows.
- Adding proxy or allowlist support if institutionally useful.
- Supporting local LLMs if available in the future.
- Providing warnings when launching network-dependent agents.

These are policy and infrastructure questions as much as container-design questions.

## Lua Module Role

The Lua module should be simple. It should expose the wrapper and set default environment variables. It should not contain most of the logic.

Example responsibilities:

```lua
local root = "/jhpce/shared/libd/ai-sandbox"

prepend_path("PATH", pathJoin(root, "bin"))

setenv("LIBD_AI_SANDBOX_ROOT", root)
setenv("LIBD_AI_SANDBOX_IMAGE", pathJoin(root, "images", "libd-ai-rocky9.sif"))
setenv("LIBD_AI_SANDBOX_MOUNTS", pathJoin(root, "etc", "mounts.tsv"))
```

The wrapper should perform validation, bind construction, home initialization, and command execution.

## Wrapper Responsibilities

The wrapper should:

- Detect `singularity` or `apptainer`.
- Validate the configured image exists.
- Validate the mount configuration file exists.
- Create the synthetic home under `$MYSCRATCH`.
- Generate a minimal `.bashrc` if needed.
- Build read-only bind options from the mount configuration.
- Mount optional payloads read-only.
- Mount optional durable output as `/agent_out` read-write.
- Disable obvious escape commands by default.
- Use explicit containment options where available.
- Support `--dry-run`.
- Log launch metadata.

## Suggested Wrapper Options

```text
--agent codex|shell
--write PATH
--payload PATH
--cmd COMMAND
--enable-slurm
--dry-run
--print-binds
--no-network
--same-path-write PATH
--help
```

For the first prototype, only these are essential:

```text
--agent
--write
--payload
--cmd
--dry-run
--help
```

## Initial Agent Choices

Default agent:

```text
codex
```

Alternative:

```text
shell
```

The shell mode is essential for testing because it allows direct verification of mount behavior before involving an AI agent.

## Safety Defaults

The first prototype should default to:

```text
real home mounted writable: no
LIBD storage mounted writable: no
Slurm available: no
SSH/scp/rsync available: no
durable output path: absent unless explicitly requested
payload: read-only
synthetic home: yes
dry-run support: yes
```

## Open Questions

- Which exact LIBD/JHPCE paths should be included in the default mount configuration?
- Should `/jhpce/shared` always be mounted read-only?
- Which JHPCE module paths are needed for compatibility inside the container?
- Should the wrapper allow same-path writable output submounts, or only `/agent_out`?
- Should Codex credentials be provisioned manually, inherited from environment, or explicitly excluded?
- Should there be an institutional policy warning at launch?
- Should logs be written only under scratch, or also into `/agent_out` when provided?
- Should a no-network mode be implemented now or deferred?
- How should large-object metadata readers avoid expensive materialization by default?
