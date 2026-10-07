-- -*- lua -*-
-- vim:ft=lua:et:ts=4
--
-- Development modulefile: the install root is derived from this file's location
-- (<root>/modulefiles/libd_ai_sandbox/0.1.lua). The deployed copy in
-- jhpce_module_config should set `root` to the install directory explicitly.

help([[
libd_ai_sandbox 0.1: run a shell or an AI agent on JHPCE with LIBD/JHPCE storage
mounted read-only. Only $MYSCRATCH and directories passed with --write are
writable; your real home is replaced by a scratch-backed synthetic home.

  libd-ai-sandbox --help
  libd-ai-sandbox --dry-run --write /dcs04/lieber/<lab>/<project>/agent_out
]])

whatis("Name: libd_ai_sandbox")
whatis("Version: 0.1")
whatis("Description: read-only data-protection sandbox for AI agents (SingularityCE 3.11.4)")

-- Guard against an unset HOSTNAME (the site singularity/apptainer modulefiles
-- fail with a nil error in that case).
local host = os.getenv("HOSTNAME") or capture("hostname") or ""
if not string.match(host, "compute") and not string.match(host, "transfer") then
    LmodError("\
libd_ai_sandbox can only be loaded on a compute or transfer node. Use srun to get one.")
end

local root = myFileName():match("^(.*)/modulefiles/[^/]+/[^/]+$")

if (mode() == "load") then
    LmodMessage("Loading libd_ai_sandbox/0.1 (LIBD/JHPCE storage will be read-only inside)")
elseif (mode() == "unload") then
    LmodMessage("Unloading libd_ai_sandbox/0.1")
end

prepend_path("PATH", pathJoin(root, "bin"))
setenv("LIBD_AI_SANDBOX_ROOT", root)
setenv("LIBD_AI_SANDBOX_RUNTIME", "/jhpce/shared/jhpce/core/singularity/3.11.4/bin/singularity")
