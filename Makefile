# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2024 Red Hat Inc

##@ Help
# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php
.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
source_dir := $(shell dirname "$(mkfile_path)")
triton_path ?= $(source_dir)
user_path ?=
create_user ?= true

AMD_IMAGE_NAME ?= amd
CPU_IMAGE_NAME ?= cpu
NVIDIA_IMAGE_NAME ?= nvidia

CTR_CMD := $(or $(shell command -v podman), $(shell command -v docker))
RUNTIME_ARGS ?=

CUSTOM_LLVM ?= false
DEMO_TOOLS ?= false
NOTEBOOK_PORT ?= 8888
IMAGE_REPO ?= quay.io/triton-dev-containers
LLVM_IMAGE_LABEL ?= latest # Need a separate tag so we only update TRITON_TAG for custom builds
LLVM_TAG ?=
TRITON_CPU_BACKEND ?= 0
TRITON_TAG ?= latest
# NOTE: Requires host build system to have a valid Red Hat Subscription if true
INSTALL_NSIGHT ?= false

# Modify image tag if CUSTOM_LLVM is enabled
ifeq ($(CUSTOM_LLVM),true)
    TRITON_TAG := custom-llvm-$(TRITON_TAG)
endif

ifeq ($(TRITON_CPU_BACKEND),1)
    LLVM_IMAGE_LABEL := cpu-$(LLVM_IMAGE_LABEL)
endif

##@ Container Build
.PHONY: image-builder-check
image-builder-check: ## Verify if container runtime is available
	@if [ -z "$(CTR_CMD)" ]; then \
		echo '!! ERROR: containerized builds require podman or docker CLI, none found in $$PATH' >&2; \
		exit 1; \
	fi

.PHONY: all
all: triton-image triton-cpu-image triton-amd-image

.PHONY: llvm-image
llvm-image: image-builder-check ## Build the Triton LLVM image
	$(CTR_CMD) build -t $(IMAGE_REPO)/llvm:$(LLVM_IMAGE_LABEL) \
		--build-arg CUSTOM_LLVM=$(CUSTOM_LLVM) \
		--build-arg LLVM_TAG=$(LLVM_TAG) \
		--build-arg TRITON_CPU_BACKEND=$(TRITON_CPU_BACKEND) \
		-f dockerfiles/Dockerfile.llvm .

.PHONY: gosu-image
gosu-image: image-builder-check ## Build the Triton gosu image
	$(CTR_CMD) build -t $(IMAGE_REPO)/gosu:latest -f dockerfiles/Dockerfile.gosu .

.PHONY: triton-image
triton-image: image-builder-check gosu-image llvm-image ## Build the Triton devcontainer image
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(NVIDIA_IMAGE_NAME):$(TRITON_TAG) \
		--build-arg CUSTOM_LLVM=$(CUSTOM_LLVM) -f dockerfiles/Dockerfile.triton .

.PHONY: triton-cpu-image
triton-cpu-image: image-builder-check gosu-image ## Build the Triton CPU image
	$(MAKE) llvm-image CUSTOM_LLVM=$(CUSTOM_LLVM) TRITON_CPU_BACKEND=1 LLVM_IMAGE_LABEL=cpu-latest
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(CPU_IMAGE_NAME):$(TRITON_TAG) \
		--build-arg CUSTOM_LLVM=$(CUSTOM_LLVM) --build-arg TRITON_CPU_BACKEND=1 \
		-f dockerfiles/Dockerfile.triton-cpu .

.PHONY: triton-amd-image
triton-amd-image: image-builder-check gosu-image llvm-image ## Build the Triton AMD devcontainer image
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(AMD_IMAGE_NAME):$(TRITON_TAG) \
		--build-arg CUSTOM_LLVM=$(CUSTOM_LLVM) -f dockerfiles/Dockerfile.triton-amd .

##@ Container Run

RUNTIME_ARGS := -r $(IMAGE_REPO) -t $(TRITON_TAG)

ifneq ($(triton_path),$(source_dir))
	RUNTIME_ARGS += " -s TRITON=$(triton_path)"
endif

ifeq ($(INSTALL_NSIGHT),true)
	RUNTIME_ARGS += " -p"
endif

ifneq ($(user_path), )
	RUNTIME_ARGS += " -u $(user_path)"
endif

ifeq ($(DEMO_TOOLS),true)
	RUNTIME_ARGS += "-j $(NOTEBOOK_PORT)"
endif

ifeq ($(CUSTOM_LLVM),true)
	RUNTIME_ARGS += " -l"
endif

.PHONY: triton-run
triton-run: image-builder-check ## Run the Triton devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) $(NVIDIA_IMAGE_NAME)

.PHONY: triton-cpu-run
triton-cpu-run: image-builder-check ## Run the Triton CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) $(CPU_IMAGE_NAME)

.PHONY: triton-amd-run
triton-amd-run: image-builder-check ## Run the Triton AMD devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) $(AMD_IMAGE_NAME)

##@ Devcontainer

.PHONY: devcontainers
devcontainers: ## Generate all devcontainer.json files
	@echo "Running devcontainer generation..."
	$(MAKE) -C .devcontainer generate

.PHONY: clean-devcontainers
clean-devcontainers: ## Remove generated devcontainer.json files
	$(MAKE) -C .devcontainer clean

.PHONY: devcontainers-help
devcontainers-help: ## Show devcontainer help
	$(MAKE) -C .devcontainer help

##@Installation

.PHONY: install
install: $(HOME)/.local/bin/triton-dev-containers

$(HOME)/.local/bin/triton-dev-containers: triton-dev-containers.sh
	install -m 0750 $< $@

.PHONY: uninstall
uninstall:
	rm -f $(HOME)/.local/bin/triton-dev-containers
