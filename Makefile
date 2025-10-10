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


#################################################################################
# ------------------------------------------------------------------------------
# System environment and tooling
# ------------------------------------------------------------------------------
CTR_CMD := $(or $(shell command -v podman), $(shell command -v docker))
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
source_dir := $(dir $(mkfile_path))

# ------------------------------------------------------------------------------
# Build and runtime options
# ------------------------------------------------------------------------------
UBI_IMAGE ?= ubi
UBI_VERSION ?= 9

PYTHON_VERSION=3.12
CUDA_VERSION=12-9
ROCM_VERSION=6.3.3

# Get latest PyTorch release version
TORCH_VERSION=$(shell curl -s https://api.github.com/repos/pytorch/pytorch/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": "v?([^\"]+)".*/\1/')

# Source code paths
llvm_path ?=
torch_path ?=
triton_path ?= $(source_dir)
user_path ?=
vllm_path ?=

create_user ?= $(USER)

# ------------------------------------------------------------------------------
# Runtime configuration
# ------------------------------------------------------------------------------
RUNTIME_ARGS ?=
MAX_JOBS ?= $(shell nproc --all)
NOTEBOOK_PORT ?= 8888
INSTALL_NSIGHT ?= false
INSTALL_TOOLS ?= false

# Options: source | pip | skip
INSTALL_TRITON ?= skip
INSTALL_TORCH ?= skip
INSTALL_VLLM ?= skip

# ------------------------------------------------------------------------------
# Image naming
# ------------------------------------------------------------------------------
IMAGE_REPO ?= quay.io/triton-dev-containers
IMAGE_PREFIX ?= ubi${UBI_VERSION}

# Base image suffixes
TRITON_SUFFIX ?= triton
TORCH_SUFFIX ?= torch
VLLM_SUFFIX ?= vllm

# Image name definitions (clean and extensible)
BASE_IMAGE_NAME ?= base
NVIDIA_IMAGE_NAME ?= nvidia
AMD_IMAGE_NAME ?= amd
CPU_IMAGE_NAME ?= cpu

TRITON_IMAGE_NAME ?= $(NVIDIA_IMAGE_NAME)-$(CUDA_VERSION)-$(TRITON_SUFFIX)
TRITON_AMD_IMAGE_NAME ?= $(AMD_IMAGE_NAME)-$(ROCM_VERSION)-$(TRITON_SUFFIX)
TRITON_CPU_IMAGE_NAME ?= $(CPU_IMAGE_NAME)-$(TRITON_SUFFIX)

TORCH_IMAGE_NAME ?= $(NVIDIA_IMAGE_NAME)-$(CUDA_VERSION)-$(TORCH_SUFFIX)
TORCH_AMD_IMAGE_NAME ?= $(AMD_IMAGE_NAME)-$(ROCM_VERSION)-$(TORCH_SUFFIX)
TORCH_CPU_IMAGE_NAME ?= $(CPU_IMAGE_NAME)-$(TORCH_SUFFIX)

VLLM_IMAGE_NAME ?= $(NVIDIA_IMAGE_NAME)-$(CUDA_VERSION)-$(VLLM_SUFFIX)
VLLM_AMD_IMAGE_NAME ?= $(AMD_IMAGE_NAME)-$(ROCM_VERSION)-$(VLLM_SUFFIX)
VLLM_CPU_IMAGE_NAME ?= $(CPU_IMAGE_NAME)-$(VLLM_SUFFIX)

# Image tag definitions (clean and extensible)
BASE_TAG ?= latest
TORCH_TAG ?= latest
TRITON_TAG ?= latest
VLLM_TAG ?= latest

.PHONY: all
all: build-images

##@ Container Build

# $(1) = image name
# $(2) = image tag
# $(3) = ubi image (default: python-312)
# $(4) = ubi version (default: 9)
# $(5) = install triton (default: source)
# $(6) = install torch (default: pip)
# $(7) = install vllm (default: skip)
# $(8) = Additional podman build arguments
# $(9) = dockerfile name
define build-image
	@echo Building image: $(IMAGE_REPO)/$(1):$(2) 
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(IMAGE_PREFIX)-$(1):$(2) \
		--build-arg UBI_IMAGE=$(3) --build-arg UBI_VERSION=$(4) \
		--build-arg INSTALL_TRITON=$(5) --build-arg INSTALL_TORCH=$(6) \
		--build-arg INSTALL_VLLM=$(7) $(8) \
		-f dockerfiles/$(9) .
endef

.PHONY: build-images
build-images: triton-image triton-cpu-image triton-amd-image torch-image torch-cpu-image torch-amd-image vllm-image vllm-cpu-image vllm-amd-image ## Build all images

.PHONY: gosu-image 
gosu-image: ## Build the Triton gosu image
	$(call build-image,gosu,latest,,$(UBI_VERSION),,,,,Dockerfile.gosu)

.PHONY: base-image
base-image: gosu-image
	$(call build-image,$(BASE_IMAGE_NAME),$(BASE_TAG),$(UBI_IMAGE),$(UBI_VERSION),$(INSTALL_TRITON),$(INSTALL_TORCH),$(INSTALL_VLLM),,Dockerfile)


.PHONY: torch-image
torch-image: base-image ## Build the PyTorch NVIDIA devcontainer image
	$(call build-image,$(TORCH_IMAGE_NAME),$(TORCH_TAG),$(UBI_IMAGE),$(UBI_VERSION),skip,source,skip,--build-arg CUDA_VERSION=$(CUDA_VERSION),Dockerfile.triton)

.PHONY: torch-cpu-image
torch-cpu-image: base-image ## Build the PyTorch CPU devcontainer image
	$(call build-image,$(TORCH_CPU_IMAGE_NAME),$(TORCH_TAG),$(UBI_IMAGE),$(UBI_VERSION),skip,source,skip,,Dockerfile.triton-cpu)

.PHONY: torch-amd-image
torch-amd-image: base-image ## Build the PyTorch AMD devcontainer image
	$(call build-image,$(TORCH_AMD_IMAGE_NAME),$(TORCH_TAG),$(UBI_IMAGE),$(UBI_VERSION),skip,source,skip,--build-arg ROCM_VERSION=$(ROCM_VERSION),Dockerfile.triton-amd)

.PHONY: triton-image
triton-image: base-image ## Build the Triton NVIDIA devcontainer image
	$(call build-image,$(TRITON_IMAGE_NAME),$(TRITON_TAG),$(UBI_IMAGE),$(UBI_VERSION),source,release,skip,--build-arg CUDA_VERSION=$(CUDA_VERSION),Dockerfile.triton)

.PHONY: triton-cpu-image
triton-cpu-image: base-image ## Build the Triton CPU devcontainer image
	$(call build-image,$(TRITON_CPU_IMAGE_NAME),$(TRITON_TAG),$(UBI_IMAGE),$(UBI_VERSION),source,release,skip,,Dockerfile.triton-cpu)

.PHONY: triton-amd-image
triton-amd-image: base-image ## Build the Triton AMD devcontainer image
	$(call build-image,$(TRITON_AMD_IMAGE_NAME),$(TRITON_TAG),$(UBI_IMAGE),$(UBI_VERSION),source,release,skip,--build-arg ROCM_VERSION=$(ROCM_VERSION),Dockerfile.triton-amd)

.PHONY: vllm-image
vllm-image: base-image ## Build the vLLM NVIDIA devcontainer image
	$(call build-image,$(VLLM_IMAGE_NAME),$(VLLM_TAG),$(UBI_IMAGE),$(UBI_VERSION),release,release,source,--build-arg CUDA_VERSION=$(CUDA_VERSION),Dockerfile.triton)

.PHONY: vllm-cpu-image
vllm-cpu-image: base-image ## Build the vLLM CPU devcontainer image
	$(call build-image,$(VLLM_CPU_IMAGE_NAME),$(VLLM_TAG),$(UBI_IMAGE),$(UBI_VERSION),release,release,source,,Dockerfile.triton-cpu)

.PHONY: vllm-amd-image
vllm-amd-image: base-image ## Build the vLLM AMD devcontainer image
	$(call build-image,$(VLLM_AMD_IMAGE_NAME),$(VLLM_TAG),$(UBI_IMAGE),$(UBI_VERSION),release,release,source,--build-arg ROCM_VERSION=$(ROCM_VERSION),Dockerfile.triton-amd)

##@ Container Run
RUNTIME_ARGS := -r $(IMAGE_REPO) -t $(TRITON_TAG) -p $(NOTEBOOK_PORT) -j $(MAX_JOBS)

ifneq ($(llvm_path), )
	RUNTIME_ARGS += -s LLVM=$(llvm_path)
endif

ifneq ($(torch_path), )
	RUNTIME_ARGS += -s TORCH=$(torch_path)
endif

ifneq ($(triton_path),$(source_dir))
	RUNTIME_ARGS += -s TRITON=$(triton_path)
endif

ifneq ($(user_path), )
	RUNTIME_ARGS += -s USER=$(user_path)
endif

ifneq ($(vllm_path), )
	RUNTIME_ARGS += -s VLLM=$(vllm_path)
endif

ifeq ($(INSTALL_NSIGHT),true)
	INSTALL_TOOLS = true
endif

ifeq ($(INSTALL_TOOLS), true)
	RUNTIME_ARGS += -d
endif

ifneq ($(create_user), )
	RUNTIME_ARGS += -u $(create_user)
endif

.PHONY: base-run
base-run: ## Run the Base devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) $(BASE_IMAGE_NAME)

.PHONY: triton-run
triton-run: ## Run the Triton NVIDIA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f triton $(NVIDIA_IMAGE_NAME)

.PHONY: triton-cpu-run
triton-cpu-run: ## Run the Triton CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f triton $(CPU_IMAGE_NAME)

.PHONY: triton-amd-run
triton-amd-run: ## Run the Triton AMD devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f triton $(AMD_IMAGE_NAME)

.PHONY: torch-run
torch-run: ## Run the PyTorch NVIDIA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f torch $(NVIDIA_IMAGE_NAME)

.PHONY: torch-cpu-run
torch-cpu-run: ## Run the PyTorch CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f torch $(CPU_IMAGE_NAME)

.PHONY: torch-amd-run
torch-amd-run: ## Run the PyTorch AMD devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f torch $(AMD_IMAGE_NAME)

.PHONY: vllm-run
vllm-run: ## Run the vLLM NVIDIA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f vllm $(NVIDIA_IMAGE_NAME)

.PHONY: vllm-cpu-run
vllm-cpu-run: ## Run the vLLM CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f vllm $(CPU_IMAGE_NAME)

.PHONY: vllm-amd-run
vllm-amd-run: ## Run the vLLM AMD devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -f vllm $(AMD_IMAGE_NAME)

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

##@ Installation
.PHONY: install
install: $(HOME)/.local/bin/triton-dev-containers ## Install the triton-dev-containers.sh runtime script

$(HOME)/.local/bin/triton-dev-containers: triton-dev-containers.sh
	install -m 0750 $< $@

.PHONY: uninstall
uninstall: ## Uninstall the triton-dev-containers.sh runtime script
	rm -f $(HOME)/.local/bin/triton-dev-containers
