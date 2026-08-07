# Build RStudio Server on EL 8/10 or Ubuntu Server LTS 24.04/26.04 with Docker

Compiles [RStudio Server](https://github.com/rstudio/rstudio) from source —
pinned to tag **`v2026.07.1+147`** — inside a Docker container, produces an
installable system package (a **relocatable RPM** on Enterprise Linux, or a
**.deb** on Ubuntu) *and* a **non-root standalone tarball**, then smoke-tests
both on a clean image of the target OS.

Two OS families, selected with `DISTRO`:

| `DISTRO` | Versions | Package | Aliases |
|----------|----------|---------|---------|
| `el` (default) | `EL=8` / `EL=10` | relocatable `.rpm` | `make el8`, `make el10` |
| `ubuntu` | `UBUNTU=24.04` / `UBUNTU=26.04` | `.deb` | `make ubuntu24.04`, `make ubuntu26.04` |

> **New here?** See **[INSTALL.md](INSTALL.md)** for a step-by-step build +
> install guide (system package and the no-root tarball, both OS families).

## Layout

| File | Purpose |
|------|---------|
| `Makefile` | Orchestrates everything (`build → extract → rename → test`) for both OS families. |
| `.github/workflows/build.yml` | CI: runs the same Makefile as a 4-way matrix (EL 8/10, Ubuntu 24.04/26.04), uploads artifacts, publishes to GitHub Releases on tag push. |
| `docker/Dockerfile.build` | EL 8/10 builder: clones the tag, installs deps, builds the RPM. |
| `docker/Dockerfile.build-deb` | Ubuntu 24.04/26.04 builder: clones the tag, installs deps, builds the .deb. |
| `docker/Dockerfile.test` | EL 8/10 + R: installs the RPM and runs the smoke test. |
| `docker/Dockerfile.test-deb` | Ubuntu + R: installs the .deb and runs the smoke test. |
| `docker/Dockerfile.standalone-test` | EL 8/10 + R: extracts the standalone tarball **as a non-root user** and smoke-tests it. |
| `docker/Dockerfile.standalone-test-deb` | Ubuntu + R: same standalone smoke test on Ubuntu. |
| `scripts/build-rpm.sh` | Activates the right toolchain/JDK, runs `package/linux/make-package Server RPM`, makes the RPM relocatable. |
| `scripts/build-deb.sh` | Same, for `make-package Server DEB` — no relocation patching needed (DEB has no relocation mechanism). |
| `scripts/make-standalone.sh` | Unpacks the built package's file payload (rpm2cpio/cpio or dpkg-deb, whichever applies) and bundles it + `run-standalone.sh` into a non-root `.tar.gz`. |
| `scripts/run-standalone.sh` | Launches RStudio Server as an ordinary user — no root, no systemd (state redirected out of `/var` and `/etc`). |
| `scripts/test-rpm.sh` | Asserts relocatability, runs `verify-installation`, starts `rserver`, curls the login page. |
| `scripts/test-deb.sh` | Same checks minus relocatability (not applicable to .deb). |
| `scripts/test-standalone.sh` | Extracts + runs the standalone tarball as a non-root user, asserts no systemd service, curls the login page. Identical for both OS families. |
| `output/<tag>/` | Extracted, renamed package **and `…-standalone.tar.gz`** artifacts land here, where `<tag>` is `el8`/`el10`/`ubuntu24.04`/`ubuntu26.04`. |

## Usage (local)

```bash
make rpm             # (DISTRO=el)     compile + build the RPM
make deb             # (DISTRO=ubuntu) compile + build the .deb
make test            # (DISTRO=el)     install the RPM on a clean image and smoke-test it
make test-deb        # (DISTRO=ubuntu) install the .deb on a clean image and smoke-test it
make standalone      # build a non-root install tarball (.tar.gz, no rpm/deb/systemd)
make test-standalone # extract + run that tarball as a normal user and smoke-test it
make all             # build + test BOTH the system package and the tarball (default)
make shell           # debug shell in the builder image
make clean           # remove the current DISTRO/version's images + the entire ./output/ tree
```

`make rpm`/`make test` only make sense with `DISTRO=el` (the default); `make
deb`/`make test-deb` only make sense with `DISTRO=ubuntu`. `make standalone`,
`make test-standalone`, and `make all` are OS-family-generic: they build
whichever package `DISTRO` selects.

```bash
make all DISTRO=ubuntu UBUNTU=24.04   # -> output/ubuntu24.04/
make all DISTRO=el     EL=8           # -> output/el8/
```

## Non-root install (no rpm/deb, no systemd)

`make standalone` produces a **plain `.tar.gz`** that an ordinary user extracts
and runs with no root, no package manager, and no systemd service:

```
output/el10/rstudio-server-2026.07.1-147.el10.x86_64-standalone.tar.gz
output/ubuntu24.04/rstudio-server-2026.07.1-147.ubuntu24.04.x86_64-standalone.tar.gz
```

It works by unpacking the built package's *file payload* (the
`/usr/lib/rstudio-server` tree — from the RPM via `rpm2cpio`/`cpio`, or from the
.deb via `dpkg-deb -x`) and bundling the `run-standalone.sh` launcher into a
single top-level directory (plus a short `INSTALL.txt`). Everything that needs
root — the systemd unit, the `/usr/bin` symlinks, the `rstudio-server` system
user, `/etc/rstudio` — is created by the package's postinst *scriptlet*, which
is **not** part of the payload, so a payload install is root-free and
systemd-free by construction, for either package format.

```bash
# On the target machine, as any normal user — extracting IS the install:
tar -xzf rstudio-server-2026.07.1-147.el10.x86_64-standalone.tar.gz
cd rstudio-server-2026.07.1-147.el10.x86_64
./run-standalone.sh                    # http://127.0.0.1:8787, no auth
./run-standalone.sh --password 'secret'  # require a login
./run-standalone.sh --help             # port, binding, R path, …
```

Extract it anywhere you like. The only runtime requirement is an `R` on the
target (point at a specific one with `run-standalone.sh --r-bin PATH`). This is
the same single-user approach Open OnDemand uses; state lives under
`~/.local/share/rstudio-standalone` instead of root-owned `/var` and `/etc`.

The build machine needs Docker; the **target does not** — copy the one `.tar.gz`
to any compatible machine and extract it. Because the binaries link the build
OS's glibc, build with the `EL`/`UBUNTU` value matching the target's OS
generation, and a matching CPU arch (`x86_64`).

### Choosing the OS

```bash
make all DISTRO=el     EL=10          # EL 10          (alias: make el10)
make all DISTRO=el     EL=8           # EL 8           (alias: make el8)
make all DISTRO=ubuntu UBUNTU=26.04   # Ubuntu 26.04   (alias: make ubuntu26.04)
make all DISTRO=ubuntu UBUNTU=24.04   # Ubuntu 24.04   (alias: make ubuntu24.04)
```

Each OS/version keeps its own images, output dir (`output/el8/`, `output/el10/`,
`output/ubuntu24.04/`, `output/ubuntu26.04/`) and package, so none of them
clobber each other.

- On **EL 8** the build automatically uses the `powertools` repo and a
  `gcc-toolset` compiler (its system gcc is too old), and keeps the EL8 package
  names; **EL 10** uses `crb` and the EL10 names.
- **Ubuntu 24.04/26.04** ship a modern system gcc already — no toolset needed.
  Ubuntu 24.04's codename ("noble") has an upstream-provided dependency list;
  **Ubuntu 26.04 relies on a compatibility shim** (see [Notes](#notes)) since
  the pinned RStudio tag may not yet ship a script for its codename. Prefer
  `UBUNTU=24.04` if a 26.04 build hits a package-name error.

### Package naming

The extracted package is renamed to encode the **RStudio version** and the
**target OS**:

```
output/el10/rstudio-server-2026.07.1-147.el10.x86_64.rpm
output/el8/rstudio-server-2026.07.1-147.el8.x86_64.rpm
                          └──── version ────┘ └OS┘ └arch┘

output/ubuntu24.04/rstudio-server_2026.07.1-147-ubuntu24.04_amd64.deb
                                 └──── version ────┘  └────OS────┘ └arch┘
```

(RPM uses the `x86_64` arch token; .deb follows Debian's own
`name_version_arch.deb` convention and `amd64`.)

### Build a different tag/version

```bash
make all \
  RSTUDIO_GIT_REF=v2026.07.1+147 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=07 \
  RSTUDIO_VERSION_PATCH=1 RSTUDIO_VERSION_SUFFIX=+147
```

## GitHub Actions

`.github/workflows/build.yml` runs the **exact same** Makefile/Dockerfiles in
CI, as a matrix over all **four** supported targets (one parallel job each):
**EL 8, EL 10, Ubuntu 24.04, Ubuntu 26.04**. Trigger it manually
(**Actions → Build, test, and publish RStudio Server packages → Run
workflow**, with optional tag/version inputs) or by pushing a `v*` tag. Each
matrix leg:

1. frees runner disk space (the build needs several GB),
2. `make rpm`/`make deb` — compiles + builds the system package for that target,
3. `make test`/`make test-deb` — installs it on a clean image of that OS and
   smoke-tests it,
4. `make standalone` — builds the non-root, no-systemd tarball from that same
   package,
5. `make test-standalone` — extracts + runs it as an unprivileged user and
   smoke-tests it,
6. uploads **two** build artifacts per leg (the system package, and the
   standalone tarball), and attaches both to the GitHub Release on tag pushes.

The four legs use separate GHA cache scopes (`el8` / `el10` / `ubuntu24.04` /
`ubuntu26.04`) so they don't evict each other.

Pushing a `v*` tag creates/updates a GitHub Release for that tag with all 8
files attached (4 targets × 2 artifacts). This publishes to GitHub Releases
only — it does **not** push to an apt/yum package repository, which would need
its own hosting and signing-key setup.

### Local vs CI parity

CI does not fork the build logic. It only overrides three Makefile variables so
the build can use BuildKit layer caching:

```bash
make all \
  DOCKER=docker \
  DOCKER_BUILD="docker buildx build" \
  BUILD_FLAGS="--cache-from type=gha --cache-to type=gha,mode=max --load"
```

Locally these default to `DOCKER=sudo docker`, `DOCKER_BUILD=$(DOCKER) build`,
and empty `BUILD_FLAGS`, producing the identical `sudo docker build …` command —
so `make all` keeps working unchanged on a workstation. (`type=gha` cache only
works inside GitHub Actions; omit `BUILD_FLAGS` anywhere else.)

## Notes

- **Docker access:** the `Makefile` defaults to `sudo docker` because this host's
  user isn't in the `docker` group. If yours is, run `make ... DOCKER=docker`.
- **Build cost:** compiling RStudio from source (bundled boost, GWT/Java client,
  Node, Quarto, pandoc, soci, …) is heavy — expect a long first build and several
  GB of disk. Layers are ordered so the dependency layer caches between runs.
- **Package-name deltas (EL):** the upstream Fedora/RHEL dependency list needs a
  few names patched for current EL releases. `Dockerfile.build` patches them
  before running the upstream installer:
  - both EL8 + EL10: `java`→`java-21-openjdk`,
    `java-devel`→`java-21-openjdk-devel`, `postgresql-devel`→`libpq-devel`;
  - EL10 only: `zlib-devel`→`zlib-ng-compat-devel` (EL8 keeps `zlib-devel`).
- **Per-OS repo + toolchain (EL):** the build enables `crb` on EL9/EL10 and
  `powertools` on EL8. EL8's system gcc (8.5) is too old, so the build installs
  and activates **`gcc-toolset-14`** for both the bundled-dependency compile and
  the RStudio compile.
- **JDK for the GWT client:** the GWT build targets Java 17. EL8's default
  `javac` (selected by `alternatives`, pulled in via `ant`) is JDK 8, so
  `build-rpm.sh` points `JAVA_HOME` at JDK 21. Ubuntu's own dependency script
  installs `openjdk-17-jdk` directly, so this is normally a no-op there, but
  `build-deb.sh` still searches defensively for a >=17 JDK.
- **Relocatable RPM:** upstream sets `CPACK_SET_DESTDIR=ON` (mutually exclusive
  with relocation), so the stock RPM has no `Prefix`. `build-rpm.sh` switches that
  off and declares `/usr/lib/rstudio-server` as a relocatable prefix, so the RPM
  can be `rpm --relocate`'d. `test-rpm.sh` asserts this and demonstrates a
  relocated install into `/opt`.
- **DEB has no relocation, and needs none:** Debian packages have no equivalent
  of `rpm --relocate` — a `.deb` always installs to its one baked-in prefix.
  So `build-deb.sh` skips the CMakeLists.txt/postinst patching `build-rpm.sh`
  does entirely; there's nothing to work around. This also means
  `make-standalone.sh` doesn't need it either, since it only extracts the raw
  file payload and `rserver` self-locates via `/proc/self/exe` regardless of
  install prefix.
- **Ubuntu 26.04 compatibility shim:** the pinned RStudio tag's
  `dependencies/linux` tree ships named `install-dependencies-<codename>`
  scripts only through Ubuntu 24.04 ("noble") as of this writing.
  `Dockerfile.build-deb` detects the running container's actual codename via
  `/etc/os-release`, and if no matching script exists, clones
  `install-dependencies-noble` and patches its internal codename guard to
  accept the new one. This is a **best-effort shim, not an upstream-verified
  package list** — if the 26.04 build fails with a missing/renamed package,
  this is the first place to check. `UBUNTU=24.04` avoids the shim entirely.
- **R is needed at build time:** `dependencies/common/install-packages` runs R to
  install a few R packages, so the builder installs R + headers (`R-core-devel`
  on EL, `r-base-dev` on Ubuntu).
- **`libuv1-dev` for the R `fs` package (Ubuntu only):** one of the R packages
  installed at build time (`fs`, a transitive dependency of rmarkdown/testthat)
  compiles a native extension that needs libuv. Upstream's own
  `install-dependencies-<codename>` apt list does not include it, so
  `Dockerfile.build-deb` installs `libuv1-dev` explicitly alongside the other R
  build prerequisites — without it, the R package install fails with
  `Package 'libuv' not found`. EL doesn't need an equivalent fix; its own
  `install-dependencies-yum` package list already covers it.
- **R doc dir in the test image:** both EL (`tsflags=nodocs`) and the official
  Ubuntu Docker image (a dpkg `path-exclude`) strip package docs by default,
  which removes R's `/usr/share/doc/R`; `rserver` refuses to start without it.
  The EL test images install R with `tsflags=''`; the Ubuntu ones remove the
  dpkg docs-exclude before installing `r-base-core`.
- **Testing without systemd:** containers usually lack systemd, so the test
  launches `rserver` directly (`--server-daemonize=0`) and verifies it serves
  the sign-in page on port 8787, rather than using `systemctl`.
