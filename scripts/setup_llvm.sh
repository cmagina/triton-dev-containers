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

REPO="triton"
PROJECTS="mlir;llvm;lld"
TARGETS_TO_BUILD="host;NVPTX;AMDGPU"

LLVM_DIR=${WORKSPACE}/llvm-project
LLVM_REPO=https://github.com/llvm/llvm-project.git
LLVM_BUILD_PATH=$LLVM_DIR
LLVM_INSTALL_PATH=${WORKSPACE}/llvm

TRITON_CPU_BACKEND=${TRITON_CPU_BACKEND:-0}

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
	if [ ! -d "$LLVM_DIR" ]; then
		info "Cloning the LLVM Project repo\n$LLVM_REPO to $LLVM_DIR ..."
		git clone "$LLVM_REPO" "$LLVM_DIR"
		if [ ! -d "$LLVM_DIR" ]; then
			echo "$LLVM_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	fi

	pushd "$LLVM_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 0 ]; then
		git fetch origin
	fi

	info "Adding LLVM_BUILD_PATH to $HOME/.bashrc ..."
	echo "export LLVM_BUILD_PATH=$LLVM_BUILD_PATH" >>$HOME/.bashrc
	echo "Run 'source $HOME/.bashrc' to update the current shell"

	popd 1>/dev/null
}

install_build_deps() {
	info "Installing LLVM dependencies ..."
	pushd "$LLVM_DIR" 1>/dev/null || exit 1
	uv pip install --upgrade cmake ninja ccache pybind11

	if [ -f mlir/python/requirements.txt ]; then
		uv pip install -r mlir/python/requirements.txt
	fi
	popd 1>/dev/null
}

usage() {
	printf "Usage: %s [COMMAND]\n" "$(basename "$0")"
	printf "\tsource\t\tDownload LLVM's source and install the build deps\n"
}

##
## Main
##

if [ $# -lt 1 ]; then
	usage
	exit 1
fi

COMMAND=${1,,}

if [ "${COMMAND}" = "source" ]; then
	hdr "Setting up the environment for building LLVM ..."
	setup_src
	install_build_deps
fi
