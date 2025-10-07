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

TRITON_DIR=${WORKSPACE}/triton
TRITON_REPO=https://github.com/triton-lang/triton.git

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
	if [ "${TRITON_CPU_BACKEND:-0}" -eq 1 ]; then
		TRITON_DIR=${WORKSPACE}/triton-cpu
		TRITON_REPO=https://github.com/triton-lang/triton-cpu.git
	fi

	if [ ! -d "$TRITON_DIR" ]; then
		info "Cloning the triton repo\n$TRITON_REPO to $TRITON_DIR ..."
		git clone "$TRITON_REPO" "$TRITON_DIR"
		if [ ! -d "$TRITON_DIR" ]; then
			echo "$TRITON_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		info "Triton repo already present, not cloning ..."
	fi

	export TRITON_DIR

	pushd "$TRITON_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${TRITON_GITREF:-}" ]; then
			git checkout $TRITON_GITREF
		fi

		info "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	popd 1>/dev/null
}

install_build_deps() {
	info "Installing triton build dependencies ..."
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
	info "Installing triton dependencies ..."
	uv pip install cmake ctypeslib2 matplotlib ninja \
		numpy pandas pybind11 pytest pyyaml scipy tabulate wheel

	info "Installing triton proton dependencies ..."
	uv pip install llnl-hatchet
}

install_src() {
	pushd "$TRITON_DIR" 1>/dev/null || exit 1
	if [ -n "${LLVM_BUILD_PATH:-}" ]; then
		info "Building and installing llvm and triton ..."
		make dev-install-llvm
	else
		info "Building and installing triton ..."
		uv pip install -e .
	fi

	popd 1>/dev/null
}

install_pip() {
	uv pip install triton
}

usage() {
	printf "Usage: %s [COMMAND]\n" "$(basename "$0")"
	printf "\tsource\t\tDownload Triton's source and install the build deps\n"
	printf "\tinstall\t\tBuild and install Triton\n"
	printf "\tpip\t\tInstall Triton using pip\n"
}

##
## Main
##

if [ $# -lt 1 ]; then
	usage
	exit 1
fi

COMMAND=${1,,}

case $COMMAND in
source)
	hdr "Setting up the environment for building Triton ..."
	setup_src
	install_build_deps
	install_deps
	;;
install)
	hdr "Building and installing Triton ..."
	install_src
	;;
pip)
	hdr "Installing Triton from PyPi ..."
	install_pip
	install_deps
	;;
*)
	usage
	exit 1
	;;
esac
