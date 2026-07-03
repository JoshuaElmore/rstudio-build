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

# ---------------------------------------------------------------------------
# Make the relocation actually usable at runtime.
#
# CPack relocation only rewrites packaged *file paths*. It does NOT touch the
# contents of the post-install scriptlet, the systemd unit's ExecStart, or the
# rstudio-server admin wrapper -- all of which bake in the build-time install
# prefix (/usr/lib/rstudio-server) via @CMAKE_INSTALL_PREFIX@. So a
# `rpm -i --prefix /somewhere/else` install relocates the files but every
# script keeps looking under /usr/lib/rstudio-server and fails with
# "No such file or directory".
#
# rpm exports the chosen relocation prefix to scriptlets as $RPM_INSTALL_PREFIX0.
# Patch the packaging sources so the three prefix-sensitive pieces honor it:
#   * postinst scriptlet -> resolve a runtime $PREFIX and use it everywhere,
#                           and rewrite the copied systemd unit's ExecStart.
#   * admin wrapper       -> locate rserver relative to its own path (works
#                           under any prefix, even a read-only one).
# The rserver binary itself self-locates its resources from /proc/self/exe, so
# no patch is needed there.
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import sys

def patch(path, transform):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    out = transform(src)
    if out == src:
        sys.exit(f"relocation patch: nothing changed in {path} (upstream layout changed?)")
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    print("relocation patch: patched", path)

POST  = "/src/rstudio/package/linux/rpm-script/postinst.sh.in"
ADMIN = "/src/rstudio/src/cpp/server/extras/admin/rstudio-server.in"

def fix_post(s):
    if "${CMAKE_INSTALL_PREFIX}" not in s and "@CMAKE_INSTALL_PREFIX@" not in s:
        sys.exit("postinst: install-prefix placeholder not found")
    # Route every prefix reference through a runtime $PREFIX shell variable.
    s = s.replace("${CMAKE_INSTALL_PREFIX}", "$PREFIX").replace("@CMAKE_INSTALL_PREFIX@", "$PREFIX")
    # Define $PREFIX = rpm relocation prefix, else the build-time default.
    # $${EMPTY}{...} survives CMake configure_file (EMPTY is an empty cmake
    # variable already used by this scriptlet); @CMAKE_INSTALL_PREFIX@ is
    # substituted with the default prefix.
    block = (
        "\n# Honor an rpm --prefix relocation (exported as RPM_INSTALL_PREFIX0);\n"
        "# otherwise fall back to the build-time install prefix.\n"
        'PREFIX="$${EMPTY}{RPM_INSTALL_PREFIX0:-@CMAKE_INSTALL_PREFIX@}"\n'
    )
    if "set +e\n" not in s:
        sys.exit("postinst: 'set +e' anchor not found")
    s = s.replace("set +e\n", "set +e\n" + block, 1)
    # The packaged systemd unit still has the build-time prefix baked into
    # ExecStart -- rewrite it to $PREFIX right after it is copied into place.
    lines = s.split("\n")
    for i, ln in enumerate(lines):
        if "extras/systemd/rstudio-server.redhat.service" in ln and ln.lstrip().startswith("cp "):
            indent = ln[:len(ln) - len(ln.lstrip())]
            lines.insert(i + 1, indent + 'sed -i "s|@CMAKE_INSTALL_PREFIX@|$PREFIX|g" $${EMPTY}{SYSTEMD_PREFIX}/system/rstudio-server.service')
            break
    else:
        sys.exit("postinst: systemd unit copy line not found")
    return "\n".join(lines)

def fix_admin(s):
    # Resolve rserver relative to this wrapper's own location instead of the
    # baked-in prefix, so it works wherever the package is relocated to.
    self_rserver = '$(dirname "$(readlink -f "$0")")/rserver'
    for needle in ("@CMAKE_INSTALL_PREFIX@/bin/rserver", "${CMAKE_INSTALL_PREFIX}/bin/rserver"):
        s = s.replace(needle, self_rserver)
    if "CMAKE_INSTALL_PREFIX" in s:
        sys.exit("admin wrapper: unexpected leftover CMAKE_INSTALL_PREFIX reference")
    return s

patch(POST, fix_post)
patch(ADMIN, fix_admin)
PYEOF

# Build the Server target as an RPM. "clean" forces a fresh build tree.
./make-package Server RPM clean

echo "make-package finished. RPM artifacts:"
find /src/rstudio/package/linux -name '*.rpm' -print
