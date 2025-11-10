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
# Buildtime configuration
# ------------------------------------------------------------------------------
WORKSPACE = /workspace

# ------------------------------------------------------------------------------
# Versions
# ------------------------------------------------------------------------------
CUDA_VERSION ?= 13-0
GOSU_VERSION ?= 1.19
PYTHON_VERSION ?= 3.12
ROCM_VERSION ?= 7.0.2
UBI_VERSION ?= 10

# ------------------------------------------------------------------------------
# Image naming
# ------------------------------------------------------------------------------
UBI_IMAGE ?= ubi

IMAGE_REPO ?= quay.io/triton-dev-containers
IMAGE_TAG ?= $(UBI_IMAGE)$(UBI_VERSION)

# Image name definitions (clean and extensible)
GOSU_IMAGE_NAME ?= gosu
BASE_IMAGE_NAME ?= base
CUDA_IMAGE_NAME ?= cuda
ROCM_IMAGE_NAME ?= rocm
CPU_IMAGE_NAME ?= cpu

# Image tags
GOSU_IMAGE_TAG ?= $(GOSU_VERSION)-$(IMAGE_TAG)
BASE_IMAGE_TAG ?= $(IMAGE_TAG)
CUDA_IMAGE_TAG ?= $(CUDA_VERSION)-$(IMAGE_TAG)
ROCM_IMAGE_TAG ?= $(ROCM_VERSION)-$(IMAGE_TAG)
CPU_IMAGE_TAG ?= $(IMAGE_TAG)

# ------------------------------------------------------------------------------
# Runtime configuration
# ------------------------------------------------------------------------------
RUNTIME_ARGS ?=

# Set the max number of jobs to use when building a framework
# Use a lower value to decrease ram usage during a build
MAX_JOBS ?= $(shell nproc --all)

# Jupyter notebook server port
NOTEBOOK_PORT ?= 8888

# Install debugging and profiling tools
INSTALL_NSIGHT ?= false
INSTALL_TOOLS ?= false
INSTALL_JUPYTER ?= true

# Operation to perform for each framework (default is skip)
INSTALL_LLVM ?= skip		# [ source | skip ]
INSTALL_TRITON ?= skip 	# [ source | release | skip ]
INSTALL_TORCH ?= skip 	# [ source | release | nightly | test | skip ]
INSTALL_VLLM ?= skip		# [ source | release | nightly | skip ]

# Framework versions to install from PyPi (latest is default for Torch)
TORCH_VERSION ?= $(shell curl -s https://api.github.com/repos/pytorch/pytorch/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": "v?([^\"]+)".*/\1/')
TRITON_VERSION ?=
VLLM_VERSION ?=

# Device indices (NVIDIA and AMD)
CUDA_VISIBLE_DEVICES ?=
ROCR_VISIBLE_DEVICES ?=

# Source code paths
llvm_path ?=
torch_path ?=
triton_path ?= $(source_dir)
user_path ?=
vllm_path ?=
gitconfig_path ?=

# Wheel url for PyTorch
torch_index_url ?= https://download.pytorch.org/whl

# Torch backend selector for UV [ cu<cuda version> | rocm<rocm version> | cpu ]
torch_backend ?=

# Wheel url for vLLM
vllm_extra_index_url ?=

# vLLM repo commit hash for specific wheel build install
vllm_commit ?=

create_user ?= $(USER)

.PHONY: all
all: build-images

##@ Container Build

# $(1) = image name
# $(2) = image tag
# $(3) = podman args
# $(4) = dockerfile name
define build-image
	@echo Building image: $(IMAGE_REPO)/$(1):$(2)
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(1):$(2) \
		$(3) -f dockerfiles/$(4) .
endef

.PHONY: build-images
build-images: cuda-image cpu-image rocm-image ## Build all images

.PHONY: gosu-image
gosu-image: ## Build the Base gosu image
	$(call build-image,$(GOSU_IMAGE_NAME),$(GOSU_IMAGE_TAG),--build-arg GOSU_VERSION=$(GOSU_VERSION) \
		--build-arg UBI_VERSION=$(UBI_VERSION),Dockerfile.gosu)

define base_image_build_args
--build-arg UBI_IMAGE=$(UBI_IMAGE) \
--build-arg UBI_VERSION=$(UBI_VERSION) \
--build-arg GOSU_IMAGE_NAME=$(GOSU_IMAGE_NAME) \
--build-arg GOSU_IMAGE_TAG=$(GOSU_IMAGE_TAG) \
--build-arg PYTHON_VERSION=$(PYTHON_VERSION) \
--build-arg WORKSPACE=$(WORKSPACE)
endef

.PHONY: base-image
base-image: gosu-image
	$(call build-image,$(BASE_IMAGE_NAME),$(BASE_IMAGE_TAG),$(base_image_build_args),Dockerfile)

define image_build_args
--build-arg BASE_IMAGE_NAME=$(BASE_IMAGE_NAME) \
--build-arg BASE_IMAGE_TAG=$(BASE_IMAGE_TAG)
endef

cuda-image: base-image ## Build a base CUDA devcontainer image
	$(call build-image,$(CUDA_IMAGE_NAME),$(CUDA_IMAGE_TAG),$(image_build_args) \
		--build-arg CUDA_VERSION=$(CUDA_VERSION),Dockerfile.cuda)

cpu-image: base-image ## Build a base CPU devcontainer image
	$(call build-image,$(CPU_IMAGE_NAME),$(CPU_IMAGE_TAG),$(image_build_args),Dockerfile.cpu)

rocm-image: base-image ## Build a base ROCm devcontainer image
	$(call build-image,$(ROCM_IMAGE_NAME),$(ROCM_IMAGE_TAG),$(image_build_args) \
		--build-arg ROCM_VERSION=$(ROCM_VERSION),Dockerfile.rocm)

##@ Container Run
RUNTIME_ARGS := -r $(IMAGE_REPO) -p $(NOTEBOOK_PORT) -j $(MAX_JOBS)

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

ifneq ($(gitconfig_path), )
	RUNTIME_ARGS += -s GITCONFIG=$(gitconfig_path)
endif

ifeq ($(INSTALL_JUPYTER),true)
	RUNTIME_ARGS += -o INSTALL_JUPYTER=true
endif

ifeq ($(INSTALL_NSIGHT),true)
	INSTALL_TOOLS = true
endif

ifeq ($(INSTALL_TOOLS),true)
	RUNTIME_ARGS += -o INSTALL_TOOLS=true
endif

ifneq ($(TORCH_VERSION), )
	RUNTIME_ARGS += -o TORCH_VERSION=$(TORCH_VERSION)
endif

ifneq ($(TRITON_VERSION), )
	RUNTIME_ARGS += -o TRITON_VERSION=$(TRITON_VERSION)
endif

ifneq ($(VLLM_VERSION), )
	RUNTIME_ARGS += -o VLLM_VERSION=$(VLLM_VERSION)
endif

ifneq ($(CUDA_VISIBLE_DEVICES), )
	RUNTIME_ARGS += -o CUDA_VISIBLE_DEVICES=$(CUDA_VISIBLE_DEVICES)
endif

ifneq ($(ROCR_VISIBLE_DEVICES), )
	RUNTIME_ARGS += -o ROCR_VISIBLE_DEVICES=$(ROCR_VISIBLE_DEVICES)
endif

ifneq ($(torch_index_url), )
	RUNTIME_ARGS += -o TORCH_INDEX_URL=$(torch_index_url)
endif

ifneq ($(torch_backend), )
	RUNTIME_ARGS += -o TORCH_BACKEND=$(torch_backend)
endif

ifneq ($(vllm_extra_index_url), )
	RUNTIME_ARGS += -o VLLM_EXTRA_INDEX_URL=$(vllm_extra_index_url)
endif

ifneq ($(vllm_commit), )
	RUNTIME_ARGS += -o VLLM_COMMIT=$(vllm_commit)
endif

ifneq ($(create_user), )
	RUNTIME_ARGS += -u $(create_user)
endif

.PHONY: base-run
base-run: ## Run the Base devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -t $(BASE_IMAGE_TAG) $(BASE_IMAGE_NAME)

.PHONY: cuda-run
cuda-run: ## Run the base CUDA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -t $(CUDA_IMAGE_TAG) $(CUDA_IMAGE_NAME)

.PHONY: cpu-run
cpu-run: ## Run the CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -t $(CPU_IMAGE_TAG) $(CPU_IMAGE_NAME)

.PHONY: rocm-run
rocm-run: ## Run the ROCm devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -t $(ROCM_IMAGE_TAG) $(ROCM_IMAGE_NAME)

.PHONY: triton-run
triton-run: ## Run the Triton CUDA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TRITON=source \
		-o INSTALL_TORCH=release -t $(CUDA_IMAGE_TAG) $(CUDA_IMAGE_NAME)

.PHONY: triton-cpu-run
triton-cpu-run: ## Run the Triton CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TRITON=source \
		-o INSTALL_TORCH=release $(CPU_IMAGE_TAG) $(CPU_IMAGE_NAME)

.PHONY: triton-rocm-run
triton-rocm-run: ## Run the Triton ROCm devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TRITON=source \
		-o INSTALL_TORCH=release -t $(ROCM_IMAGE_TAG) $(ROCM_IMAGE_NAME)

.PHONY: torch-run
torch-run: ## Run the PyTorch CUDA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TORCH=source \
		-t $(CUDA_IMAGE_TAG) $(CUDA_IMAGE_NAME)

.PHONY: torch-cpu-run
torch-cpu-run: ## Run the PyTorch CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TORCH=source \
		-t $(CPU_IMAGE_TAG) $(CPU_IMAGE_NAME)

.PHONY: torch-rocm-run
torch-rocm-run: ## Run the PyTorch ROCm devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_TORCH=source \
		-t $(ROCM_IMAGE_TAG) $(ROCM_IMAGE_NAME)

.PHONY: vllm-run
vllm-run: ## Run the vLLM CUDA devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_VLLM=source \
		-t $(CUDA_IMAGE_TAG) $(CUDA_IMAGE_NAME)

.PHONY: vllm-cpu-run
vllm-cpu-run: ## Run the vLLM CPU devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_VLLM=source \
		-t $(CPU_IMAGE_TAG) $(CPU_IMAGE_NAME)

.PHONY: vllm-rocm-run
vllm-rocm-run: ## Run the vLLM ROCm devcontainer image
	@./triton-dev-containers.sh $(RUNTIME_ARGS) -o INSTALL_VLLM=source \
		-o INSTALL_TORCH=release -o INSTALL_TRITON=release \
		-t $(ROCM_IMAGE_TAG) $(ROCM_IMAGE_NAME)

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