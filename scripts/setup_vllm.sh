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

WORKSPACE=${WORKSPACE:-${HOME}}

VLLM_REPO=https://github.com/vllm-project/vllm.git
VLLM_DIR="${WORKSPACE}/vllm"
PIP_VLLM_INDEX_URL_BASE=https://wheels.vllm.ai

setup_src() {
	if [ ! -d "${VLLM_DIR}" ]; then
		echo "Cloning the vLLM repo $VLLM_REPO to $VLLM_DIR ..."
		git clone "$VLLM_REPO" "$VLLM_DIR"

		if [ ! -d "$VLLM_DIR" ]; then
			echo "$VLLM_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			pushd "$VLLM_DIR" 1>/dev/null || exit 1
			git submodule sync
			git submodule update --init --recursive

			if [ -n "${VLLM_GITREF:-}" ]; then
				git checkout "$VLLM_GITREF"
			fi

			echo "Install pre-commit hooks into your local vLLM git repo (one-time)"
			uv pip install pre-commit
			pre-commit install
			popd 1>/dev/null
		fi
	else
		echo "vLLM repo already present, not cloning ..."
	fi
}

install_build_deps() {
	pushd "$VLLM_DIR" 1>/dev/null || exit 1

	if [ "${INSTALL_TORCH:-}" = "source" ]; then
		echo "Using existing torch source build ..."
		python use_existing_torch.py
	fi

	if [ -n "${CUDA_VERSION:-}" ]; then
		VLLM_TARGET_DEVICE=cuda

		if [ -e requirements/cuda.txt ]; then
			echo "Installing vLLM CUDA build dependencies ..."
			uv pip install --prerelease=allow -r requirements/cuda.txt
		fi
	elif [ -n "${ROCM_VERSION:-}" ]; then
		VLLM_TARGET_DEVICE=rocm

		uv pip install --upgrade numba \
			scipy \
			"huggingface-hub[cli,hf_transfer]" \
			setuptools_scm

		uv pip install "numpy<2"

		if [ -e requirements/rocm.txt ]; then
			echo "Installing vLLM ROCm build dependencies ..."
			uv pip install --prerelease=allow -r requirements/rocm.txt
		fi
	elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
		VLLM_TARGET_DEVICE=cpu

		if [ -e requirements/cpu.txt ]; then
			echo "Installing vLLM CPU build dependencies ..."
			uv pip install --prerelease=allow -r requirements/cpu.txt
		fi
	fi

	if [ -f requirements/build.txt ]; then
		echo "Installing vLLM build dependencies ..."
		uv pip install --prerelease=allow -r requirements/build.txt
	fi

	popd 1>/dev/null

	echo "Set the target device for vLLM build ..."
	tee -a "${HOME}/.bashrc" <<EOF

# Target device for vLLM build
export VLLM_TARGET_DEVICE=$VLLM_TARGET_DEVICE
EOF
	echo "Run 'source ${HOME}/.bashrc' before building vLLM"
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [COMMAND]
    source     Download vLLM's source (if needed) and install the build deps
    release    Install vLLM
    nightly    Install the vLLM nightly wheel
EOF
}

##
## Main
##

if [ $# -ne 1 ]; then
	usage
	exit 1
fi

COMMAND=${1,,}

if command -v sudo &>/dev/null; then
	SUDO=$(which sudo)
	export SUDO
fi

case $COMMAND in
source)
	echo "Setting up the environment for building vLLM ..."
	setup_src
	install_build_deps
	exit $?
	;;
release)
	echo "Installing vLLM release ..."
	if [ -n "${PIP_VLLM_EXTRA_INDEX_URL:-}" ]; then
		echo "Using the extra index url $PIP_VLLM_EXTRA_INDEX_URL ..."
	elif [ -n "${VLLM_COMMIT:-}" ]; then
		echo "Using the build from commit $VLLM_COMMIT ..."
		PIP_VLLM_EXTRA_INDEX_URL="--extra-index-url ${PIP_VLLM_INDEX_URL_BASE}/${VLLM_COMMIT}"
	fi
	;;
nightly)
	echo "Installing vLLM nightly ..."
	PIP_VLLM_EXTRA_INDEX_URL="--extra-index-url ${PIP_VLLM_INDEX_URL_BASE}/nightly"
	;;
*)
	usage
	exit 1
	;;
esac

if [ -n "${UV_TORCH_BACKEND:-}" ]; then
	echo "Using specified torch backend, $UV_TORCH_BACKEND"
elif [ -n "${ROCM_VERSION:-}" ]; then
	TORCH_ROCM_VERSION="$(echo "$ROCM_VERSION" | sed -e 's/\([0-9]\.[0-9]\).*/\1/')"

	echo "Using the torch ROCm version $TORCH_ROCM_VERSION backend"
	UV_TORCH_BACKEND="rocm${TORCH_ROCM_VERSION}"
elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
	echo "Using the torch CPU backend"
	UV_TORCH_BACKEND=cpu
elif [ -n "${CUDA_VERSION:-}" ]; then
	TORCH_CUDA_VERSION="$(echo "$CUDA_VERSION" | sed -e 's/\([0-9]*\)[.-]\([0-9]\)/\1\2/')"

	echo "Using the torch CUDA version $TORCH_CUDA_VERSION backend"
	UV_TORCH_BACKEND="cu${TORCH_CUDA_VERSION}"
else
	echo "Using the torch auto backend"
	UV_TORCH_BACKEND=auto
fi

if [ -n "${PIP_VLLM_VERSION:-}" ]; then
	echo "Installing specified version $PIP_VLLM_VERSION"
	PIP_VLLM_VERSION="==$PIP_VLLM_VERSION"
fi

uv pip install -U vllm${PIP_VLLM_VERSION:-} \
	--torch-backend="$UV_TORCH_BACKEND" \
	${PIP_VLLM_EXTRA_INDEX_URL:-}

# Fix up LD_LIBRARY_PATH for CUDA
"${WORKSPACE}"/ldpretend.sh
