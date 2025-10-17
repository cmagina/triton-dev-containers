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

TORCH_DIR=${WORKSPACE}/torch
TORCH_REPO=https://github.com/pytorch/pytorch.git

TORCH_VISION_DIR=${WORKSPACE}/torchvision
TORCH_VISION_REPO=https://github.com/pytorch/vision.git

TORCH_INDEX_URL_BASE=https://download.pytorch.org/whl
TORCH_HDR_MSG="Installing Torch"

setup_torch_src() {
	if [ -n "${ROCM_VERSION:-}" ]; then
		TORCH_REPO=https://github.com/ROCm/pytorch.git
		TORCH_GITREF="1c57644d"
	fi

	if [ ! -d "$TORCH_DIR" ]; then
		echo "Cloning the Torch repo $TORCH_REPO to $TORCH_DIR ..."
		git clone "$TORCH_REPO" "$TORCH_DIR"
		if [ ! -d "$TORCH_DIR" ]; then
			echo "$TORCH_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		echo "Torch repo already present, not cloning ..."
	fi

	pushd "$TORCH_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${TORCH_GITREF:-}" ]; then
			git checkout $TORCH_GITREF
		fi

		echo "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

setup_torchvision_src() {
	if [ -n "${ROCM_VERSION:-}" ]; then
		TORCH_VISION_GITREF="v0.23.0"
	fi

	if [ ! -d "$TORCH_VISION_DIR" ]; then
		echo "Cloning the Torch repo $TORCH_VISION_REPO to $TORCH_VISION_DIR ..."
		git clone "$TORCH_VISION_REPO" "$TORCH_VISION_DIR"
		if [ ! -d "$TORCH_VISION_DIR" ]; then
			echo "$TORCH_VISION_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		echo "Torch repo already present, not cloning ..."
	fi

	pushd "$TORCH_VISION_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${TORCH_VISION_GITREF:-}" ]; then
			git checkout $TORCH_VISION_GITREF
		fi

		echo "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

install_build_deps() {
	pushd "$TORCH_DIR" 1>/dev/null || exit 1

	if [ -f requirements.txt ]; then
		echo "Installing Torch dependencies ..."
		# Run this command from the PyTorch directory after cloning the source code using the “Get the PyTorch Source“ section above
		uv pip install --group dev
		uv pip install mkl-static mkl-include
		make triton
	fi

	if [ -n "${ROCM_VERSION:-}" ]; then
		python tools/amd_build/build_amd.py
	fi

	popd 1>/dev/null
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
	exit -1
fi

COMMAND=${1,,}

case $COMMAND in
source)
	echo "Setting up the environment for building Torch ..."
	setup_torch_src
	setup_torchvision_src
	install_build_deps
	exit $?
	;;
release)
	TORCH_HDR_MSG="$TORCH_HDR_MSG release"
	;;
nightly)
	TORCH_HDR_MSG="$TORCH_HDR_MSG nightly"
	TORCH_INDEX_URL_BUILD=/nightly
	;;
test)
	TORCH_HDR_MSG="$TORCH_HDR_MSG test"
	TORCH_INDEX_URL_BUILD=/test
	;;
*)
	usage
	exit 1
	;;
esac

echo "${TORCH_HDR_MSG} ..."
if [ -n "${TORCH_INDEX_URL:-}" ]; then
	echo "Using the specified index, $TORCH_INDEX_URL"
	TORCH_INDEX_URL="--index-url  $TORCH_INDEX_URL"
else
	TORCH_INDEX_URL="--index-url ${TORCH_INDEX_URL_BASE}${TORCH_INDEX_URL_BUILD:-}"
fi

if [ -n "${TORCH_BACKEND:-}" ]; then
	echo "Using specified torch backend, $TORCH_BACKEND"
elif [ -n "${ROCM_VERSION:-}" ]; then
	echo "Using the torch ROCm version ${ROCM_VERSION%.*} backend"
	TORCH_BACKEND=rocm${ROCM_VERSION%.*}
elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
	echo "Using the torch CPU backend"
	TORCH_BACKEND=cpu
elif [ -n "${CUDA_VERSION:-}" ]; then
	echo "Using the torch CUDA version ${CUDA_VERSION//-/} backend"
	TORCH_BACKEND=cu${CUDA_VERSION//-/}
else
	echo "Using the torch auto backend"
	TORCH_BACKEND=auto
fi

if [ -n "${TORCH_VERSION:-}" ]; then
	echo "Specified Torch version $TORCH_VERSION"
	TORCH_VERSION="==$TORCH_VERSION"
fi

uv pip install torch${TORCH_VERSION:-} \
	--torch-backend=$TORCH_BACKEND \
	$TORCH_INDEX_URL

# Fix up LD_LIBRARY_PATH for CUDA
./ldpretend.sh
