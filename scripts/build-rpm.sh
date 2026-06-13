#!/usr/bin/env bash
#
# Invoked inside the build container from /src/rstudio/package/linux.
# Drives the upstream make-package script to produce an RStudio Server RPM.
set -euxo pipefail

cd "$(dirname "$0")" 2>/dev/null || true
cd /src/rstudio/package/linux

# On EL8 the build must use the newer gcc-toolset compiler (the system gcc 8.5
# is too old). The enable script only exists where a toolset was installed
# (EL8); on EL9/EL10 this is a no-op. Disable `-u` while sourcing it since the
# script references some unset variables.
set +u
for ts in /opt/rh/gcc-toolset-*/enable; do
    [ -f "$ts" ] && { . "$ts"; echo "Activated $(dirname "$ts")"; break; }
done
set -u
echo "Using compiler: $(command -v g++) -> $(g++ --version | head -1)"

# The GWT client is compiled with javac targeting release 17. On EL8 the default
# javac (selected by `alternatives`, and pulled in via ant) is JDK 8, which
# rejects `-target 17`. Point the build at a modern JDK (>= 17). The
# java-21-openjdk-devel package is installed on every supported OS.
for jdk in /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-21-openjdk-* \
           /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-17-openjdk-*; do
    if [ -x "$jdk/bin/javac" ]; then
        export JAVA_HOME="$jdk"
        export PATH="$jdk/bin:$PATH"
        break
    fi
done
echo "Using JAVA_HOME=${JAVA_HOME:-<unset>}; javac: $(javac -version 2>&1)"

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
