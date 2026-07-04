#!/usr/bin/env bash
#
# Smoke test for the standalone, NON-ROOT tarball. Runs entirely as an
# unprivileged user (see Dockerfile.standalone-test):
#
#   1. extracts the .tar.gz into $HOME (no root, no rpm)
#   2. asserts the tree + launcher landed under $HOME and nothing needs root
#   3. asserts NO systemd service was created anywhere
#   4. launches the server via run-standalone.sh and checks it serves the
#      sign-in page on port 8787
set -uo pipefail

TARBALL="$HOME/rstudio-standalone.tar.gz"
PORT=8787

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# 0. We must NOT be root -- the whole point is that this works unprivileged.
# ---------------------------------------------------------------------------
echo "==> Running as: $(id -un) (uid $(id -u))"
[ "$(id -u)" -ne 0 ] || fail "test is running as root; it must run as a normal user"
[ -f "$TARBALL" ] || fail "tarball not found at $TARBALL"

# ---------------------------------------------------------------------------
# 1. Extract into $HOME (extracting the tarball IS the install).
# ---------------------------------------------------------------------------
echo "==> Extracting the standalone tarball into $HOME"
tar -xzf "$TARBALL" -C "$HOME" || fail "tar extraction failed"
# The tarball holds a single top-level dir: rstudio-server-<ver>...
PREFIX="$(find "$HOME" -maxdepth 1 -type d -name 'rstudio-server-*' | head -1)"
[ -n "$PREFIX" ] || fail "extracted top-level rstudio-server-* directory not found"
echo "    extracted to: $PREFIX"

# ---------------------------------------------------------------------------
# 2. Sanity: files are present and under $HOME (i.e. no privileged locations).
# ---------------------------------------------------------------------------
echo "==> Verifying the extracted tree"
[ -x "$PREFIX/bin/rserver" ]        || fail "rserver missing at $PREFIX/bin/rserver"
[ -x "$PREFIX/bin/rsession" ]       || fail "rsession missing at $PREFIX/bin/rsession"
[ -x "$PREFIX/run-standalone.sh" ]  || fail "run-standalone.sh missing at $PREFIX"
case "$PREFIX" in
    "$HOME"/*) : ;;
    *) fail "prefix is not under \$HOME: $PREFIX" ;;
esac
[ -f "$PREFIX/VERSION" ] && echo "    installed VERSION: $(cat "$PREFIX/VERSION")"

# ---------------------------------------------------------------------------
# 3. Assert NO systemd service was *installed*. A payload install can't create
#    system files as a normal user; check the real systemd unit locations to be
#    explicit. (The RStudio tree itself ships inert unit *templates* under
#    extras/systemd -- those are just packaged files the postinst would have
#    used; since we never run the postinst, nothing lands in a systemd dir.)
# ---------------------------------------------------------------------------
echo "==> Verifying no systemd service was installed"
for unit in \
    /usr/lib/systemd/system/rstudio-server.service \
    /etc/systemd/system/rstudio-server.service \
    "$HOME/.config/systemd/user/rstudio-server.service"; do
    [ -e "$unit" ] && fail "unexpected systemd unit installed: $unit"
done
echo "    PASS: no rstudio-server.service in any systemd location"

# ---------------------------------------------------------------------------
# 4. Launch the server as this user (no root, no systemd) and probe HTTP.
# ---------------------------------------------------------------------------
echo "==> Verifying R is available"
command -v R >/dev/null 2>&1 || fail "no R on PATH"
R --version | head -1

echo "==> Starting the server via run-standalone.sh (foreground, backgrounded here)"
# Default prefix self-locates to $PREFIX; default auth is none on localhost.
"$PREFIX/run-standalone.sh" --port "$PORT" --address 127.0.0.1 \
    > "$HOME/run-standalone.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; pkill -P "$SERVER_PID" 2>/dev/null || true' EXIT

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
JAR="$HOME/cookies.txt"

# Probe WITHOUT following redirects (-L), so an auth redirect can never turn into
# a client-side redirect loop. We only need to confirm rserver is up and that the
# response is RStudio's. Capture the status line + headers (incl. any Location)
# and the body, with a cookie jar so a browser-like flow is preserved.
echo "==> Waiting for rserver to answer on port $PORT (redirects NOT followed)"
code=""
for _ in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "---- run-standalone.log ----"; cat "$HOME/run-standalone.log"
        fail "server exited prematurely"
    fi
    # No -f/-L: a 3xx is a valid response (exit 0); only a dead port yields 000.
    code="$(curl -sS -m 5 -A "$UA" -c "$JAR" -b "$JAR" \
        -o "$HOME/index.html" -D "$HOME/headers.txt" \
        -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != "000" ] && break
    code=""
    sleep 1
done
[ -n "$code" ] || { echo "---- run-standalone.log ----"; cat "$HOME/run-standalone.log"; fail "server did not respond on port $PORT"; }

echo "    first HTTP status: $code"
echo "    ---- response headers ----"; sed 's/^/    /' "$HOME/headers.txt"

echo "==> Checking the response is served by RStudio Server"
# Accept a positive RStudio marker in either the headers (e.g. a Location that
# points at RStudio's sign-in) or the body. A redirect to /auth-sign-in still
# proves rserver launched, bound the port, and is routing requests as non-root.
if grep -qiE 'rstudio|sign in|auth-sign-in|unsupported_browser' "$HOME/headers.txt" "$HOME/index.html"; then
    echo "PASS: RStudio Server is up and serving HTTP on port $PORT (status $code)."
else
    echo "FAIL: response does not look like RStudio (status $code)."
    echo "---- body (first 500 bytes) ----"; head -c 500 "$HOME/index.html"; echo
    echo "---- run-standalone.log ----"; cat "$HOME/run-standalone.log"
    exit 1
fi

echo "==> SUCCESS: standalone installer runs fully as a non-root user with no systemd."
