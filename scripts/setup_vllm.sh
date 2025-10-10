#! /bin/bash -e

trap "echo -e '\nScript interrupted. Exiting gracefully.'; exit 1" SIGINT

# Copyright (C) 2024-2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

CLONED=0

WORKSPACE=${WORKSPACE:-${HOME}}

VLLM_DIR=${WORKSPACE}/vllm
VLLM_REPO=https://github.com/vllm-project/vllm.git

FA_DIR=${WORKSPACE}/flash-attention
FA_REPO="https://github.com/Dao-AILab/flash-attention.git"
FA_GITREF="0e60e394"

AITER_DIR=${WORKSPACE}/aiter
AITER_REPO="https://github.com/ROCm/aiter.git"
AITER_GITREF="eef23c7f"

VLLM_INDEX_URL_BASE=https://wheels.vllm.ai
VLLM_HDR_MSG="Installing vLLM"

setup_src() {
	if [ ! -d "$VLLM_DIR" ]; then
		echo "# Cloning the vLLM repo $VLLM_REPO to $VLLM_DIR ..."
		git clone "$VLLM_REPO" "$VLLM_DIR"
		if [ ! -d "$VLLM_DIR" ]; then
			echo "$VLLM_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		echo "# vLLM repo already present, not cloning ..."
	fi

	pushd "$VLLM_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${VLLM_GITREF:-}" ]; then
			git checkout $VLLM_GITREF
		fi

		echo "# Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

install_build_deps() {
	pushd "$VLLM_DIR" 1>/dev/null || exit 1

	if [ -n "${ROCM_VERSION:-}" ]; then
		echo "# Installing ROCm build dependencies ..."
		if [ -e "/opt/rocm/share/amd_smi" ]; then
			uv pip install /opt/rocm/share/amd_smi
		fi

		uv pip install --upgrade numba \
			scipy \
			huggingface-hub[cli,hf_transfer] \
			setuptools_scm

		uv pip install "numpy<2"

		if [ -e requirements/rocm.txt ]; then
			uv pip install -r requirements/rocm.txt
		fi

		tee -a ${HOME}/.bashrc >>EOF

		# Build vLLM for MI210/MI250/MI300.
		export PYTORCH_ROCM_ARCH="gfx90a;gfx942"
		EOF
	elif [ -n "${CUDA_VERSION:-}" ]; then
		echo "# Installing CUDA build dependencies ..."
		${SUDO:-} dnf -y install cuda-toolkit-${CUDA_VERSION}
	fi

	if [ -f requirements/build.txt ]; then
		echo "# Installing vLLM dependencies ..."
		uv pip install -r requirements/build.txt
	fi

	popd 1>/dev/null
}

usage() {
	printf "Usage: %s [COMMAND]\n" "$(basename "$0")"
	printf "\tsource\t\tDownload vLLM's source (if needed) and install the build deps\n"
	printf "\trelease\t\tInstall vLLM\n"
	printf "\tnightly\t\tInstall the vLLM nightly wheel\n"
}

##
## Main
##

COMMAND=${1,,}

if command -v sudo &>/dev/null; then
	export SUDO=$(which sudo)
fi

case $COMMAND in
source)
	echo "## Setting up the environment for building vLLM ..."
	setup_src
	install_build_deps
	exit $?
	;;
release)
	VLLM_HDR_MSG="${VLLM_HDR_MSG} release"
	if [ -n "${VLLM_EXTRA_INDEX_URL:-}" ]; then
		VLLM_HDR_MSG="${VLLM_HDR_MSG} from extra index url"
	elif [ -n "${VLLM_COMMIT:-}" ]; then
		VLLM_HDR_MSG="${VLLM_HDR_MSG} commit ${VLLM_COMMIT}"
		VLLM_EXTRA_INDEX_URL="--extra-index-url ${VLLM_INDEX_URL_BASE}/${VLLM_COMMIT}"
	fi
	;;
nightly)
	VLLM_HDR_MSG="${VLLM_HDR_MSG} nightly"
	VLLM_EXTRA_INDEX_URL="--extra-index-url ${VLLM_INDEX_URL_BASE}/nightly"
	;;
*)
	usage
	exit 1
	;;
esac

echo "## ${VLLM_HDR_MSG} ..."
if [ -n "${TORCH_BACKEND:-}" ]; then
	echo "# Using specified torch backend, ${TORCH_BACKEND}"
elif [ -n "${ROCM_VERSION:-}" ]; then
	echo "# Using the torch ROCm version ${ROCM_VERSION%.*} backend"
	TORCH_BACKEND=rocm${ROCM_VERSION%.*}
elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
	echo "# Using the torch CPU backend"
	TORCH_BACKEND=cpu
elif [ -n "${CUDA_VERSION:-}" ]; then
	echo "# Using the torch CUDA version ${CUDA_VERSION//-/} backend"
	TORCH_BACKEND=cu${CUDA_VERSION//-/}
else
	echo "# Using the torch auto backend"
	TORCH_BACKEND=auto
fi

if [ -n "${VLLM_VERSION:-}" ]; then
	echo "# Specified vLLM version ${VLLM_VERSION}"
	VLLM_VERSION="==$VLLM_VERSION"
fi

uv pip install -U vllm${VLLM_VERSION:-} \
	--torch-backend=${TORCH_BACKEND} \
	${VLLM_EXTRA_INDEX_URL:-}

# Fix up LD_LIBRARY_PATH for CUDA
./ldpretend.sh
