# Example environment modules for the standalone tarball

These are optional, site-installed examples — not something `make` builds or
uses. They're for HPC-style login nodes that expose software through
`module load` on top of the no-root, no-systemd tarball produced by `make
standalone` (see the top-level [INSTALL.md](../INSTALL.md#4-install--standalone-tarball-no-root-no-systemd)).
Loading the module just puts `rserver-standalone` (a thin alias to the
extracted tree's `run-standalone.sh`) on `$PATH` — it doesn't start anything
by itself.

Two equivalent copies are provided since sites run one module tool or the
other:

| File | For |
|------|-----|
| `rstudio-server/2026.07.1-147.lua` | [Lmod](https://lmod.readthedocs.io/) |
| `rstudio-server/2026.07.1-147` | [Environment Modules](https://modules.readthedocs.io/) (Tcl), also read by Lmod's Tcl-compat mode |

## Install

1. Build and extract the standalone tarball on (or for) the target host —
   see INSTALL.md — e.g. into:

   ```
   /opt/apps/rstudio-server/2026.07.1-147/rstudio-server-2026.07.1-147.el10.x86_64/
   ```

2. Edit the `prefix` variable near the top of whichever modulefile you use to
   point at that directory.
3. Copy the module tree (keeping the `rstudio-server/<version>` layout) onto
   a directory already on `$MODULEPATH`, or add its parent to `$MODULEPATH`:

   ```bash
   module use /opt/apps/modulefiles
   module avail rstudio-server
   module load rstudio-server/2026.07.1-147
   rserver-standalone --help
   ```

## Notes

- The tarball is OS/glibc-specific (see the asymmetries in the top-level
  [README](../README.md#notes)); if a site serves both EL and Ubuntu login
  nodes, build and extract one tarball per OS generation and give each its
  own `prefix` — either as separate module versions (e.g.
  `2026.07.1-147-el10`, `2026.07.1-147-ubuntu24.04`) or by relying on
  per-node `$MODULEPATH` to only expose the matching one.
- Bump the version in the filename and the `prefix`/`whatis`/help text
  together when building a newer `RSTUDIO_GIT_REF` — nothing here reads the
  Makefile's version variables automatically.
- `run-standalone.sh` still needs an `R` on `$PATH` at run time (or
  `--r-bin PATH`); if your site also modules R, document loading it first
  (e.g. `module load R/4.4.1 rstudio-server/2026.07.1-147`).
