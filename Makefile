# =============================================================================
# Build RStudio Server from source, in Docker, for either Enterprise Linux
# (EL 8/10, produces an RPM) or Ubuntu Server LTS (24.04/26.04, produces a
# .deb) -- and test.
#
#   make rpm            - build the RStudio Server RPM and copy it into ./output/
#   make deb            - build the RStudio Server .deb and copy it into ./output/
#   make test           - install the RPM on a clean EL image and smoke-test it
#   make test-deb       - install the .deb on a clean Ubuntu image and smoke-test it
#   make standalone     - build a NON-ROOT install tarball (.tar.gz, no rpm/deb,
#                         no systemd) into ./output/ (works for either DISTRO)
#   make test-standalone- extract + run the standalone tarball as an unprivileged
#                         user on a clean image and smoke-test it
#   make all            - build + test BOTH the system package (rpm or deb) and
#                         the standalone tarball for the selected DISTRO (default)
#   make el10           - build + test EL 10   (alias: make all DISTRO=el EL=10)
#   make el8            - build + test EL 8    (alias: make all DISTRO=el EL=8)
#   make ubuntu26.04    - build + test Ubuntu 26.04 (alias: make all DISTRO=ubuntu UBUNTU=26.04)
#   make ubuntu24.04    - build + test Ubuntu 24.04 (alias: make all DISTRO=ubuntu UBUNTU=24.04)
#   make shell          - open a shell in the builder image (debugging)
#   make clean          - remove build artifacts and images (current DISTRO/version)
#
# Select the OS family with DISTRO (default el), and the version with EL or
# UBUNTU depending on DISTRO:
#   make all DISTRO=el     EL=8            # build + test on EL 8
#   make all DISTRO=el     EL=10           # build + test on EL 10
#   make all DISTRO=ubuntu UBUNTU=24.04    # build + test on Ubuntu 24.04 LTS
#   make all DISTRO=ubuntu UBUNTU=26.04    # build + test on Ubuntu 26.04 LTS
# Artifacts and images are kept separate per OS (output/<tag>, image tags),
# where <tag> is el8/el10/ubuntu24.04/ubuntu26.04.
#
# NOTE on Ubuntu 26.04: at the time this Makefile was written, the pinned
# RStudio tag's dependencies/linux tree ships install-dependencies scripts for
# named Ubuntu codenames up through 24.04 ("noble") only. Dockerfile.build-deb
# works around a still-unlisted 26.04 codename by cloning noble's dependency
# list (see the Dockerfile for details) -- this is a best-effort compatibility
# shim, not an upstream-verified package list. Prefer UBUNTU=24.04 if the
# 26.04 build hits a package-name error.
#
# Override the target tag/version on the command line, e.g.:
#   make rpm RSTUDIO_GIT_REF=v2026.06.0+242 \
#            RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=06 \
#            RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+242
# =============================================================================

# ---- Configuration ----------------------------------------------------------
# Which OS family to build for: "el" (Enterprise Linux -> RPM) or "ubuntu"
# (Ubuntu Server LTS -> .deb). Defaults to "el" so existing invocations
# (make all, make rpm, make el8/el10, ...) are unchanged.
DISTRO ?= el

# Target Enterprise Linux major version (8 or 10), used when DISTRO=el. The
# concrete base image is still the Rocky Linux image published for that EL
# release.
EL     ?= 10
# Target Ubuntu Server LTS version, used when DISTRO=ubuntu.
UBUNTU ?= 26.04

ifeq ($(DISTRO),ubuntu)
  BASE_IMAGE         ?= ubuntu:$(UBUNTU)
  OS_TAG             := ubuntu$(UBUNTU)
  BUILD_DOCKERFILE   := docker/Dockerfile.build-deb
  SA_TEST_DOCKERFILE := docker/Dockerfile.standalone-test-deb
  PKG_BUILD          := deb
  PKG_TEST           := test-deb
else
  BASE_IMAGE         ?= rockylinux/rockylinux:$(EL)
  OS_TAG             := el$(EL)
  BUILD_DOCKERFILE   := docker/Dockerfile.build
  SA_TEST_DOCKERFILE := docker/Dockerfile.standalone-test
  PKG_BUILD          := rpm
  PKG_TEST           := test
endif

RSTUDIO_GIT_URL        ?= https://github.com/rstudio/rstudio.git
RSTUDIO_GIT_REF        ?= v2026.06.0+242
RSTUDIO_VERSION_MAJOR  ?= 2026
RSTUDIO_VERSION_MINOR  ?= 06
RSTUDIO_VERSION_PATCH  ?= 0
RSTUDIO_VERSION_SUFFIX ?= +242

# This host's user is not in the docker group but has passwordless `sudo docker`.
# Override with `make DOCKER=docker` if your user can talk to the daemon directly.
DOCKER        ?= sudo docker
# The image build command and any extra flags are split out so CI can swap in
# `docker buildx build` + registry/gha cache flags WITHOUT changing local use.
# Locally these default to a plain `<DOCKER> build` with no extra flags, so the
# command produced is identical to before.
DOCKER_BUILD  ?= $(DOCKER) build
BUILD_FLAGS   ?=
# Image tags and output dir are namespaced per OS_TAG so el8/el10/ubuntu24.04/
# ubuntu26.04 builds never clobber each other (CPack names the package file
# identically regardless of target OS).
VER           := $(RSTUDIO_VERSION_MAJOR).$(RSTUDIO_VERSION_MINOR).$(RSTUDIO_VERSION_PATCH)
# Build number from the version suffix ("+242" -> "242").
RSTUDIO_BUILD := $(subst +,,$(RSTUDIO_VERSION_SUFFIX))
# Two different arch-naming conventions: rpm/tarball use "x86_64" (rpm --eval
# %_arch); .deb uses "amd64" (dpkg --print-architecture). Same physical arch.
ARCH          ?= x86_64
DEB_ARCH      ?= amd64
BUILD_IMAGE   ?= rstudio-server-build:$(VER)-$(OS_TAG)
TEST_IMAGE    ?= rstudio-server-test:$(VER)-$(OS_TAG)
SA_TEST_IMAGE ?= rstudio-server-standalone-test:$(VER)-$(OS_TAG)
OUTPUT_ROOT   ?= output
OUTPUT_DIR    ?= $(OUTPUT_ROOT)/$(OS_TAG)
# Canonical RPM filename: RStudio version + build, the target OS, and arch.
# e.g. rstudio-server-2026.06.0-242.el8.x86_64.rpm
RPM_FILENAME  ?= rstudio-server-$(VER)-$(RSTUDIO_BUILD).el$(EL).$(ARCH).rpm
# Canonical DEB filename, following Debian's name_version_arch.deb convention.
# e.g. rstudio-server_2026.06.0-242-ubuntu24.04_amd64.deb
DEB_FILENAME  ?= rstudio-server_$(VER)-$(RSTUDIO_BUILD)-ubuntu$(UBUNTU)_$(DEB_ARCH).deb
# Standalone tarball filename. MUST match the name make-standalone.sh derives
# inside the container (version + build + OS tag + arch), so the Makefile can
# copy exactly that file out. Uses the rpm-style ARCH regardless of DISTRO
# since the tarball is neither an rpm nor a deb. e.g.
# rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
# rstudio-server-2026.06.0-242.ubuntu24.04.x86_64-standalone.tar.gz
STANDALONE_FILENAME ?= rstudio-server-$(VER)-$(RSTUDIO_BUILD).$(OS_TAG).$(ARCH)-standalone.tar.gz

# Pass docker build args from the configuration above.
BUILD_ARGS = \
	--build-arg BASE_IMAGE=$(BASE_IMAGE) \
	--build-arg RSTUDIO_GIT_URL=$(RSTUDIO_GIT_URL) \
	--build-arg RSTUDIO_GIT_REF=$(RSTUDIO_GIT_REF) \
	--build-arg RSTUDIO_VERSION_MAJOR=$(RSTUDIO_VERSION_MAJOR) \
	--build-arg RSTUDIO_VERSION_MINOR=$(RSTUDIO_VERSION_MINOR) \
	--build-arg RSTUDIO_VERSION_PATCH=$(RSTUDIO_VERSION_PATCH) \
	--build-arg RSTUDIO_VERSION_SUFFIX=$(RSTUDIO_VERSION_SUFFIX)

.DEFAULT_GOAL := all
.PHONY: all image rpm deb test test-deb standalone test-standalone shell clean \
        el8 el10 ubuntu24.04 ubuntu26.04

# Build + test both artifacts for the selected DISTRO: the system package (rpm
# or deb) and the standalone tarball. Each phony prerequisite runs once, and
# make orders them by their own dependencies ($(PKG_TEST) -> $(PKG_BUILD);
# test-standalone -> standalone -> $(PKG_BUILD)), so the package is built once
# and reused for both.
all: $(PKG_BUILD) $(PKG_TEST) standalone test-standalone

# Convenience aliases for each supported OS.
el10:
	$(MAKE) all DISTRO=el EL=10
el8:
	$(MAKE) all DISTRO=el EL=8
ubuntu26.04:
	$(MAKE) all DISTRO=ubuntu UBUNTU=26.04
ubuntu24.04:
	$(MAKE) all DISTRO=ubuntu UBUNTU=24.04

# ---- 1. Compile RStudio Server + build the package inside the container ------
image:
	$(DOCKER_BUILD) $(BUILD_ARGS) $(BUILD_FLAGS) \
		-f $(BUILD_DOCKERFILE) \
		-t $(BUILD_IMAGE) .

# ---- 2. Extract the built RPM(s) to ./output/<tag>/ -------------------------
rpm: image
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Extracting RPM(s) from $(BUILD_IMAGE)"
	rm -f $(OUTPUT_DIR)/*.rpm
	$(DOCKER) rm -f rstudio-extract-$(OS_TAG) >/dev/null 2>&1 || true
	$(DOCKER) create --name rstudio-extract-$(OS_TAG) $(BUILD_IMAGE) >/dev/null
	$(DOCKER) cp rstudio-extract-$(OS_TAG):/output/. $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-extract-$(OS_TAG) >/dev/null
	@echo ">> Renaming RPM -> $(RPM_FILENAME)"
	@cd $(OUTPUT_DIR) && for f in rstudio-server-*.rpm; do \
		[ "$$f" = "$(RPM_FILENAME)" ] || mv -f "$$f" "$(RPM_FILENAME)"; \
	done
	@echo ">> RPM(s) available in ./$(OUTPUT_DIR):"
	@ls -l $(OUTPUT_DIR)/*.rpm

# ---- 2'. Extract the built DEB(s) to ./output/<tag>/ ------------------------
deb: image
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Extracting DEB(s) from $(BUILD_IMAGE)"
	rm -f $(OUTPUT_DIR)/*.deb
	$(DOCKER) rm -f rstudio-extract-$(OS_TAG) >/dev/null 2>&1 || true
	$(DOCKER) create --name rstudio-extract-$(OS_TAG) $(BUILD_IMAGE) >/dev/null
	$(DOCKER) cp rstudio-extract-$(OS_TAG):/output/. $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-extract-$(OS_TAG) >/dev/null
	@echo ">> Renaming DEB -> $(DEB_FILENAME)"
	@cd $(OUTPUT_DIR) && for f in rstudio-server*.deb; do \
		[ "$$f" = "$(DEB_FILENAME)" ] || mv -f "$$f" "$(DEB_FILENAME)"; \
	done
	@echo ">> DEB(s) available in ./$(OUTPUT_DIR):"
	@ls -l $(OUTPUT_DIR)/*.deb

# ---- 3. Install the RPM on a clean EL image and smoke-test it ---------------
# The test image is built from a tiny, OS-specific context (just the correct
# RPM + the test script) so it always installs the right artifact and matches
# the build OS via BASE_IMAGE.
test: rpm
	@echo ">> Building test image and running smoke test (EL $(EL))"
	rm -rf $(OUTPUT_DIR)/.ctx && mkdir -p $(OUTPUT_DIR)/.ctx
	cp $(OUTPUT_DIR)/*.rpm $(OUTPUT_DIR)/.ctx/
	cp scripts/test-rpm.sh $(OUTPUT_DIR)/.ctx/
	$(DOCKER_BUILD) $(BUILD_FLAGS) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f docker/Dockerfile.test -t $(TEST_IMAGE) $(OUTPUT_DIR)/.ctx
	rm -rf $(OUTPUT_DIR)/.ctx
	$(DOCKER) run --rm $(TEST_IMAGE)

# ---- 3'. Install the DEB on a clean Ubuntu image and smoke-test it ----------
test-deb: deb
	@echo ">> Building test image and running smoke test (Ubuntu $(UBUNTU))"
	rm -rf $(OUTPUT_DIR)/.ctx && mkdir -p $(OUTPUT_DIR)/.ctx
	cp $(OUTPUT_DIR)/*.deb $(OUTPUT_DIR)/.ctx/
	cp scripts/test-deb.sh $(OUTPUT_DIR)/.ctx/
	$(DOCKER_BUILD) $(BUILD_FLAGS) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f docker/Dockerfile.test-deb -t $(TEST_IMAGE) $(OUTPUT_DIR)/.ctx
	rm -rf $(OUTPUT_DIR)/.ctx
	$(DOCKER) run --rm $(TEST_IMAGE)

# ---- 2b. Build a standalone, non-root install tarball -----------------------
# Turns the built package's relocatable/plain file payload into a plain
# .tar.gz an ordinary user extracts and runs with NO root and NO systemd
# service. make-standalone.sh runs inside the builder image (rpm2cpio+cpio for
# EL, dpkg-deb for Ubuntu -- both ship in their respective builder image with
# no extra install), unpacks the package's file payload (which contains no
# systemd unit / postinst scriptlets), bundles the run-standalone.sh launcher
# into a single top-level dir, and emits the tarball to /output; we copy just
# that file out.
standalone: $(PKG_BUILD)
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Building standalone (non-root, no-systemd) tarball from the $(PKG_BUILD)"
	$(DOCKER) rm -f rstudio-standalone-$(OS_TAG) >/dev/null 2>&1 || true
	$(DOCKER) run --name rstudio-standalone-$(OS_TAG) $(BUILD_IMAGE) \
		/usr/local/bin/make-standalone.sh
	$(DOCKER) cp rstudio-standalone-$(OS_TAG):/output/$(STANDALONE_FILENAME) $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-standalone-$(OS_TAG) >/dev/null
	@echo ">> Standalone tarball available:"
	@ls -l $(OUTPUT_DIR)/$(STANDALONE_FILENAME)

# ---- 2c. Smoke-test the standalone tarball as an UNPRIVILEGED user -----------
# Builds a clean OS+R image with a normal (non-root) user, extracts the tarball
# and launches the server as that user, and asserts it serves the sign-in page
# with no systemd service anywhere. Proves the no-root/no-systemd contract.
# $(SA_TEST_DOCKERFILE) selects the EL- or Ubuntu-flavored variant.
test-standalone: standalone
	@echo ">> Smoke-testing the standalone tarball as a non-root user ($(OS_TAG))"
	rm -rf $(OUTPUT_DIR)/.ctx-sa && mkdir -p $(OUTPUT_DIR)/.ctx-sa
	cp $(OUTPUT_DIR)/$(STANDALONE_FILENAME) $(OUTPUT_DIR)/.ctx-sa/
	cp scripts/test-standalone.sh $(OUTPUT_DIR)/.ctx-sa/
	$(DOCKER_BUILD) $(BUILD_FLAGS) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f $(SA_TEST_DOCKERFILE) -t $(SA_TEST_IMAGE) $(OUTPUT_DIR)/.ctx-sa
	rm -rf $(OUTPUT_DIR)/.ctx-sa
	$(DOCKER) run --rm $(SA_TEST_IMAGE)

# ---- Debug: shell into the builder ------------------------------------------
shell: image
	$(DOCKER) run --rm -it $(BUILD_IMAGE) /bin/bash

# ---- Cleanup ----------------------------------------------------------------
clean:
	$(DOCKER) rm -f rstudio-extract-$(OS_TAG) rstudio-standalone-$(OS_TAG) 2>/dev/null || true
	$(DOCKER) rmi $(SA_TEST_IMAGE) $(TEST_IMAGE) $(BUILD_IMAGE) 2>/dev/null || true
	rm -rf $(OUTPUT_ROOT)
