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

setup_src() {
	# if [ -n "${ROCM_VERSION:-}" ]; then
	# 	TRITON_DIR=${WORKSPACE}/triton-rocm
	# 	TRITON_REPO=https://github.com/ROCm/triton.git
	# 	TRITON_GITREF="57c693b6"
	if [ "${TRITON_CPU_BACKEND:-0}" -eq 1 ]; then
		TRITON_DIR=${WORKSPACE}/triton-cpu
		TRITON_REPO=https://github.com/triton-lang/triton-cpu.git
	else
		TRITON_DIR=${WORKSPACE}/triton
		TRITON_REPO=https://github.com/triton-lang/triton.git
	fi

	if [ ! -d "$TRITON_DIR" ]; then
		echo "Cloning the triton repo $TRITON_REPO to $TRITON_DIR ..."
		git clone "$TRITON_REPO" "$TRITON_DIR"
		if [ ! -d "$TRITON_DIR" ]; then
			echo "$TRITON_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		echo "Triton repo already present, not cloning ..."
	fi

	export TRITON_DIR

	pushd "$TRITON_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${TRITON_GITREF:-}" ]; then
			git checkout $TRITON_GITREF
		fi

		echo "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

install_build_deps() {
	echo "Installing triton build dependencies ..."
	pushd "$TRITON_DIR" 1>/dev/null || exit 1

	if [ -f python/requirements.txt ]; then
		uv pip install -r python/requirements.txt
	fi

	if command ccache &>/dev/null; then
		tee -a $HOME/.bashrc <<EOF

# Enable CCACHE use for Triton build
TRITON_BUILD_WITH_CCACHE=true
EOF
	fi

	popd 1>/dev/null
}

install_deps() {
	echo "Installing triton dependencies ..."
	uv pip install cmake ctypeslib2 matplotlib ninja \
		numpy pandas pybind11 pytest pyyaml scipy tabulate wheel

	echo "Installing triton proton dependencies ..."
	uv pip install llnl-hatchet
}

install_src() {
	pushd "$TRITON_DIR" 1>/dev/null || exit 1
	if [ -n "${LLVM_BUILD_PATH:-}" ]; then
		echo "Building and installing llvm and triton ..."
		make dev-install-llvm
	else
		echo "Building and installing triton ..."
		uv pip install -e .
	fi

	popd 1>/dev/null
}

install_release() {
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

	if [ -n "${TRITON_VERSION:-}" ]; then
		echo "Specified Triton version $TRITON_VERSION"
		TRITON_VERSION="==$TRITON_VERSION"
	fi

	uv pip install triton${TRITON_VERSION:-} \
		--torch-backend=$TORCH_BACKEND

	# Fix up LD_LIBRARY_PATH for CUDA
	./ldpretend.sh
}

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") [COMMAND]
    source     Download Triton's source (if needed) and install the build deps
    install    Build and install Triton from source
    release    Install Triton
EOF
}

##
## Main
##

COMMAND=${1,,}

case $COMMAND in
source)
	echo "Setting up the environment for building Triton from source..."
	setup_src
	install_build_deps
	install_deps
	;;
install)
	echo "Building and installing Triton from source ..."
	setup_src
	install_build_deps
	install_src
	install_deps
	;;
release)
	echo "Installing Triton ..."
	install_release
	install_deps
	;;
*)
	usage
	exit 1
	;;
esac
