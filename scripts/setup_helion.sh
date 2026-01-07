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

HELION_DIR=${WORKSPACE}/helion
HELION_REPO=https://github.com/pytorch/helion.git

setup_src() {
	if [ ! -d "$HELION_DIR" ]; then
		echo "Cloning the Torch repo $HELION_REPO to $HELION_DIR ..."
		git clone "$HELION_REPO" "$HELION_DIR"
		if [ ! -d "$HELION_DIR" ]; then
			echo "$HELION_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			pushd "$HELION_DIR" 1>/dev/null || exit 1
			git submodule sync
			git submodule update --init --recursive

			if [ -n "${HELION_GITREF:-}" ]; then
				git checkout "$HELION_GITREF"
			fi

			echo "Installing pre-commit hooks into your local Helion git repo (one-time)"
			uv pip install pre-commit
			pre-commit install
			popd 1>/dev/null
		fi
	else
		echo "Torch repo already present, not cloning ..."
	fi
}

install_deps() {
	echo "Installing torch dependencies ..."
	uv pip install numpy
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [COMMAND] 
    source     Download Helion's source (if needed) and install the build deps
    release    Install Helion
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

case $COMMAND in
source)
	echo "Setting up the environment for building Helion ..."
	setup_src
	install_deps
	exit $?
	;;
release)
	echo "Installing Helion release ..."
	if [ -n "${UV_TORCH_BACKEND:-}" ]; then
		echo "Using specified torch backend, $UV_TORCH_BACKEND"
		UV_TORCH_BACKEND="--torch-backend=$UV_TORCH_BACKEND"
	elif [ -n "${ROCM_VERSION:-}" ]; then
		TORCH_ROCM_VERSION=$(echo "$ROCM_VERSION" | sed -e 's/\([0-9]\.[0-9]\).*/\1/')

		echo "Using the torch ROCm version $TORCH_ROCM_VERSION backend"
		UV_TORCH_BACKEND="--torch-backend=rocm${TORCH_ROCM_VERSION}"
	elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
		echo "Using the torch CPU backend"
		UV_TORCH_BACKEND="--torch-backend=cpu"
	elif [ -n "${CUDA_VERSION:-}" ]; then
		TORCH_CUDA_VERSION=$(echo "$CUDA_VERSION" | sed -e 's/\([0-9]*\)[.-]\([0-9]\)/\1\2/')

		echo "Using the torch CUDA version $TORCH_CUDA_VERSION backend"
		UV_TORCH_BACKEND="--torch-backend=cu${TORCH_CUDA_VERSION}"
	else
		echo "Using the torch auto backend"
		UV_TORCH_BACKEND="--torch-backend=auto"
	fi
	;;
*)
	usage
	exit 1
	;;
esac

if [ -n "${PIP_HELION_INDEX_URL:-}" ]; then
	echo "Using the specified index, $PIP_HELION_INDEX_URL"
	PIP_HELION_INDEX_URL="--index-url  $PIP_HELION_INDEX_URL"
fi

if [ -n "${PIP_HELION_VERSION:-}" ]; then
	echo "Installing the specified Helion version $PIP_HELION_VERSION"
	PIP_HELION_VERSION="==$PIP_HELION_VERSION"
fi

uv pip install helion${PIP_HELION_VERSION:-} ${UV_TORCH_BACKEND:-} \
	${PIP_HELION_INDEX_URL:-}
install_deps

# Fix up LD_LIBRARY_PATH for CUDA
"${WORKSPACE}"/ldpretend.sh
