# =============================================================================
# Build RStudio Server RPMs from source on Enterprise Linux (EL 8 or 10), in
# Docker, and test.
#
#   make rpm            - build the RStudio Server RPM and copy it into ./output/
#   make test           - install the RPM on a clean EL image and smoke-test it
#   make standalone     - build a NON-ROOT install tarball (.tar.gz, no rpm,
#                         no systemd) into ./output/
#   make test-standalone- extract + run the standalone tarball as an unprivileged
#                         user on a clean image and smoke-test it
#   make all            - build + test BOTH the RPM and the standalone tarball
#                         (default)
#   make el10           - build + test for EL 10 (alias for: make all EL=10)
#   make el8            - build + test for EL 8  (alias for: make all EL=8)
#   make shell          - open a shell in the builder image (debugging)
#   make clean          - remove build artifacts and images (current EL)
#
# Select the build OS with EL (default 10):
#   make all EL=8              # build + test on EL 8
#   make all EL=10             # build + test on EL 10
# Artifacts and images are kept separate per OS (output/el<N>, image tags).
#
# Override the target tag/version on the command line, e.g.:
#   make rpm RSTUDIO_GIT_REF=v2026.06.0+242 \
#            RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=06 \
#            RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+242
# =============================================================================

# ---- Configuration ----------------------------------------------------------
# Target Enterprise Linux major version (8 or 10). The concrete base image is
# still the Rocky Linux image published for that EL release.
EL                     ?= 10
BASE_IMAGE             ?= rockylinux/rockylinux:$(EL)

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
# Image tags and output dir are namespaced per OS so el8 / el10 builds never
# clobber each other (CPack names the RPM file identically for both).
VER           := $(RSTUDIO_VERSION_MAJOR).$(RSTUDIO_VERSION_MINOR).$(RSTUDIO_VERSION_PATCH)
# Build number from the version suffix ("+242" -> "242").
RSTUDIO_BUILD := $(subst +,,$(RSTUDIO_VERSION_SUFFIX))
ARCH          ?= x86_64
BUILD_IMAGE   ?= rstudio-server-build:$(VER)-el$(EL)
TEST_IMAGE    ?= rstudio-server-test:$(VER)-el$(EL)
SA_TEST_IMAGE ?= rstudio-server-standalone-test:$(VER)-el$(EL)
OUTPUT_ROOT   ?= output
OUTPUT_DIR    ?= $(OUTPUT_ROOT)/el$(EL)
# Canonical RPM filename: RStudio version + build, the target OS, and arch.
# e.g. rstudio-server-2026.06.0-242.el8.x86_64.rpm
RPM_FILENAME  ?= rstudio-server-$(VER)-$(RSTUDIO_BUILD).el$(EL).$(ARCH).rpm
# Standalone tarball filename. MUST match the name make-standalone.sh derives
# inside the container (version + build + el<N> + arch), so the Makefile can
# copy exactly that file out. e.g.
# rstudio-server-2026.06.0-242.el10.x86_64-standalone.tar.gz
STANDALONE_FILENAME ?= rstudio-server-$(VER)-$(RSTUDIO_BUILD).el$(EL).$(ARCH)-standalone.tar.gz

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
.PHONY: all image rpm test standalone test-standalone shell clean el8 el10

# Build + test both artifacts: the RPM and the standalone tarball. Each phony
# prerequisite runs once, and make orders them by their own dependencies
# (test -> rpm; test-standalone -> standalone -> rpm), so the RPM is built once
# and reused for both.
all: rpm test standalone test-standalone

# Convenience aliases for each supported OS.
el10:
	$(MAKE) all EL=10
el8:
	$(MAKE) all EL=8

# ---- 1. Compile RStudio Server + build the RPM inside the container ----------
image:
	$(DOCKER_BUILD) $(BUILD_ARGS) $(BUILD_FLAGS) \
		-f docker/Dockerfile.build \
		-t $(BUILD_IMAGE) .

# ---- 2. Extract the built RPM(s) to ./output/el<N>/ -------------------------
rpm: image
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Extracting RPM(s) from $(BUILD_IMAGE)"
	rm -f $(OUTPUT_DIR)/*.rpm
	$(DOCKER) rm -f rstudio-extract-el$(EL) >/dev/null 2>&1 || true
	$(DOCKER) create --name rstudio-extract-el$(EL) $(BUILD_IMAGE) >/dev/null
	$(DOCKER) cp rstudio-extract-el$(EL):/output/. $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-extract-el$(EL) >/dev/null
	@echo ">> Renaming RPM -> $(RPM_FILENAME)"
	@cd $(OUTPUT_DIR) && for f in rstudio-server-*.rpm; do \
		[ "$$f" = "$(RPM_FILENAME)" ] || mv -f "$$f" "$(RPM_FILENAME)"; \
	done
	@echo ">> RPM(s) available in ./$(OUTPUT_DIR):"
	@ls -l $(OUTPUT_DIR)/*.rpm

# ---- 3. Install the RPM on a clean image and smoke-test it ------------------
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

# ---- 2b. Build a standalone, non-root install tarball -----------------------
# Turns the relocatable RPM into a plain .tar.gz an ordinary user extracts and
# runs with NO root and NO systemd service. make-standalone.sh runs inside the
# builder image (it has cpio + the packaging scripts), unpacks the RPM *payload*
# (which contains no systemd unit / scriptlets), bundles the run-standalone.sh
# launcher into a single top-level dir, and emits the tarball to /output; we
# copy just that file out.
standalone: rpm
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Building standalone (non-root, no-systemd) tarball from the RPM"
	$(DOCKER) rm -f rstudio-standalone-el$(EL) >/dev/null 2>&1 || true
	$(DOCKER) run --name rstudio-standalone-el$(EL) $(BUILD_IMAGE) \
		/usr/local/bin/make-standalone.sh
	$(DOCKER) cp rstudio-standalone-el$(EL):/output/$(STANDALONE_FILENAME) $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-standalone-el$(EL) >/dev/null
	@echo ">> Standalone tarball available:"
	@ls -l $(OUTPUT_DIR)/$(STANDALONE_FILENAME)

# ---- 2c. Smoke-test the standalone tarball as an UNPRIVILEGED user -----------
# Builds a clean EL+R image with a normal (non-root) user, extracts the tarball
# and launches the server as that user, and asserts it serves the sign-in page
# with no systemd service anywhere. Proves the no-root/no-systemd contract.
test-standalone: standalone
	@echo ">> Smoke-testing the standalone tarball as a non-root user (EL $(EL))"
	rm -rf $(OUTPUT_DIR)/.ctx-sa && mkdir -p $(OUTPUT_DIR)/.ctx-sa
	cp $(OUTPUT_DIR)/$(STANDALONE_FILENAME) $(OUTPUT_DIR)/.ctx-sa/
	cp scripts/test-standalone.sh $(OUTPUT_DIR)/.ctx-sa/
	$(DOCKER_BUILD) $(BUILD_FLAGS) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f docker/Dockerfile.standalone-test -t $(SA_TEST_IMAGE) $(OUTPUT_DIR)/.ctx-sa
	rm -rf $(OUTPUT_DIR)/.ctx-sa
	$(DOCKER) run --rm $(SA_TEST_IMAGE)

# ---- Debug: shell into the builder ------------------------------------------
shell: image
	$(DOCKER) run --rm -it $(BUILD_IMAGE) /bin/bash

# ---- Cleanup ----------------------------------------------------------------
clean:
	$(DOCKER) rm -f rstudio-extract-el$(EL) rstudio-standalone-el$(EL) 2>/dev/null || true
	$(DOCKER) rmi $(SA_TEST_IMAGE) $(TEST_IMAGE) $(BUILD_IMAGE) 2>/dev/null || true
	rm -rf $(OUTPUT_ROOT)
