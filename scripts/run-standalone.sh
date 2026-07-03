#!/usr/bin/env bash
#
# run-standalone.sh -- launch RStudio Server as an ordinary, unprivileged user,
# with no root and no systemd service. Everything a normal system install keeps
# in root-owned locations (/var/run, /var/lib, /etc/rstudio) is redirected to a
# per-user working directory instead.
#
# This is the same approach Open OnDemand's bc_osc_rstudio_server uses:
#   * --server-user=$(whoami)     run single-user; never try to setuid as root
#   * --server-data-dir / etc.    point writable state at $HOME instead of /var
#   * RSTUDIO_CONFIG_DIR          make rserver read config + secure key files
#                                 from a writable dir, not /etc/rstudio and the
#                                 root-owned /var/lib/rstudio-server
#   * a private sqlite database    instead of the root-owned default
#   * --auth-none, or a tiny PAM   helper checking one password (no real PAM/root)
#   * (optional) bubblewrap to     bind a user dir over /etc/rstudio
#
# Usage:
#   run-standalone.sh [options]
#
# Options:
#   -p, --prefix DIR    RStudio install prefix (contains bin/rserver).
#                       Default: $RSTUDIO_PREFIX or /home/joshua/rstudio
#   -P, --port N        TCP port to listen on (default: 8787)
#   -a, --address ADDR  Address to bind (default: 127.0.0.1; use 0.0.0.0 for LAN)
#   -w, --work DIR      Writable state dir (default: ~/.local/share/rstudio-standalone)
#       --password PW   Require login as the current user with password PW.
#                       Omit to run with NO authentication (localhost only!).
#       --bwrap         Force bind-mounting the work dir over /etc/rstudio using
#                       bubblewrap (auto-enabled if /etc/rstudio is unreadable).
#   -h, --help          Show this help.
#
# Stop the server with Ctrl-C (it runs in the foreground).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
PREFIX="${RSTUDIO_PREFIX:-/home/joshua/rstudio}"
PORT=8787
ADDRESS=127.0.0.1
WORK="${XDG_DATA_HOME:-$HOME/.local/share}/rstudio-standalone"
PASSWORD=""
USE_BWRAP=0

die() { echo "run-standalone: $*" >&2; exit 1; }

show_help() { sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--prefix)   PREFIX="${2:?}"; shift 2;;
        -P|--port)     PORT="${2:?}"; shift 2;;
        -a|--address)  ADDRESS="${2:?}"; shift 2;;
        -w|--work)     WORK="${2:?}"; shift 2;;
        --password)    PASSWORD="${2:?}"; shift 2;;
        --bwrap)       USE_BWRAP=1; shift;;
        -h|--help)     show_help; exit 0;;
        *)             die "unknown option: $1 (try --help)";;
    esac
done

RSERVER="$PREFIX/bin/rserver"
RSESSION="$PREFIX/bin/rsession"
[ -x "$RSERVER" ]  || die "rserver not found or not executable at: $RSERVER
Pass the right install location with --prefix DIR."

# ---------------------------------------------------------------------------
# Build the per-user state directory
# ---------------------------------------------------------------------------
mkdir -p "$WORK"/{run,db,logs,etc}
chmod 700 "$WORK"

# Make rserver read its "system" config and secure key files from our writable
# dir instead of /etc/rstudio and the root-owned /var/lib/rstudio-server. This
# is what avoids EACCES on the session-rpc-key / secure-cookie-key files a
# previous root or systemd start may have created under /var/lib.
export RSTUDIO_CONFIG_DIR="$WORK/etc"

# generate a 0600 secret file only if it is missing
gen_secret() {
    if [ ! -s "$1" ]; then
        if command -v uuidgen >/dev/null 2>&1; then
            uuidgen > "$1"
        else
            head -c 32 /dev/urandom | base64 > "$1"
        fi
    fi
    chmod 600 "$1"
}

# sqlite database config (the default lives under root-owned /var/lib)
cat > "$WORK/database.conf" <<EOF
provider=sqlite
directory=$WORK/db
EOF
chmod 600 "$WORK/database.conf"

# Secure keys. The cookie key is passed explicitly below; the RPC key must be
# pre-seeded in RSTUDIO_CONFIG_DIR so rserver finds it there (step 1 of its
# lookup) rather than falling through to the unreadable /var/lib copy.
COOKIE_KEY="$WORK/secure-cookie-key"
gen_secret "$COOKIE_KEY"

# Seed the RPC key in RSTUDIO_CONFIG_DIR. rserver uses the env var directly (no
# "rstudio" suffix), but seed a rstudio/ subdir too so we win regardless.
mkdir -p "$WORK/etc/rstudio"
RPC_SECRET="$(cat "$COOKIE_KEY")"   # reuse a value; any stable secret works
for d in "$WORK/etc" "$WORK/etc/rstudio"; do
    if [ ! -s "$d/session-rpc-key" ]; then
        printf '%s' "$RPC_SECRET" > "$d/session-rpc-key"
    fi
    chmod 600 "$d/session-rpc-key"
done

# ---------------------------------------------------------------------------
# Assemble the rserver command line
# ---------------------------------------------------------------------------
ME="$(id -un)"
ARGS=(
    --server-user="$ME"
    --server-daemonize=0
    --server-data-dir="$WORK/run"
    --server-pid-file="$WORK/run/rstudio-server.pid"
    --www-address="$ADDRESS"
    --www-port="$PORT"
    --database-config-file="$WORK/database.conf"
    --secure-cookie-key-file="$COOKIE_KEY"
)

# Point rserver at this install's rsession and R (helps when they are not on PATH
# or when R comes from a conda/module environment).
[ -x "$RSESSION" ] && ARGS+=( --rsession-path="$RSESSION" )
if R_BIN="$(command -v R 2>/dev/null)"; then
    ARGS+=( --rsession-which-r="$R_BIN" )
fi

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
if [ -n "$PASSWORD" ]; then
    # Real login page, backed by a tiny helper (no root / no PAM needed).
    # rserver runs the helper with the username as $1 and the password on stdin.
    PW_FILE="$WORK/.auth-password"
    printf '%s' "$PASSWORD" > "$PW_FILE"
    chmod 600 "$PW_FILE"

    AUTH_HELPER="$WORK/auth-helper.sh"
    cat > "$AUTH_HELPER" <<EOF
#!/usr/bin/env bash
# RStudio auth-pam-helper: username in \$1, password on stdin.
IFS= read -r _pw
[ "\$1" = "$ME" ] && [ "\$_pw" = "\$(cat "$PW_FILE")" ]
EOF
    chmod 700 "$AUTH_HELPER"

    ARGS+=(
        --auth-none=0
        --auth-pam-helper-path="$AUTH_HELPER"
        --auth-encrypt-password=0
    )
    AUTH_MSG="log in as '$ME' with the password you supplied"
else
    # No authentication: whoever reaches the port is you. Localhost only!
    ARGS+=( --auth-none=1 )
    AUTH_MSG="no login required (auth disabled)"
    if [ "$ADDRESS" != "127.0.0.1" ] && [ "$ADDRESS" != "localhost" ]; then
        echo "run-standalone: WARNING: auth is disabled but you are binding" >&2
        echo "                $ADDRESS (not localhost). Anyone who can reach" >&2
        echo "                port $PORT gets a session as $ME. Use --password." >&2
    fi
fi

# ---------------------------------------------------------------------------
# /etc/rstudio handling
#
# RSTUDIO_CONFIG_DIR (set above) already redirects config + key lookups to our
# writable dir, so this is not normally needed. --bwrap is offered only for the
# rare case where something still hardcodes the literal /etc/rstudio path: it
# bind-mounts our dir there using unprivileged user namespaces.
# ---------------------------------------------------------------------------
WRAPPER=()
if [ "$USE_BWRAP" -eq 1 ]; then
    command -v bwrap >/dev/null 2>&1 || die "bwrap requested but not installed (install bubblewrap)."
    : > "$WORK/etc/rserver.conf"
    WRAPPER=( bwrap --dev-bind / / --bind "$WORK/etc" /etc/rstudio )
    echo "run-standalone: overlaying $WORK/etc onto /etc/rstudio via bwrap"
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
URL_HOST="$ADDRESS"; [ "$ADDRESS" = "0.0.0.0" ] && URL_HOST="$(hostname -f 2>/dev/null || hostname)"
cat <<EOF

  RStudio Server (standalone, no root / no systemd)
  -------------------------------------------------
  prefix : $PREFIX
  work   : $WORK
  user   : $ME
  auth   : $AUTH_MSG
  URL    : http://$URL_HOST:$PORT

  Running in the foreground -- press Ctrl-C to stop.

EOF

exec "${WRAPPER[@]}" "$RSERVER" "${ARGS[@]}"