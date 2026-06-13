# =============================================================================
# Build RStudio Server RPMs from source on Rocky Linux (8 or 10), in Docker,
# and test.
#
#   make rpm     - build the RStudio Server RPM and copy it into ./output/
#   make test    - install the RPM on a clean Rocky image and smoke-test it
#   make all     - rpm + test (default)
#   make rocky10 - build + test for Rocky 10 (alias for: make all ROCKY=10)
#   make rocky8  - build + test for Rocky 8  (alias for: make all ROCKY=8)
#   make shell   - open a shell in the builder image (debugging)
#   make clean   - remove build artifacts and images (current ROCKY)
#
# Select the build OS with ROCKY (default 10):
#   make all ROCKY=8            # build + test on Rocky Linux 8
#   make all ROCKY=10           # build + test on Rocky Linux 10
# Artifacts and images are kept separate per OS (output/rocky<N>, image tags).
#
# Override the target tag/version on the command line, e.g.:
#   make rpm RSTUDIO_GIT_REF=v2026.05.0+218 \
#            RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=05 \
#            RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+218
# =============================================================================

# ---- Configuration ----------------------------------------------------------
# Target Rocky Linux major version (8 or 10).
ROCKY                  ?= 10
BASE_IMAGE             ?= rockylinux/rockylinux:$(ROCKY)

RSTUDIO_GIT_URL        ?= https://github.com/rstudio/rstudio.git
RSTUDIO_GIT_REF        ?= v2026.05.0+218
RSTUDIO_VERSION_MAJOR  ?= 2026
RSTUDIO_VERSION_MINOR  ?= 05
RSTUDIO_VERSION_PATCH  ?= 0
RSTUDIO_VERSION_SUFFIX ?= +218

# This host's user is not in the docker group but has passwordless `sudo docker`.
# Override with `make DOCKER=docker` if your user can talk to the daemon directly.
DOCKER        ?= sudo docker
# The image build command and any extra flags are split out so CI can swap in
# `docker buildx build` + registry/gha cache flags WITHOUT changing local use.
# Locally these default to a plain `<DOCKER> build` with no extra flags, so the
# command produced is identical to before.
DOCKER_BUILD  ?= $(DOCKER) build
BUILD_FLAGS   ?=
# Image tags and output dir are namespaced per OS so rocky8 / rocky10 builds
# never clobber each other (CPack names the RPM file identically for both).
VER           := $(RSTUDIO_VERSION_MAJOR).$(RSTUDIO_VERSION_MINOR).$(RSTUDIO_VERSION_PATCH)
# Build number from the version suffix ("+218" -> "218").
RSTUDIO_BUILD := $(subst +,,$(RSTUDIO_VERSION_SUFFIX))
ARCH          ?= x86_64
BUILD_IMAGE   ?= rstudio-server-build:$(VER)-rocky$(ROCKY)
TEST_IMAGE    ?= rstudio-server-test:$(VER)-rocky$(ROCKY)
OUTPUT_DIR    ?= output/rocky$(ROCKY)
# Canonical RPM filename: RStudio version + build, the target OS, and arch.
# e.g. rstudio-server-2026.05.0-218.el8.x86_64.rpm
RPM_FILENAME  ?= rstudio-server-$(VER)-$(RSTUDIO_BUILD).el$(ROCKY).$(ARCH).rpm

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
.PHONY: all image rpm test shell clean rocky8 rocky10

all: rpm test

# Convenience aliases for each supported OS.
rocky10:
	$(MAKE) all ROCKY=10
rocky8:
	$(MAKE) all ROCKY=8

# ---- 1. Compile RStudio Server + build the RPM inside the container ----------
image:
	$(DOCKER_BUILD) $(BUILD_ARGS) $(BUILD_FLAGS) \
		-f docker/Dockerfile.build \
		-t $(BUILD_IMAGE) .

# ---- 2. Extract the built RPM(s) to ./output/rocky<N>/ ----------------------
rpm: image
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Extracting RPM(s) from $(BUILD_IMAGE)"
	rm -f $(OUTPUT_DIR)/*.rpm
	$(DOCKER) rm -f rstudio-extract-rocky$(ROCKY) >/dev/null 2>&1 || true
	$(DOCKER) create --name rstudio-extract-rocky$(ROCKY) $(BUILD_IMAGE) >/dev/null
	$(DOCKER) cp rstudio-extract-rocky$(ROCKY):/output/. $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-extract-rocky$(ROCKY) >/dev/null
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
	@echo ">> Building test image and running smoke test (Rocky $(ROCKY))"
	rm -rf $(OUTPUT_DIR)/.ctx && mkdir -p $(OUTPUT_DIR)/.ctx
	cp $(OUTPUT_DIR)/*.rpm $(OUTPUT_DIR)/.ctx/
	cp scripts/test-rpm.sh $(OUTPUT_DIR)/.ctx/
	$(DOCKER_BUILD) $(BUILD_FLAGS) --build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f docker/Dockerfile.test -t $(TEST_IMAGE) $(OUTPUT_DIR)/.ctx
	rm -rf $(OUTPUT_DIR)/.ctx
	$(DOCKER) run --rm $(TEST_IMAGE)

# ---- Debug: shell into the builder ------------------------------------------
shell: image
	$(DOCKER) run --rm -it $(BUILD_IMAGE) /bin/bash

# ---- Cleanup ----------------------------------------------------------------
clean:
	-$(DOCKER) rm -f rstudio-extract-rocky$(ROCKY) 2>/dev/null
	-$(DOCKER) rmi $(TEST_IMAGE) $(BUILD_IMAGE) 2>/dev/null
	rm -rf $(OUTPUT_DIR)
