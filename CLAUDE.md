# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo does **not** contain RStudio Server source. It's a Docker-based build
harness that clones a pinned tag of [rstudio/rstudio](https://github.com/rstudio/rstudio)
(currently `v2026.07.1+147`, set via `RSTUDIO_GIT_REF` in the `Makefile`) and
compiles it from scratch inside Docker, for two OS families:

- **EL** (Enterprise Linux 8/10, on Rocky Linux base images) → relocatable `.rpm`
- **Ubuntu** (Server LTS 24.04/26.04) → `.deb`

Each build also produces a **standalone, non-root, no-systemd `.tar.gz`** derived
from the same package's file payload — for targets without root/Docker/apt/dnf
(e.g. HPC login nodes). Every artifact is smoke-tested (installed/extracted +
`rserver` started + login page curled) on a clean image before being considered
built.

Everything is driven by one `Makefile` calling Dockerfiles in `docker/` and
shell scripts in `scripts/`. CI (`.github/workflows/build.yml`) runs the exact
same Makefile targets — it does not fork any build logic, only overrides
`DOCKER`/`DOCKER_BUILD`/`BUILD_FLAGS` to use `docker buildx build` with GHA
layer caching instead of plain `sudo docker build`.

## Common commands

```bash
make rpm             # (DISTRO=el)     compile + build the RPM -> output/<tag>/
make deb             # (DISTRO=ubuntu) compile + build the .deb -> output/<tag>/
make test            # (DISTRO=el)     install the RPM on a clean image, smoke-test it
make test-deb        # (DISTRO=ubuntu) install the .deb on a clean image, smoke-test it
make standalone      # build the non-root install tarball (works for either DISTRO)
make test-standalone # extract + run the tarball as a non-root user, smoke-test it
make all             # build + test BOTH the system package and the tarball (default goal)
make shell           # debug shell inside the builder image (before the package build step)
make clean           # remove this DISTRO/version's images + the entire ./output/ tree
```

OS/version selection (each keeps separate images and `output/<tag>/`, so they
never clobber each other):

```bash
make all DISTRO=el     EL=8            # or: make el8
make all DISTRO=el     EL=10           # or: make el10  (EL default)
make all DISTRO=ubuntu UBUNTU=24.04    # or: make ubuntu24.04
make all DISTRO=ubuntu UBUNTU=26.04    # or: make ubuntu26.04  (UBUNTU default)
```

Build a different RStudio tag/version:

```bash
make all RSTUDIO_GIT_REF=v2026.07.1+147 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=07 \
  RSTUDIO_VERSION_PATCH=1 RSTUDIO_VERSION_SUFFIX=+147
```

Docker invocation: the Makefile defaults to `sudo docker` (`DOCKER=sudo docker`)
since the primary dev host's user isn't in the `docker` group. If your user is,
pass `DOCKER=docker`. There is no lint/test suite beyond the Make targets
themselves — "testing a change" means running the relevant `make` target(s)
against Docker, which takes real time (a from-source RStudio build, several GB,
long first run) and disk.

CI locally-equivalent invocation (what `.github/workflows/build.yml` actually
runs per matrix leg — useful to reproduce a CI failure locally):

```bash
make all DOCKER=docker DOCKER_BUILD="docker buildx build" \
  BUILD_FLAGS="--cache-from type=gha --cache-to type=gha,mode=max --load"
```

## Architecture: the build pipeline

Each `DISTRO`/version combination flows through the same dependency chain
(`make all` = `$(PKG_BUILD)` → `$(PKG_TEST)` → `standalone` → `test-standalone`,
where `$(PKG_BUILD)` is `rpm` or `deb` depending on `DISTRO`):

1. **`image`** — `docker/Dockerfile.build` (EL) or `Dockerfile.build-deb`
   (Ubuntu) clones the pinned RStudio tag, installs OS deps + toolchain, and
   builds the package via `scripts/build-rpm.sh` / `scripts/build-deb.sh`,
   which wrap upstream's `package/linux/make-package Server RPM|DEB`.
2. **`rpm`/`deb`** — extracts the built package out of the (throwaway)
   container into `output/<tag>/`, renamed to a canonical filename encoding
   version + OS + arch (see `README.md` "Package naming").
3. **`test`/`test-deb`** — builds a small test image (`Dockerfile.test` /
   `Dockerfile.test-deb`) from just the package + `scripts/test-rpm.sh` /
   `test-deb.sh`, installs it on a clean base image, starts `rserver`
   directly (no systemd in containers), and curls the sign-in page.
4. **`standalone`** — runs `scripts/make-standalone.sh` *inside the already-
   built builder image* (which already has `rpm2cpio`/`cpio` or `dpkg-deb`
   available). It unpacks just the package's **file payload**, skipping the
   postinst scriptlet entirely (that's where the systemd unit, `/usr/bin`
   symlinks, and the `rstudio-server` system user get created for a package
   install) — so the tarball is root-free and systemd-free *by construction*.
   Bundles in `scripts/run-standalone.sh` as the launcher.
5. **`test-standalone`** — `Dockerfile.standalone-test[-deb]` extracts and
   runs the tarball as an *unprivileged* user on a clean image, and asserts
   no systemd service exists anywhere, proving the no-root/no-systemd claim.

Key asymmetries between the two OS families to keep in mind when touching
either path:

- **Relocatable RPM vs fixed-prefix DEB**: `build-rpm.sh` turns off upstream's
  `CPACK_SET_DESTDIR=ON` and declares a relocatable prefix so the RPM supports
  `rpm --relocate`/`--prefix`; `.deb` has no such mechanism and always installs
  to `/usr/lib/rstudio-server`, so `build-deb.sh` skips that patching entirely.
- **EL needs a newer toolchain**: EL8's system gcc is too old, so `gcc-toolset-14`
  is installed/activated for both the bundled-dependency and RStudio compiles;
  EL8 uses `powertools`, EL10 uses `crb`. Ubuntu ships a modern gcc already.
- **JDK 21 for the GWT client**: the GWT build wants Java 17+; EL8's default
  `javac` resolves to JDK 8 via `alternatives`, so `build-rpm.sh` points
  `JAVA_HOME` at JDK 21 explicitly. Ubuntu's dependency script installs
  `openjdk-17-jdk` directly, so this is normally a no-op there.
- **Ubuntu 26.04 is a best-effort shim, not upstream-verified**: the pinned
  RStudio tag ships `install-dependencies-<codename>` scripts only through
  "noble" (24.04). `Dockerfile.build-deb` detects the container's real
  codename and, if unmatched, clones `install-dependencies-noble` and patches
  its codename guard. If a 26.04 build fails on a package-name error, that
  script is the first place to check; `UBUNTU=24.04` sidesteps it.
- **Package-name deltas patched pre-install (EL)**: `Dockerfile.build` rewrites
  a few upstream Fedora/RHEL dependency names before running the installer
  (`java`→`java-21-openjdk`, `postgresql-devel`→`libpq-devel` on both; EL10
  additionally needs `zlib-devel`→`zlib-ng-compat-devel`).
- **R must be present at build time** (not just runtime) on both families,
  because `dependencies/common/install-packages` runs R to install a few R
  packages during the dependency-install step.

`scripts/run-standalone.sh` is the standalone launcher end users invoke
directly on the target machine — it redirects all writable state (including a
private **SQLite** metadata DB, so no Postgres server is needed) to
`~/.local/share/rstudio-standalone` instead of root-owned `/var`/`/etc`, and
runs `rserver` in the foreground as the invoking user.

## Working on this repo

- Everything here fans out from `Makefile` variables (`DISTRO`, `EL`, `UBUNTU`,
  `RSTUDIO_GIT_REF`, `RSTUDIO_VERSION_*`, `DOCKER`, `DOCKER_BUILD`,
  `BUILD_FLAGS`) — check there first when changing build parameters or output
  naming (`RPM_FILENAME`/`DEB_FILENAME`/`STANDALONE_FILENAME`).
- Local and CI paths **must stay identical** apart from the three Makefile
  variables CI overrides (`DOCKER`, `DOCKER_BUILD`, `BUILD_FLAGS`); don't add
  CI-only logic to the Dockerfiles/scripts.
- `output/` is git-ignored build output, regenerated by `make`; `make clean`
  wipes it along with this `DISTRO`/version's images.
- When editing a Dockerfile or script for one OS family, check whether the
  same fix is needed on the other family's equivalent file (they're
  intentionally parallel: `Dockerfile.build` / `Dockerfile.build-deb`,
  `build-rpm.sh` / `build-deb.sh`, `test-rpm.sh` / `test-deb.sh`,
  `Dockerfile.standalone-test` / `Dockerfile.standalone-test-deb`) — but do
  not force artificial symmetry where the OS families genuinely differ (see
  the relocation/toolchain asymmetries above).
