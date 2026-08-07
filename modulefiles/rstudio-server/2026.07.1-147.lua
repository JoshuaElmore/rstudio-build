-- Lmod modulefile for the standalone (non-root, no systemd) RStudio Server
-- tarball built by this repo (`make standalone`). See ../README.md.
--
-- Edit `prefix` below to wherever you extracted the …-standalone.tar.gz on
-- THIS host (it must match the host's OS/arch the tarball was built for).

help([[
RStudio Server 2026.07.1-147 -- standalone, non-root, no-systemd install.

Loading this module puts a `rserver-standalone` command on your PATH; it
wraps the extracted tarball's run-standalone.sh launcher and runs a
single-user RStudio Server session in the foreground, with all writable
state kept under ~/.local/share/rstudio-standalone.

Usage:
  rserver-standalone                      # http://127.0.0.1:8787, no auth
  rserver-standalone --password 'secret'  # require a login
  rserver-standalone --port 8888 --r-bin /opt/R/4.4.1/bin/R
  rserver-standalone --help               # all options

Requires an R on $PATH (or pass --r-bin). Stop with Ctrl-C.
]])

whatis("Name        : rstudio-server")
whatis("Version     : 2026.07.1-147")
whatis("Category    : development, statistics")
whatis("Description : RStudio Server, standalone non-root/no-systemd install")
whatis("URL         : https://github.com/rstudio/rstudio")

-- Site-specific: where the …-standalone.tar.gz was extracted on this host.
-- Matches $BASE from scripts/make-standalone.sh, e.g.
--   /opt/apps/rstudio-server/2026.07.1-147/rstudio-server-2026.07.1-147.el10.x86_64
local prefix = "/opt/apps/rstudio-server/2026.07.1-147"

if not isDir(prefix) then
    LmodError(
        "rstudio-server/2026.07.1-147: install prefix not found:\n    " .. prefix ..
        "\nExtract the standalone tarball there (tar -xzf …-standalone.tar.gz)," ..
        "\nor edit the 'prefix' variable in this modulefile."
    )
end

if not isFile(pathJoin(prefix, "run-standalone.sh")) then
    LmodError("rstudio-server/2026.07.1-147: " .. prefix .. " does not look like an extracted standalone tarball (no run-standalone.sh).")
end

setenv("RSTUDIO_PREFIX", prefix)
prepend_path("PATH", pathJoin(prefix, "bin"))

-- run-standalone.sh lives at the top of the extracted tree, not in bin/, so
-- expose it as a stable PATH command instead of requiring users to know the
-- tree layout or cd into it.
set_alias("rserver-standalone", pathJoin(prefix, "run-standalone.sh"))

if mode() == "load" then
    LmodMessage("rstudio-server/2026.07.1-147 loaded -- run 'rserver-standalone --help' to start a session.")
end
