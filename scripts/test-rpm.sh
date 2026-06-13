#!/usr/bin/env bash
#
# Smoke test for an installed RStudio Server RPM.
#
#   1. confirms the RPM is relocatable and demonstrates a relocated install
#   2. confirms R + the installed binaries are present
#   3. launches rserver directly (containers lack systemd) and checks that it
#      serves the sign-in page on port 8787
set -uo pipefail

RSERVER=/usr/lib/rstudio-server/bin/rserver
ADMIN=/usr/lib/rstudio-server/bin/rstudio-server
RPM=$(ls /tmp/rstudio-server-*.rpm | head -1)
PORT=8787

# ---------------------------------------------------------------------------
# 1. Relocatability
# ---------------------------------------------------------------------------
echo "==> Verifying the RPM is relocatable"
PREFIXES=$(rpm -qp --qf '%{PREFIXES}' "$RPM")
if [ -z "$PREFIXES" ] || [ "$PREFIXES" = "(none)" ]; then
    echo "FAIL: RPM declares no relocation prefix (not relocatable)"
    exit 1
fi
echo "    declared Prefix: $PREFIXES"

echo "==> Demonstrating relocation into /opt (isolated rpmdb root, no scripts)"
rm -rf /tmp/relocroot && mkdir -p /tmp/relocroot
rpm --root=/tmp/relocroot \
    --relocate /usr/lib/rstudio-server=/opt/rstudio \
    --nodeps --noscripts -i "$RPM"
if [ ! -x /tmp/relocroot/opt/rstudio/bin/rserver ]; then
    echo "FAIL: relocation did not place files under /opt/rstudio"
    exit 1
fi
echo "    PASS: relocated rserver at /tmp/relocroot/opt/rstudio/bin/rserver"

# ---------------------------------------------------------------------------
# 2. Normal install sanity (the RPM was installed to its default prefix by
#    Dockerfile.test)
# ---------------------------------------------------------------------------
echo "==> Verifying R is available"
which R
R --version | head -1

echo "==> Files installed by the RPM"
test -x "$RSERVER" || { echo "FAIL: rserver binary missing"; exit 1; }
test -x "$ADMIN"   || { echo "FAIL: rstudio-server admin script missing"; exit 1; }
rpm -q rstudio-server
[ -f /usr/lib/rstudio-server/VERSION ] && \
    echo "    installed VERSION: $(cat /usr/lib/rstudio-server/VERSION)"

# verify-installation drives the systemd service, which containers lack; run it
# for information but do not gate the test on it.
echo "==> Running upstream verify-installation (informational; needs systemd)"
timeout 60 "$ADMIN" verify-installation 2>&1 | sed 's/^/    /' || \
    echo "    (verify-installation returned non-zero -- expected without systemd)"

# ---------------------------------------------------------------------------
# 3. Functional check: start rserver and probe the HTTP endpoint
# ---------------------------------------------------------------------------
echo "==> Preparing runtime directories"
mkdir -p /var/run/rstudio-server /var/lib/rstudio-server /var/log/rstudio/rstudio-server

echo "==> Starting rserver in the foreground (no systemd)"
"$RSERVER" --server-daemonize=0 --www-port="$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Use a browser user-agent so RStudio serves the real sign-in page rather than
# its "unsupported browser" redirect.
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

echo "==> SUCCESS: relocatable RStudio Server RPM installs and runs."
