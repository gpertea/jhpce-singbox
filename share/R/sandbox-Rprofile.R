## ai-singbox user R profile (set via R_PROFILE_USER inside the sandbox).
## Runs after the site Rprofile.site, which has already put the writable sandbox
## library (~/R/<version> in the synthetic home) first in .libPaths().
## Adds the real home's personal libraries, mounted read-only at /host_home/R, right
## after it: installed packages are found, new installs still go to the sandbox.
## Then sources the synthetic home's own ~/.Rprofile, as R would have.
local({
    host <- "/host_home/R"
    if (dir.exists(host)) {
        thisR <- sub("/R.*", "", sub(".*conda_R/", "", R.home()))
        cand <- c(file.path(host, thisR),
                  file.path(host, paste0(R.version$platform, "-library"),
                            paste(R.version$major, sub("\\..*", "", R.version$minor), sep = ".")))
        cand <- cand[dir.exists(cand)]
        if (length(cand)) {
            cur <- .libPaths()
            .libPaths(unique(c(cur[1], cand, cur[-1])))
        }
    }
})
if (file.exists("~/.Rprofile")) source("~/.Rprofile")
