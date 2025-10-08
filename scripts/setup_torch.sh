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

TORCH_DIR=${WORKSPACE}/torch
TORCH_REPO=https://github.com/pytorch/pytorch.git

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
	if [ ! -d "$TORCH_DIR" ]; then
		info "Cloning the Torch repo\n$TORCH_REPO to $TORCH_DIR ..."
		git clone "$TORCH_REPO" "$TORCH_DIR"
		if [ ! -d "$TORCH_DIR" ]; then
			echo "$TORCH_DIR not found. ERROR Cloning repository..."
			exit 1
		else
			CLONED=1
		fi
	else
		info "Torch repo already present, not cloning ..."
	fi

	pushd "$TORCH_DIR" 1>/dev/null || exit 1

	if [ "$CLONED" -eq 1 ]; then
		git submodule sync
		git submodule update --init --recursive

		if [ -n "${TORCH_GITREF:-}" ]; then
			git checkout $TORCH_GITREF
		fi

		info "Installing pre-commit dependencies ..."
		uv pip install pre-commit
		pre-commit install
	fi

	if command ccache &>/dev/null; then
		export USE_CCACHE=1
	fi

	popd 1>/dev/null
}

install_build_deps() {
	pushd "$TORCH_DIR" 1>/dev/null || exit 1

	if [ -f requirements.txt ]; then
		info "Installing Torch dependencies ..."
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

install_pip() {
	local torch_version
	local torch_index_url

	if [ -n "${ROCM_VERSION:-}" ]; then
		hdr "Installing Torch ROCm ..."
		torch_index_url="--index-url https://download.pytorch.org/whl/rocm${ROCM_VERSION%.*}"
	elif [ ${TRITON_CPU_BACKEND:-0} -eq 1 ]; then
		hdr "Installing Torch CPU ..."
		torch_index_url="--index-url https://download.pytorch.org/whl/cpu"
	else
		hdr "Installing Torch ..."
	fi

	if [ -n "${TORCH_VERSION:-}" ]; then
		torch_version="==$TORCH_VERSION"
	fi

	uv pip install torch${torch_version:-} ${torch_index_url:-}
}

ldpretend() {
	if [ -d "${PYTHONPATH}/nvidia" ]; then
		info "Fixing the system not seeing the NVIDIA CUDA libraries installed from pip ..."
		cuda_libs=($(find ${PYTHONPATH}/nvidia -iname '*.so*'))

		for lib in ${cuda_libs[*]}; do
			baselib="$(basename "$lib")"
			libdir=$(dirname "$lib")

			while
				libext="${baselib##*.}"
				[ "$libext" != "so" ]
			do
				baselib="$(basename "$baselib" ."$libext")"
			done

			if [ ! -e "$libdir/$baselib" ]; then
				ln -vs "$lib" "$libdir/$baselib"
			fi
		done

		info "Adding the NVIDIA CUDA libraries to LD_LIBRARY_PATH ..."
		cuda_dirs=($(find "${PYTHONPATH}/nvidia" -maxdepth 1 -mindepth 1 -type d ! -name '__pycache__'))
		printf -v cuda_ld_paths '%s/lib:' "${cuda_dirs[@]}"
		if [ -z "${LD_LIBRARY_PATH:-}" ]; then
			LD_LIBRARY_PATH=${cuda_ld_paths%:}
		else
			LD_LIBRARY_PATH=${cuda_ld_paths}${LD_LIBRARY_PATH}
		fi
		echo export LD_LIBRARY_PATH=${LD_LIBRARY_PATH} >>${HOME}/.bashrc
	fi
}

install_nightly() {
	local index_url

	if [ -n "${ROCM_VERSION:-}" ]; then
		hdr "Installing Torch nightly ROCm wheel ..."
		index_url=https://download.pytorch.org/whl/nightly/rocm${ROCM_VERSION%.*}
	elif [ -n "${CUDA_VERSION:-}" ]; then
		hdr "Installing Torch nightly CUDA wheel ..."
		index_url=https://download.pytorch.org/whl/nightly/cu${CUDA_VERSION//-/}
	else
		hdr "Installing Torch nightly CPU wheel ..."
		index_url=https://download.pytorch.org/whl/nightly/cpu
	fi

	uv pip install --pre torch torchvision \
		--index-url "$index_url"
}

usage() {
	printf "Usage: %s [COMMAND]\n" "$(basename "$0")"
	printf "\tsource\t\tDownload Torch's source and install the build deps\n"
	printf "\tpip\t\tInstall the Torch using pip\n"
	printf "\tnightly\t\tInstall the Torch nightly build using pip\n"
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
	hdr "Setting up the environment for building Torch ..."
	setup_src
	install_build_deps
	ldpretend
	;;
pip)
	install_pip
	ldpretend
	;;
nightly)
	install_nightly
	;;
*)
	usage
	exit 1
	;;
esac
