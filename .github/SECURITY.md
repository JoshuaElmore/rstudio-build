# Security Policy

## Scope

This repository is a **Docker-based build harness** — it does not contain
RStudio Server source code. It clones a pinned tag of
[rstudio/rstudio](https://github.com/rstudio/rstudio) and compiles it inside
Docker (see [CLAUDE.md](../CLAUDE.md) / [README.md](../README.md)). That
splits security issues into two categories:

- **Issues in this repo's build tooling** — the `Makefile`, `docker/*`
  Dockerfiles, `scripts/*.sh`, or `.github/workflows/build.yml` (e.g. a
  supply-chain problem in how dependencies are fetched/verified, a shell
  injection in a script, secrets leaking into an image layer or CI log, or an
  unsafe default in `scripts/run-standalone.sh`) — **report those here**,
  using the process below.
- **Issues in RStudio Server itself** — a vulnerability in the compiled
  product's own code (the part that came from upstream `rstudio/rstudio`) is
  not something this repo can patch. Report those to Posit directly per
  [RStudio's own security policy](https://github.com/rstudio/rstudio/security)
  (or https://posit.co/security/ if that changes); consider also reporting
  affected pinned tags here so this harness can move `RSTUDIO_GIT_REF` to a
  fixed version once one is available.

If you're unsure which side a finding falls on, report it here — worst case
it gets pointed upstream.

### Not a vulnerability (by design)

The standalone tarball's `run-standalone.sh` runs with **no authentication**
(`--auth-none=1`) unless `--password` is passed, and binds to `127.0.0.1` by
default. This is intentional (see [INSTALL.md](../INSTALL.md)) and not
something you need to report — though a report on a case where the *default*
binds somewhere other than localhost, or the password/auth path itself is
broken, is very much in scope.

## Supported Versions

This is a build harness for a single pinned RStudio tag at a time (currently
`RSTUDIO_GIT_REF` in the [Makefile](../Makefile)), not a versioned library
with a support matrix. Only the harness on the default branch (`main`) is
maintained; older tags/branches and previously published `output/` artifacts
are not.

## Reporting a Vulnerability

Preferred: use GitHub's private reporting so details aren't public before a
fix is out — go to this repository's **Security** tab → **Report a
vulnerability** (or
https://github.com/JoshuaElmore/rstudio-build/security/advisories/new).

If that's unavailable to you, open a regular
[GitHub issue](https://github.com/JoshuaElmore/rstudio-build/issues) with as
much detail as you can share publicly, and note that further detail is
available privately on request.

Please include:

- Which file(s)/script(s)/workflow step are affected, and the pinned
  `RSTUDIO_GIT_REF` / `DISTRO`/`EL`/`UBUNTU` combination you built with, if
  relevant.
- Steps to reproduce (a `make` invocation is usually enough).
- Impact you'd expect (e.g. arbitrary code execution during the Docker build,
  a credential/secret exposure, a privilege-escalation path in the
  standalone tarball).

This is a small, personally maintained project — there's no formal SLA, but
reports will be acknowledged and looked at as soon as reasonably possible.
