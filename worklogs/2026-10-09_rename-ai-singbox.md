# 2026-10-09 — Renamed to ai-singbox (wrapper 0.5.0-dev)

- Command `libd-ai-sandbox` -> `ai-singbox`; module `libd_ai_sandbox` -> `ai-singbox`,
  description "customizable Singularity container sandbox for AI agents".
- Environment `LIBD_AI_SANDBOX_*` -> `AI_SINGBOX_*`; per-user `~/.libd-ai-sandbox` ->
  `~/.ai-singbox`, `~/.config/libd-ai-sandbox` -> `~/.config/ai-singbox`; in-container
  `/.libd-ai-sandbox/` -> `/.ai-singbox/`; notes markers `ai-singbox:begin/end` (old markers still
  recognized and replaced); planned `ai-singbox-positron`, `ai-singbox-sbatch`.
- LIBD storage split into site profile `libd`; site `default` is `include = libd`.
- Texts made generic ("cluster storage"); banner and agent notes list the session's actual
  read-only folders instead of hard-coded `/dcs*/lieber`.
- The author's state moved: `~/.libd-ai-sandbox` -> `~/.ai-singbox`; the wrapper warns when it
  finds the old folder and no new one.
- History files (`worklogs/`, `docs/initial/`) keep the old name.
- Gotcha: `sed -i` replaced the `CLAUDE.md` symlink with a file; restored (`ln -s AGENTS.md CLAUDE.md`).
- Tests: 85/85 transfer-01, 82/82 compute-122.
