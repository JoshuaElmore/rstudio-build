# Build RStudio Server RPMs on Rocky Linux 10 (Docker)

Compiles [RStudio Server](https://github.com/rstudio/rstudio) from source —
pinned to tag **`v2026.05.0+218`** ("Golden Wattle") — inside a Rocky Linux 10
container, produces an installable **RPM**, then smoke-tests it on a clean
Rocky 10 image.

## Layout

| File | Purpose |
|------|---------|
| `Makefile` | Orchestrates everything (`build → extract → test`). |
| `docker/Dockerfile.build` | Rocky 10 builder: clones the tag, installs deps, builds the RPM. |
| `docker/Dockerfile.test` | Rocky 10 + R: installs the RPM and runs the smoke test. |
| `scripts/build-rpm.sh` | Runs `package/linux/make-package Server RPM` in the builder. |
| `scripts/test-rpm.sh` | `verify-installation`, starts `rserver`, curls the login page. |
| `output/` | Extracted `.rpm` artifacts land here. |
| `.github/workflows/build-rpm.yml` | GitHub Actions: runs the same build + test in CI and uploads the RPM. |

## Usage (local)

```bash
make rpm     # compile + build the RPM, copied to ./output/
make test    # install the RPM on a clean image and smoke-test it
make all     # rpm + test (default)
make shell   # debug shell in the builder image
make clean   # remove images and ./output
```

Build a different tag/version:

```bash
make all \
  RSTUDIO_GIT_REF=v2026.05.0+218 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=05 \
  RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+218
```

## GitHub Actions

`.github/workflows/build-rpm.yml` runs the **exact same** Makefile/Dockerfiles in
CI. Trigger it manually (**Actions → Build RStudio Server RPM → Run workflow**,
with optional tag/version inputs) or by pushing a `v*` tag. The workflow:

1. frees runner disk space (the build needs several GB),
2. `make rpm` — compiles + builds the relocatable RPM,
3. `make test` — installs it on a clean Rocky 10 image and smoke-tests it,
4. uploads the RPM as a build artifact (and attaches it to the GitHub Release on
   tag pushes).

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
- **Rocky 10 package deltas:** RHEL 10 renamed four packages the upstream
  Fedora/RHEL dependency list expects. `Dockerfile.build` patches them before
  running the upstream installer:
  `java`→`java-21-openjdk`, `java-devel`→`java-21-openjdk-devel`,
  `postgresql-devel`→`libpq-devel`, `zlib-devel`→`zlib-ng-compat-devel`.
- **Testing without systemd:** containers usually lack systemd, so the test
  launches `rserver` directly (`--server-daemonize=0`) and verifies it serves
  the sign-in page on port 8787, rather than using `systemctl`.
