#!/usr/bin/env bash
#
# Invoked inside the build container from /src/rstudio/package/linux.
# Drives the upstream make-package script to produce an RStudio Server .deb.
#
# Unlike build-rpm.sh, this script does NOT patch CMakeLists.txt/postinst for
# relocatability: Debian packages have no relocation mechanism (no equivalent
# of `rpm --relocate`), so upstream's default CPACK_SET_DESTDIR=ON / baked-in
# CMAKE_INSTALL_PREFIX is exactly what a normal .deb install needs -- there is
# nothing to work around. The standalone tarball path also doesn't need it:
# it extracts the package's raw file payload (never runs the postinst), and
# rserver itself self-locates its resources from /proc/self/exe regardless of
# install prefix.
set -euxo pipefail

cd "$(dirname "$0")" 2>/dev/null || true
cd /src/rstudio/package/linux

# Ubuntu 24.04/26.04 ship a modern system gcc (13+) that's new enough to build
# RStudio directly -- unlike EL8, no gcc-toolset activation is needed here.
echo "Using compiler: $(command -v g++) -> $(g++ --version | head -1)"

# The GWT client is compiled with javac targeting release 17. Point the build
# at a modern JDK (>= 17) if the default `javac` isn't one; install-dependencies
# for Ubuntu installs openjdk-17-jdk itself, so this is normally a no-op, but we
# still search explicitly for robustness (mirrors build-rpm.sh).
for jdk in /usr/lib/jvm/java-21-openjdk-* /usr/lib/jvm/java-17-openjdk-amd64 \
           /usr/lib/jvm/java-17-openjdk-* /usr/lib/jvm/java-21-openjdk; do
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

# Build the Server target as a DEB. "clean" forces a fresh build tree.
./make-package Server DEB clean

echo "make-package finished. DEB artifacts:"
find /src/rstudio/package/linux -name '*.deb' -print
