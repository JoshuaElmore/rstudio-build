#!/usr/bin/env bash
#
# Invoked INSIDE the build container (either EL/rpm-based or Ubuntu/deb-based).
# Turns the already-built RStudio Server package in /output into a plain,
# non-root install tarball (.tar.gz), written back to /output.
#
# Why extract the package's file payload instead of shipping the rpm/deb?
#   The package's file payload is JUST the /usr/lib/rstudio-server tree.
#   Everything that needs root -- the systemd unit, the /usr/bin symlinks, the
#   rstudio-server system user, the /etc/rstudio config dir -- is created by
#   the postinst *scriptlet*, which is NOT part of the payload. So unpacking
#   the payload (rpm2cpio|cpio for .rpm, dpkg-deb -x for .deb) gives a clean
#   userland tree with no systemd service and no root requirement, by
#   construction -- true for both package formats.
#
# The tarball contains a single top-level directory holding the RStudio tree,
# the run-standalone.sh launcher (the no-root/no-systemd runner), and a short
# INSTALL.txt. Extracting the tarball IS the install; there is no separate
# install step and nothing to run as root.
set -euxo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
RUN_STANDALONE="${RUN_STANDALONE:-/usr/local/bin/run-standalone.sh}"
[ -f "$RUN_STANDALONE" ] || { echo "make-standalone: run-standalone.sh not found: $RUN_STANDALONE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"

# ---------------------------------------------------------------------------
# 1. Unpack the package's file payload (no scriptlets, no root, no package db).
#    Whichever of .rpm/.deb is present in $OUTPUT_DIR tells us which builder
#    image this is (EL vs Ubuntu); each uses the tool native to its image, so
#    no extra package install is needed either way (rpm2cpio ships with rpm on
#    EL; dpkg-deb ships with dpkg on Ubuntu).
# ---------------------------------------------------------------------------
RPM="$(ls "$OUTPUT_DIR"/rstudio-server-*.rpm 2>/dev/null | head -1 || true)"
DEB="$(ls "$OUTPUT_DIR"/rstudio-server*.deb 2>/dev/null | head -1 || true)"
if [ -n "$RPM" ]; then
    echo "make-standalone: extracting RPM payload from $RPM"
    # rpm2cpio always streams the cpio payload to stdout, identically across
    # every rpm version -- unlike rpm2archive, whose file-vs-stdout behavior
    # changed between EL8 and EL10.
    ( cd "$STAGE" && rpm2cpio "$RPM" | cpio -idm --quiet )
elif [ -n "$DEB" ]; then
    echo "make-standalone: extracting DEB payload from $DEB"
    dpkg-deb -x "$DEB" "$STAGE"
else
    echo "make-standalone: no .rpm or .deb found in $OUTPUT_DIR" >&2
    exit 1
fi

# Locate the installed tree by finding bin/rserver, so we don't hardcode the
# prefix. RS_TREE is the dir that contains bin/, R/, resources/, ... .
RSERVER="$(find "$STAGE" -type f -path '*/bin/rserver' | head -1)"
[ -n "$RSERVER" ] || { echo "make-standalone: rserver not found in package payload" >&2; exit 1; }
RS_TREE="$(dirname "$(dirname "$RSERVER")")"
echo "make-standalone: RStudio tree at $RS_TREE"

# ---------------------------------------------------------------------------
# 2. Names. The tarball holds ONE top-level dir ($BASE) so it never tar-bombs
#    the extraction directory. $STANDALONE_FILENAME in the Makefile must match
#    "$BASE-standalone.tar.gz".
#
#    OS_TAG matches what the Makefile computes: el<major> for EL (Rocky image;
#    VERSION_ID may be e.g. "8.10", so truncate to the major version), or
#    ubuntu<version> for Ubuntu (VERSION_ID is already e.g. "24.04").
# ---------------------------------------------------------------------------
: "${RSTUDIO_VERSION_MAJOR:?}" "${RSTUDIO_VERSION_MINOR:?}" "${RSTUDIO_VERSION_PATCH:?}"
VER="${RSTUDIO_VERSION_MAJOR}.${RSTUDIO_VERSION_MINOR}.${RSTUDIO_VERSION_PATCH}${RSTUDIO_VERSION_SUFFIX:-}"
. /etc/os-release
case "$ID" in
    ubuntu) OS_TAG="ubuntu${VERSION_ID}" ;;
    *)      OS_TAG="el${VERSION_ID%%.*}" ;;
esac
ARCH="$(uname -m)"
BUILD="${RSTUDIO_VERSION_SUFFIX:-}"; BUILD="${BUILD#+}"
BASE="rstudio-server-${RSTUDIO_VERSION_MAJOR}.${RSTUDIO_VERSION_MINOR}.${RSTUDIO_VERSION_PATCH}-${BUILD}.${OS_TAG}.${ARCH}"
OUT="$OUTPUT_DIR/${BASE}-standalone.tar.gz"

# ---------------------------------------------------------------------------
# 3. Assemble the top-level dir: the RStudio tree + launcher + INSTALL note.
#    mv (not cp) since $STAGE and $WORK share a filesystem -- avoids duplicating
#    the multi-hundred-MB tree.
# ---------------------------------------------------------------------------
DIST="$WORK/$BASE"
mv "$RS_TREE" "$DIST"
install -m 0755 "$RUN_STANDALONE" "$DIST/run-standalone.sh"

cat > "$DIST/INSTALL.txt" <<EOF
RStudio Server ${VER} -- standalone, non-root.

Extract this archive anywhere you like; the extracted directory IS the install
(no root, no rpm, no systemd service):

  tar -xzf ${BASE}-standalone.tar.gz
  cd ${BASE}
  ./run-standalone.sh                    # http://127.0.0.1:8787, no auth
  ./run-standalone.sh --password 'pw'    # require a login password
  ./run-standalone.sh --help             # port, address, R path, ...

Requires an R installation on the machine (any R). Point at a specific one
with:  ./run-standalone.sh --r-bin /path/to/R
EOF

# ---------------------------------------------------------------------------
# 4. Pack the single top-level dir.
# ---------------------------------------------------------------------------
tar -C "$WORK" -czf "$OUT" "$BASE"

echo "make-standalone: wrote $OUT ($(du -h "$OUT" | cut -f1))"
