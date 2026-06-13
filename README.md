# Build RStudio Server RPMs on Rocky Linux 8 / 10 (Docker)

Compiles [RStudio Server](https://github.com/rstudio/rstudio) from source —
pinned to tag **`v2026.05.0+218`** ("Golden Wattle") — inside a Rocky Linux
container, produces an installable, **relocatable RPM**, then smoke-tests it on a
clean Rocky image. Builds for **Rocky Linux 8 or 10** (`ROCKY=8` / `ROCKY=10`).

## Layout

| File | Purpose |
|------|---------|
| `Makefile` | Orchestrates everything (`build → extract → rename → test`). |
| `docker/Dockerfile.build` | Rocky 8/10 builder: clones the tag, installs deps, builds the RPM. |
| `docker/Dockerfile.test` | Rocky 8/10 + R: installs the RPM and runs the smoke test. |
| `scripts/build-rpm.sh` | Activates the right toolchain/JDK, runs `package/linux/make-package Server RPM`, makes the RPM relocatable. |
| `scripts/test-rpm.sh` | Asserts relocatability, runs `verify-installation`, starts `rserver`, curls the login page. |
| `output/rocky<N>/` | Extracted, renamed `.rpm` artifacts land here (per OS). |
| `.github/workflows/build-rpm.yml` | GitHub Actions: runs the same build + test in CI (Rocky 8 & 10) and uploads the RPMs. |

## Usage (local)

```bash
make rpm     # compile + build the RPM, copied to ./output/rocky<N>/
make test    # install the RPM on a clean image and smoke-test it
make all     # rpm + test (default)
make shell   # debug shell in the builder image
make clean   # remove the current ROCKY's images + the entire ./output/ tree
```

### Choosing the OS (Rocky 8 or 10)

`ROCKY` selects the build/target OS (default `10`):

```bash
make all ROCKY=10     # Rocky Linux 10  (alias: make rocky10)
make all ROCKY=8      # Rocky Linux 8   (alias: make rocky8)
```

Each OS keeps its own images, output dir (`output/rocky8/`, `output/rocky10/`)
and RPM, so the two never clobber each other. On Rocky 8 the build automatically
uses the `powertools` repo and a `gcc-toolset` compiler (its system gcc is too
old), and keeps the EL8 package names; Rocky 10 uses `crb` and the EL10 names.

### RPM naming

The extracted RPM is renamed to encode the **RStudio version** and the **Linux
version**:

```
output/rocky10/rstudio-server-2026.05.0-218.el10.x86_64.rpm
output/rocky8/rstudio-server-2026.05.0-218.el8.x86_64.rpm
                            └──── version ────┘ └OS┘ └arch┘
```

### Build a different tag/version

```bash
make all \
  RSTUDIO_GIT_REF=v2026.05.0+218 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=05 \
  RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+218
```

## GitHub Actions

`.github/workflows/build-rpm.yml` runs the **exact same** Makefile/Dockerfiles in
CI, as a matrix over **Rocky 8 and Rocky 10** (one parallel job each). Trigger it
manually (**Actions → Build RStudio Server RPM → Run workflow**, with optional
tag/version inputs) or by pushing a `v*` tag. Each matrix leg:

1. frees runner disk space (the build needs several GB),
2. `make rpm ROCKY=<8|10>` — compiles + builds the relocatable RPM,
3. `make test ROCKY=<8|10>` — installs it on a clean Rocky image and smoke-tests it,
4. uploads the RPM as a per-OS build artifact (and attaches it to the GitHub
   Release on tag pushes).

The two legs use separate GHA cache scopes (`rocky8` / `rocky10`) so they don't
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
  names patched for current Rocky releases. `Dockerfile.build` patches them before
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
- **R doc dir in the test image:** Rocky containers set `tsflags=nodocs`, which
  strips R's `/usr/share/doc/R`; `rserver` refuses to start without it, so the
  test image installs R with `tsflags=''`.
- **Testing without systemd:** containers usually lack systemd, so the test
  launches `rserver` directly (`--server-daemonize=0`) and verifies it serves
  the sign-in page on port 8787, rather than using `systemctl`.
