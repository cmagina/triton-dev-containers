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
# SPDX-License-Identifier: Apache-2.0]\
set -euo pipefail

CLONED=0

WORKSPACE=${WORKSPACE:-${HOME}}

VLLM_DIR=${WORKSPACE}/vllm
VLLM_REPO=https://github.com/vllm-project/vllm.git

get_cols() {
	read rows cols < <(stty size)
	echo $cols
}

hdr() {
	local msg="$1"
	local cols=$(get_cols)

	printf -v hdr_padding '#%.0s' {$(seq 1 $((($cols - ${#msg} - 2) / 2)))}
	printf -v hdr_line '#%.0s' {$(seq 1 $((2 * ${#hdr_padding} + ${#msg} + 2)))}

	printf "%s\n" "$hdr_line"
	printf "%s %s %s\n" "$hdr_padding" "$msg" "$hdr_padding"
	printf "%s\n" "$hdr_line"
}

info() {
	local msg="$1"
	local cols=$(get_cols)

	printf -v info_padding '=%.0s' {$(seq 1 $((($cols - ${#msg} - 2) / 2)))}
	printf -v info_line '=%.0s' {$(seq 1 $((2 * ${#info_padding} + ${#msg} + 2)))}

	printf "%s\n" "$info_line"
	printf "%s %s %s\n" "$info_padding" "$msg" "$info_padding"
	printf "%s\n" "$info_line"
}

setup_src() {
	if [ ! -d "$VLLM_DIR" ]; then
		info "Cloning the vLLM repo\n$VLLM_REPO to $VLLM_DIR ..."
		git clone "$VLLM_REPO" "$VLLM_DIR"
		if [ ! -d "$VLLM_DIR" ]; then
			echo "$VLLM_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		info "vLLM repo already present, not cloning ..."
	fi

	pushd "$VLLM_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${VLLM_GITREF:-}" ]; then
			git checkout $VLLM_GITREF
		fi

		info "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

install_build_deps() {
	pushd "$VLLM_DIR" 1>/dev/null || exit 1

	if [ -n "${ROCM_VERSION:-}" ]; then
		info "Installing ROCm build dependencies ..."
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

		tee -a $HOME/.bashrc >>EOF

		# Build vLLM for MI210/MI250/MI300.
		export PYTORCH_ROCM_ARCH="gfx90a;gfx942"
		EOF
	elif [ -n "${CUDA_VERSION:-}" ]; then
		info "Installing CUDA build dependencies ..."
		${SUDO:-} dnf -y install cuda-toolkit-${CUDA_VERSION}
	fi

	if [ -f requirements/build.txt ]; then
		info "Installing vLLM dependencies ..."
		uv pip install -r requirements/build.txt
	fi

	popd 1>/dev/null
}

install_pip() {
	if [ "${NVIDIA:-}" = "true" ]; then
		hdr "Installing CUDA vLLM wheel ..."
		uv pip install vllm \
			--extra-index-url https://download.pytorch.org/whl/cu${CUDA_VERSION//-/}
	fi
}

install_nightly() {
	hdr "Installing vLLM nightly ..."
	uv pip install -U vllm \
		--torch-backend=auto \
		--extra-index-url https://wheels.vllm.ai/nightly
}

usage() {
	printf "Usage: %s [COMMAND]\n" "$(basename "$0")"
	printf "\tsource\t\tDownload vLLM's source and install the build deps\n"
	printf "\tpip\t\tInstall the vLLM using pip\n"
	printf "\tnightly\t\tInstall the vLLM nightly build using pip\n"
}

##
## Main
##

if [ $# -lt 1 ]; then
	usage
	exit 1
fi

COMMAND=${1,,}

if command -v sudo &>/dev/null; then
	export SUDO=$(which sudo)
fi

case $COMMAND in
source)
	hdr "Setting up the environment for building vLLM ..."
	setup_src
	install_build_deps
	;;
pip)
	install_pip
	;;
nightly)
	install_nightly
	;;
*)
	usage
	exit 1
	;;
esac
