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

TORCH_DIR=${WORKSPACE}/torch
TORCH_REPO=https://github.com/pytorch/pytorch.git

PIP_TORCH_INDEX_URL_BASE=https://download.pytorch.org/whl

setup_src() {
	if [ ! -d "$TORCH_DIR" ]; then
		echo "Cloning the Torch repo $TORCH_REPO to $TORCH_DIR ..."
		git clone "$TORCH_REPO" "$TORCH_DIR"
		if [ ! -d "$TORCH_DIR" ]; then
			echo "$TORCH_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			pushd "$TORCH_DIR" 1>/dev/null || exit 1
			git submodule sync
			git submodule update --init --recursive

			if [ -n "${TORCH_GITREF:-}" ]; then
				git checkout ""
			fi

			echo "Install pre-commit hooks into your local Torch git repo (one-time)"
			uv pip install pre-commit
			pre-commit install
			popd 1>/dev/null
		fi
	else
		echo "Torch repo already present, not cloning ..."
	fi
}

install_build_deps() {
	pushd "$TORCH_DIR" 1>/dev/null || exit 1

	if [ -f requirements.txt ]; then
		echo "Installing Torch dependencies ..."
		uv pip install --group dev
		uv pip install mkl-static mkl-include
		make triton
	fi

	${SUDO:-} dnf -y install numactl-devel

	if [ -n "${ROCM_VERSION:-}" ]; then
		python tools/amd_build/build_amd.py
	fi

	popd 1>/dev/null
}

install_deps() {
	echo "Installing torch dependencies ..."
	uv pip install numpy
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [COMMAND] 
    source     Download Torch's source (if needed) and install the build deps
    release    Install Torch
    nightly    Install the Torch nightly wheel
    test       Install the Torch test wheel
EOF
}

##
## Main
##

if [ $# -ne 1 ]; then
	usage
	exit 1
fi

if command -v sudo &>/dev/null; then
	SUDO=sudo
	export SUDO
fi

COMMAND=${1,,}

case $COMMAND in
source)
	echo "Setting up the environment for building Torch ..."
	setup_src
	install_build_deps
	install_deps
	exit $?
	;;
release)
	echo "Installing the Torch release build ..."
	if [ -n "${UV_TORCH_BACKEND:-}" ]; then
		echo "Using specified uv backend, $UV_TORCH_BACKEND"
		UV_TORCH_BACKEND="--torch-backend=$UV_TORCH_BACKEND"
	elif [ -n "${ROCM_VERSION:-}" ]; then
		TORCH_ROCM_VERSION=$(echo "$ROCM_VERSION" | sed -e 's/\([0-9]\.[0-9]\).*/\1/')

		echo "Using the uv ROCm version $TORCH_ROCM_VERSION backend"
		UV_TORCH_BACKEND="--torch-backend=rocm${TORCH_ROCM_VERSION}"
	elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
		echo "Using the uv CPU backend"
		UV_TORCH_BACKEND="--torch-backend=cpu"
	elif [ -n "${CUDA_VERSION:-}" ]; then
		TORCH_CUDA_VERSION=$(echo "$CUDA_VERSION" | sed -e 's/\([0-9]*\)[.-]\([0-9]\)/\1\2/')

		echo "Using the uv CUDA version $TORCH_CUDA_VERSION backend"
		UV_TORCH_BACKEND="--torch-backend=cu${TORCH_CUDA_VERSION}"
	else
		echo "Using the uv auto backend"
		UV_TORCH_BACKEND="--torch-backend=auto"
	fi
	;;
nightly | test)
	echo "Installing Torch ..."
	PIP_TORCH_INDEX_URL_BUILD=/$COMMAND
	;;
*)
	usage
	exit 1
	;;
esac

if [ -n "${PIP_TORCH_INDEX_URL:-}" ]; then
	echo "Using the specified index, $PIP_TORCH_INDEX_URL"
	PIP_TORCH_INDEX_URL="--index-url  $PIP_TORCH_INDEX_URL"
else
	PIP_TORCH_INDEX_URL="--index-url ${PIP_TORCH_INDEX_URL_BASE}${PIP_TORCH_INDEX_URL_BUILD:-}"
fi

if [ -n "${PIP_TORCH_INDEX_URL_BUILD:-}" ]; then
	echo "Using the ${PIP_TORCH_INDEX_URL_BUILD///} build ..."
	if [ -n "${ROCM_VERSION:-}" ]; then
		TORCH_ROCM_VERSION=$(echo "$ROCM_VERSION" | sed -e 's/\([0-9]\.[0-9]\).*/\1/')

		echo "Using the ROCm version $TORCH_ROCM_VERSION backend"
		PIP_TORCH_INDEX_URL="${PIP_TORCH_INDEX_URL}/rocm${TORCH_ROCM_VERSION}"
	elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
		echo "Using the CPU backend"
		PIP_TORCH_INDEX_URL="${PIP_TORCH_INDEX_URL}/cpu"
	elif [ -n "${CUDA_VERSION:-}" ]; then
		TORCH_CUDA_VERSION=$(echo "$CUDA_VERSION" | sed -e 's/\([0-9]*\)[.-]\([0-9]\)/\1\2/')

		echo "Using the CUDA version $TORCH_CUDA_VERSION backend"
		PIP_TORCH_INDEX_URL="${PIP_TORCH_INDEX_URL}/cu${TORCH_CUDA_VERSION}"
	fi
fi

if [ -n "${PIP_TORCH_VERSION:-}" ]; then
	echo "Installing the specified version $PIP_TORCH_VERSION"
	PIP_TORCH_VERSION="==$PIP_TORCH_VERSION"
fi

uv pip install torch${PIP_TORCH_VERSION:-} ${UV_TORCH_BACKEND:-} \
	$PIP_TORCH_INDEX_URL

# Fix up LD_LIBRARY_PATH for CUDA
"${WORKSPACE}"/ldpretend.sh
