# Build RStudio Server RPMs on Enterprise Linux (EL 8 / 10) with Docker

Compiles [RStudio Server](https://github.com/rstudio/rstudio) from source —
pinned to tag **`v2026.06.0+242`** — inside an Enterprise Linux (EL)
container, produces an installable, **relocatable RPM** *and* a **non-root
standalone tarball**, then smoke-tests both on a clean EL image. Builds for
**EL 8 or 10** (`EL=8` / `EL=10`).

> **New here?** See **[INSTALL.md](INSTALL.md)** for a step-by-step build +
> install guide (both the RPM and the no-root tarball).

## Layout

| File | Purpose |
|------|---------|
| `Makefile` | Orchestrates everything (`build → extract → rename → test`). |
| `docker/Dockerfile.build` | EL 8/10 builder: clones the tag, installs deps, builds the RPM. |
| `docker/Dockerfile.test` | EL 8/10 + R: installs the RPM and runs the smoke test. |
| `docker/Dockerfile.standalone-test` | EL 8/10 + R: extracts the standalone tarball **as a non-root user** and smoke-tests it. |
| `scripts/build-rpm.sh` | Activates the right toolchain/JDK, runs `package/linux/make-package Server RPM`, makes the RPM relocatable. |
| `scripts/make-standalone.sh` | Unpacks the relocatable RPM's payload and bundles it + `run-standalone.sh` into a non-root `.tar.gz`. |
| `scripts/run-standalone.sh` | Launches RStudio Server as an ordinary user — no root, no systemd (state redirected out of `/var` and `/etc`). |
| `scripts/test-rpm.sh` | Asserts relocatability, runs `verify-installation`, starts `rserver`, curls the login page. |
| `scripts/test-standalone.sh` | Extracts + runs the standalone tarball as a non-root user, asserts no systemd service, curls the login page. |
| `output/el<N>/` | Extracted, renamed `.rpm` **and `…-standalone.tar.gz`** artifacts land here (per OS). |

## Usage (local)

```bash
make rpm             # compile + build the RPM, copied to ./output/el<N>/
make test            # install the RPM on a clean image and smoke-test it
make standalone      # build a non-root install tarball (.tar.gz, no rpm/systemd)
make test-standalone # extract + run that tarball as a normal user and smoke-test it
make all             # build + test BOTH the RPM and the tarball (default)
make shell           # debug shell in the builder image
make clean           # remove the current EL's images + the entire ./output/ tree
```

## Non-root install (no rpm, no systemd)

`make standalone` produces a **plain `.tar.gz`** that an ordinary user extracts
and runs with no root, no `rpm`, and no systemd service:

```
output/el10/rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
```

It works by unpacking the relocatable RPM's *file payload* (the
`/usr/lib/rstudio-server` tree) and bundling the `run-standalone.sh` launcher
into a single top-level directory (plus a short `INSTALL.txt`). Everything that
needs root — the systemd unit, the `/usr/bin` symlinks, the `rstudio-server`
system user, `/etc/rstudio` — is created by the RPM's postinst *scriptlet*,
which is **not** part of the payload, so a payload install is root-free and
systemd-free by construction.

```bash
# On the target machine, as any normal user — extracting IS the install:
tar -xzf rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
cd rstudio-server-2026.06.0-242.el10.x86_64
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
OS's glibc, build with `EL` matching the target's EL generation (`EL=8` for
EL8 targets, `EL=10` for EL10) and a matching CPU arch (`x86_64`).

### Choosing the OS (EL 8 or 10)

`EL` selects the build/target OS (default `10`):

```bash
make all EL=10     # EL 10  (alias: make el10)
make all EL=8      # EL 8   (alias: make el8)
```

Each OS keeps its own images, output dir (`output/el8/`, `output/el10/`)
and RPM, so the two never clobber each other. On EL 8 the build automatically
uses the `powertools` repo and a `gcc-toolset` compiler (its system gcc is too
old), and keeps the EL8 package names; EL 10 uses `crb` and the EL10 names.

### RPM naming

The extracted RPM is renamed to encode the **RStudio version** and the **EL
version**:

```
output/el10/rstudio-server-2026.06.0-242.el10.x86_64.rpm
output/el8/rstudio-server-2026.06.0-242.el8.x86_64.rpm
                          └──── version ────┘ └OS┘ └arch┘
```

### Build a different tag/version

```bash
make all \
  RSTUDIO_GIT_REF=v2026.06.0+242 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=06 \
  RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+242
```

## GitHub Actions

`.github/workflows/build-rpm.yml` runs the **exact same** Makefile/Dockerfiles in
CI, as a matrix over **EL 8 and EL 10** (one parallel job each). Trigger it
manually (**Actions → Build RStudio Server RPM → Run workflow**, with optional
tag/version inputs) or by pushing a `v*` tag. Each matrix leg:

1. frees runner disk space (the build needs several GB),
2. `make rpm EL=<8|10>` — compiles + builds the relocatable RPM,
3. `make test EL=<8|10>` — installs it on a clean EL image and smoke-tests it,
4. uploads the RPM as a per-OS build artifact (and attaches it to the GitHub
   Release on tag pushes).

The two legs use separate GHA cache scopes (`el8` / `el10`) so they don't
evict each other.

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
- **Package-name deltas:** the upstream Fedora/RHEL dependency list needs a few
  names patched for current EL releases. `Dockerfile.build` patches them before
  running the upstream installer:
  - both EL8 + EL10: `java`→`java-21-openjdk`,
    `java-devel`→`java-21-openjdk-devel`, `postgresql-devel`→`libpq-devel`;
  - EL10 only: `zlib-devel`→`zlib-ng-compat-devel` (EL8 keeps `zlib-devel`).
- **Per-OS repo + toolchain:** the build enables `crb` on EL9/EL10 and
  `powertools` on EL8. EL8's system gcc (8.5) is too old, so the build installs
  and activates **`gcc-toolset-14`** for both the bundled-dependency compile and
  the RStudio compile.
- **JDK for the GWT client:** the GWT build targets Java 17, but EL8's default
  `javac` (selected by `alternatives`, pulled in via `ant`) is JDK 8.
  `build-rpm.sh` points `JAVA_HOME` at JDK 21 so the client compiles on both OSes.
- **Relocatable RPM:** upstream sets `CPACK_SET_DESTDIR=ON` (mutually exclusive
  with relocation), so the stock RPM has no `Prefix`. `build-rpm.sh` switches that
  off and declares `/usr/lib/rstudio-server` as a relocatable prefix, so the RPM
  can be `rpm --relocate`'d. `test-rpm.sh` asserts this and demonstrates a
  relocated install into `/opt`.
- **R is needed at build time:** `dependencies/common/install-packages` runs R to
  install a few R packages, so the builder installs R + headers.
- **R doc dir in the test image:** EL containers set `tsflags=nodocs`, which
  strips R's `/usr/share/doc/R`; `rserver` refuses to start without it, so the
  test image installs R with `tsflags=''`.
- **Testing without systemd:** containers usually lack systemd, so the test
  launches `rserver` directly (`--server-daemonize=0`) and verifies it serves
  the sign-in page on port 8787, rather than using `systemctl`.
```
