#!/usr/bin/env bash
#
# Invoked inside the build container from /src/rstudio/package/linux.
# Drives the upstream make-package script to produce an RStudio Server RPM.
set -euxo pipefail

cd "$(dirname "$0")" 2>/dev/null || true
cd /src/rstudio/package/linux

# Version components are read by make-package from the environment.
: "${RSTUDIO_VERSION_MAJOR:?}"
: "${RSTUDIO_VERSION_MINOR:?}"
: "${RSTUDIO_VERSION_PATCH:?}"
export RSTUDIO_VERSION_SUFFIX="${RSTUDIO_VERSION_SUFFIX:-}"

echo "Building RStudio Server ${RSTUDIO_VERSION_MAJOR}.${RSTUDIO_VERSION_MINOR}.${RSTUDIO_VERSION_PATCH}${RSTUDIO_VERSION_SUFFIX}"

# ---------------------------------------------------------------------------
# Make the RPM relocatable.
#
# Upstream sets CPACK_SET_DESTDIR=ON, which CPack treats as mutually exclusive
# with relocation -> the stock RPM ships with no Prefix tag (not relocatable).
# Every packaged file lives under ${CMAKE_INSTALL_PREFIX} (/usr/lib/rstudio-
# server); the /etc, systemd unit and /usr/bin symlinks are created by the
# post-install script, not packaged. So a single relocation prefix is enough.
#
# Switch DESTDIR off and declare the install prefix as a relocatable Prefix.
# (Verified: file list and count are unchanged, all files stay under the
# prefix, and the resulting RPM reports PREFIXES=/usr/lib/rstudio-server.)
# ---------------------------------------------------------------------------
CML=/src/rstudio/package/linux/CMakeLists.txt
if ! grep -q "CPACK_RPM_PACKAGE_RELOCATABLE" "$CML"; then
    sed -i 's#set(CPACK_SET_DESTDIR "ON")#set(CPACK_SET_DESTDIR "OFF")\nset(CPACK_PACKAGING_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")\nset(CPACK_RPM_PACKAGE_RELOCATABLE "TRUE")#' "$CML"
fi
grep -nE 'CPACK_SET_DESTDIR|CPACK_PACKAGING_INSTALL_PREFIX|CPACK_RPM_PACKAGE_RELOCATABLE' "$CML"

# Build the Server target as an RPM. "clean" forces a fresh build tree.
./make-package Server RPM clean

echo "make-package finished. RPM artifacts:"
find /src/rstudio/package/linux -name '*.rpm' -print
