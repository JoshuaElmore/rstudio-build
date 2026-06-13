# =============================================================================
# Build RStudio Server RPMs from source on Rocky Linux 10, in Docker, and test.
#
#   make rpm     - build the RStudio Server RPM and copy it into ./output/
#   make test    - install the RPM on a clean Rocky 10 image and smoke-test it
#   make all     - rpm + test (default)
#   make shell   - open a shell in the builder image (debugging)
#   make clean   - remove build artifacts and images
#
# Override the target tag/version on the command line, e.g.:
#   make rpm RSTUDIO_GIT_REF=v2026.05.0+218 \
#            RSTUDIO_VERSION_MAJOR=2026 RSTUDIO_VERSION_MINOR=05 \
#            RSTUDIO_VERSION_PATCH=0 RSTUDIO_VERSION_SUFFIX=+218
# =============================================================================

# ---- Configuration ----------------------------------------------------------
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
BUILD_IMAGE   ?= rstudio-server-build:$(RSTUDIO_VERSION_MAJOR).$(RSTUDIO_VERSION_MINOR).$(RSTUDIO_VERSION_PATCH)
TEST_IMAGE    ?= rstudio-server-test:$(RSTUDIO_VERSION_MAJOR).$(RSTUDIO_VERSION_MINOR).$(RSTUDIO_VERSION_PATCH)
OUTPUT_DIR    ?= output

# Pass docker build args from the configuration above.
BUILD_ARGS = \
	--build-arg RSTUDIO_GIT_URL=$(RSTUDIO_GIT_URL) \
	--build-arg RSTUDIO_GIT_REF=$(RSTUDIO_GIT_REF) \
	--build-arg RSTUDIO_VERSION_MAJOR=$(RSTUDIO_VERSION_MAJOR) \
	--build-arg RSTUDIO_VERSION_MINOR=$(RSTUDIO_VERSION_MINOR) \
	--build-arg RSTUDIO_VERSION_PATCH=$(RSTUDIO_VERSION_PATCH) \
	--build-arg RSTUDIO_VERSION_SUFFIX=$(RSTUDIO_VERSION_SUFFIX)

.DEFAULT_GOAL := all
.PHONY: all image rpm test shell clean

all: rpm test

# ---- 1. Compile RStudio Server + build the RPM inside the container ----------
image:
	$(DOCKER_BUILD) $(BUILD_ARGS) $(BUILD_FLAGS) \
		-f docker/Dockerfile.build \
		-t $(BUILD_IMAGE) .

# ---- 2. Extract the built RPM(s) to ./output/ -------------------------------
rpm: image
	@mkdir -p $(OUTPUT_DIR)
	@echo ">> Extracting RPM(s) from $(BUILD_IMAGE)"
	$(DOCKER) rm -f rstudio-extract >/dev/null 2>&1 || true
	$(DOCKER) create --name rstudio-extract $(BUILD_IMAGE) >/dev/null
	$(DOCKER) cp rstudio-extract:/output/. $(OUTPUT_DIR)/
	$(DOCKER) rm -f rstudio-extract >/dev/null
	@echo ">> RPM(s) available in ./$(OUTPUT_DIR):"
	@ls -l $(OUTPUT_DIR)/*.rpm

# ---- 3. Install the RPM on a clean image and smoke-test it ------------------
test: rpm
	@echo ">> Building test image and running smoke test"
	$(DOCKER_BUILD) $(BUILD_FLAGS) -f docker/Dockerfile.test -t $(TEST_IMAGE) .
	$(DOCKER) run --rm $(TEST_IMAGE)

# ---- Debug: shell into the builder ------------------------------------------
shell: image
	$(DOCKER) run --rm -it $(BUILD_IMAGE) /bin/bash

# ---- Cleanup ----------------------------------------------------------------
clean:
	-$(DOCKER) rm -f rstudio-extract 2>/dev/null
	-$(DOCKER) rmi $(TEST_IMAGE) $(BUILD_IMAGE) 2>/dev/null
	rm -rf $(OUTPUT_DIR)
