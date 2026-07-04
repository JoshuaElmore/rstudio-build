#!/usr/bin/env bash
#
# Smoke test for an installed RStudio Server .deb.
#
#   1. confirms R + the installed binaries are present
#   2. launches rserver directly (containers lack systemd) and checks that it
#      serves the sign-in page on port 8787
#
# Unlike test-rpm.sh, there is no relocation section here: Debian packages
# have no relocation mechanism (no equivalent of `rpm --relocate`), so there is
# nothing to demonstrate -- a .deb always installs to its one baked-in prefix.
set -uo pipefail

RSERVER=/usr/lib/rstudio-server/bin/rserver
ADMIN=/usr/lib/rstudio-server/bin/rstudio-server
PORT=8787

# ---------------------------------------------------------------------------
# 1. Install sanity (the .deb was installed to its default prefix by
#    Dockerfile.test-deb)
# ---------------------------------------------------------------------------
echo "==> Verifying R is available"
which R
R --version | head -1

echo "==> Files installed by the .deb"
test -x "$RSERVER" || { echo "FAIL: rserver binary missing"; exit 1; }
test -x "$ADMIN"   || { echo "FAIL: rstudio-server admin script missing"; exit 1; }
dpkg -s rstudio-server | sed -n 's/^\(Package\|Version\|Architecture\):/    &/p'
[ -f /usr/lib/rstudio-server/VERSION ] && \
    echo "    installed VERSION: $(cat /usr/lib/rstudio-server/VERSION)"

# verify-installation drives the systemd service, which containers lack; run it
# for information but do not gate the test on it.
echo "==> Running upstream verify-installation (informational; needs systemd)"
timeout 60 "$ADMIN" verify-installation 2>&1 | sed 's/^/    /' || \
    echo "    (verify-installation returned non-zero -- expected without systemd)"

# ---------------------------------------------------------------------------
# 2. Functional check: start rserver and probe the HTTP endpoint
# ---------------------------------------------------------------------------
echo "==> Preparing runtime directories"
mkdir -p /var/run/rstudio-server /var/lib/rstudio-server /var/log/rstudio/rstudio-server

echo "==> Starting rserver in the foreground (no systemd)"
"$RSERVER" --server-daemonize=0 --www-port="$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Use a browser user-agent so RStudio serves the real sign-in page rather than
# its "unsupported browser" redirect. This is a normal system install (PAM
# auth, not --auth-none), so an unauthenticated GET returns the sign-in form
# directly (200) rather than bouncing through a redirect loop.
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

echo "==> Waiting for the HTTP endpoint on port $PORT"
ok=0
for _ in $(seq 1 30); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FAIL: rserver exited prematurely"
        exit 1
    fi
    if curl -fsS -A "$UA" -L "http://127.0.0.1:${PORT}/" -o /tmp/rstudio-index.html; then
        ok=1
        break
    fi
    sleep 1
done

if [ "$ok" -ne 1 ]; then
    echo "FAIL: server did not respond on port $PORT"
    exit 1
fi

echo "==> Checking the response is served by RStudio Server"
if grep -qiE 'rstudio|sign in|auth-sign-in|unsupported_browser' /tmp/rstudio-index.html; then
    echo "PASS: RStudio Server is up and serving HTTP on port $PORT."
else
    echo "FAIL: unexpected response body:"
    head -c 500 /tmp/rstudio-index.html
    exit 1
fi

echo "==> SUCCESS: RStudio Server .deb installs and runs."
