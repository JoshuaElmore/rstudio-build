# Building and Installing RStudio Server

This repo builds [RStudio Server](https://github.com/rstudio/rstudio) from source
inside Docker and produces **two** artifacts you can install:

| Artifact | Install as | Needs root? | Needs systemd? | Best for |
|----------|-----------|:-----------:|:--------------:|----------|
| **RPM** (`.rpm`) | system package (`dnf`/`rpm`) | yes | yes (service) | a normal system-wide server |
| **Standalone tarball** (`.tar.gz`) | extract into a directory you own | **no** | **no** | shared boxes, HPC login nodes, no-root/no-Docker targets |

The **build machine needs Docker**; the **target machine does not** — for the
standalone tarball the target needs only a shell, `tar`, and an R install.

---

## 1. Prerequisites (build machine)

- Docker (the `Makefile` calls `sudo docker` by default — see below).
- GNU `make`, and a POSIX shell.
- Several GB of free disk and a good while for the first build: RStudio compiles
  bundled boost, the GWT/Java client, Node, Quarto, pandoc, soci, … from source.

If your user is in the `docker` group, skip `sudo`:

```bash
make ... DOCKER=docker
```

---

## 2. Choose the target OS

`EL` selects the build **and** target OS generation (default `10`). Build with
the value that matches where you'll install, because the binaries link the build
OS's glibc:

| Target OS family | Build with |
|------------------|------------|
| Enterprise Linux **8** (RHEL / AlmaLinux / Oracle / …) | `EL=8` |
| Enterprise Linux **10** (RHEL / AlmaLinux / Oracle / …) | `EL=10` |

A newer-glibc build will not start on an older target (an EL10 build won't run on
EL8). When in doubt, build on the **oldest** generation you need to support. The
CPU arch must also match (`x86_64`). Each OS keeps its own images and output dir
(`output/el8/`, `output/el10/`).

---

## 3. Build

```bash
make rpm             # -> output/el<N>/rstudio-server-<ver>.<el>.<arch>.rpm
make standalone      # -> output/el<N>/rstudio-server-<ver>.<el>.<arch>-standalone.tar.gz
make all             # build + smoke-test BOTH (default target)
```

Handy aliases and helpers:

```bash
make el8             # = make all EL=8
make el10            # = make all EL=10
make test            # install the RPM on a clean image and smoke-test it
make test-standalone # extract + run the tarball as a non-root user and smoke-test it
make shell           # debug shell in the builder image
make clean           # remove this EL's images + the whole ./output/ tree
```

Build a different tag/version by overriding the version variables:

```bash
make all \
  RSTUDIO_GIT_REF=v2026.06.0+242 \
  RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=06 \
  RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+242
```

The artifacts land in `output/el<N>/`, e.g.:

```
output/el10/rstudio-server-2026.06.0-242.el10.x86_64.rpm
output/el10/rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
```

---

## 4. Install — standalone tarball (no root, no systemd)

Copy the one `.tar.gz` to any compatible machine (no Docker or rpm needed there)
and extract it. **Extracting is the install.**

```bash
# On the target machine, as any normal user:
tar -xzf rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
cd rstudio-server-2026.06.0-242.el10.x86_64

./run-standalone.sh                       # http://127.0.0.1:8787, no auth (localhost)
./run-standalone.sh --password 'secret'   # require logging in as you with a password
./run-standalone.sh --help                # all options
```

The server runs in the **foreground** — stop it with `Ctrl-C`. It runs single-user
as *you*, with all writable state redirected under
`~/.local/share/rstudio-standalone` instead of the root-owned `/var` and
`/etc/rstudio` a system install uses. Nothing here needs root or systemd. This is
the same approach [Open OnDemand](https://osc.github.io/ood-documentation/) uses.

**Database:** RStudio Server requires a metadata database. `run-standalone.sh`
configures it to use a private **SQLite** database under the work dir
(`~/.local/share/rstudio-standalone/db`), so there is **no PostgreSQL server to
install or run** — but the host must provide the SQLite client library
(`libsqlite3.so.0`, from the `sqlite-libs` package). It's present on essentially
every Linux; a system RPM install would pull it in automatically, whereas the
tarball relies on it already being there (see requirements below).

Common options for `run-standalone.sh`:

| Option | Meaning | Default |
|--------|---------|---------|
| `-P, --port N` | TCP port to listen on | `8787` |
| `-a, --address ADDR` | Bind address (`0.0.0.0` for LAN — see warning) | `127.0.0.1` |
| `-R, --r-bin PATH` | R executable / R home / bin dir to use | first `R` on `$PATH` |
| `--password PW` | Require login as the current user with password `PW` | (none → auth disabled) |
| `-p, --prefix DIR` | RStudio install prefix (`bin/rserver`) | the extracted dir |
| `-w, --work DIR` | Writable state directory | `~/.local/share/rstudio-standalone` |

> **Security:** with no `--password`, authentication is disabled — anyone who can
> reach the port gets a session as you. Keep the default `127.0.0.1` binding, or
> set `--password` before binding a routable address.

### Requirements on the target

- A shell, `tar`, `gzip`, coreutils — present on any Linux.
- **R** must be installed (any version). If `R` isn't on `$PATH`, point at it:
  `./run-standalone.sh --r-bin /opt/R/4.4.1/bin/R`.
- **SQLite** client library (`libsqlite3.so.0` / `sqlite-libs`) — the standalone
  server uses a private SQLite database, so this must be present (install with
  `dnf install sqlite-libs` if it isn't). No database *server* is needed.
- Standard system shared libraries (glibc, libstdc++, openssl, libpam, zlib, …).
  RStudio's heavy dependencies are bundled inside the tree, but system libs are
  not — they're present on any normal workstation or HPC node. If `rserver` fails
  with a `cannot open shared object` error, that library is missing from the host.

---

## 5. Install — RPM (system-wide, root + systemd)

On a target of the matching OS, install the package as root; `dnf` resolves the
runtime dependencies (including R):

```bash
sudo dnf install ./rstudio-server-2026.06.0-242.el10.x86_64.rpm
sudo systemctl enable --now rstudio-server
```

Then browse to `http://<host>:8787` and sign in with a real system account (the
RPM uses PAM, so users must exist on the box). Configuration lives in
`/etc/rstudio`; the service is `rstudio-server.service`.

### Relocatable install

This RPM is built **relocatable** (upstream's is not — see the README for how).
Install the tree somewhere other than `/usr/lib/rstudio-server`:

```bash
sudo rpm -i --prefix /opt/rstudio ./rstudio-server-2026.06.0-242.el10.x86_64.rpm
```

The postinst, the systemd unit's `ExecStart`, and the admin wrapper all honor the
chosen prefix, so a relocated install starts normally.

---

## 6. Distributing to machines without Docker

Only the build box needs Docker. For no-Docker targets:

1. On the build box: `make standalone EL=<8|10>` (match the target's OS family).
2. Copy the single `output/el<N>/…-standalone.tar.gz` to the target (`scp`,
   shared filesystem, artifact store, …).
3. On the target: extract and run `run-standalone.sh` as above.

No root, no rpm database, no systemd, and no Docker are involved on the target.

---

## Troubleshooting

- **`rserver` exits immediately / `cannot open shared object file`** — a required
  system library is missing on the target. Run `ldd bin/rserver` and install the
  package providing the missing `.so`. A common one is `libsqlite3.so.0` — install
  `sqlite-libs` (the standalone server uses a private SQLite database).
- **Database errors on startup** — ensure `sqlite-libs` is installed and the work
  dir (`~/.local/share/rstudio-standalone`) is writable; the SQLite file lives
  under its `db/` subdirectory.
- **`No such file or directory` for R / wrong R** — pass `--r-bin` explicitly.
- **Won't start on an older OS** — you built on a newer OS generation; rebuild with
  the `EL` value that matches (or is older than) the target.
- **Port already in use** — pick another with `--port`.
- **First build is very slow / large** — expected; it compiles everything from
  source. Layers are ordered so the heavy dependency layer caches between runs.
