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

PYTHON_CUDA_LDCONFIG_FILE=/etc/ld.so.conf.d/988-python-cuda.conf

if command -v sudo &>/dev/null; then
	SUDO=sudo
	export SUDO
fi

if [ -d "${PYTHONPATH}/nvidia" ]; then
	echo "Fixing the system not seeing the NVIDIA CUDA libraries installed from pip ..."
	readarray cuda_libs < <(find "${PYTHONPATH}"/nvidia -iname '*.so*')

	for lib in ${cuda_libs[@]}; do
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
	echo "Adding the NVIDIA CUDA pip installed libraries to ldconfig ..."
	${SUDO:-} rm -f "$PYTHON_CUDA_LDCONFIG_FILE"
	readarray -t cuda_dirs < <(find "${PYTHONPATH}/nvidia" -maxdepth 1 -mindepth 1 -type d ! -name '__pycache__')
	for cuda_ld_path in "${cuda_dirs[@]}"; do
		echo "${cuda_ld_path}"/lib | ${SUDO:-} tee -a "$PYTHON_CUDA_LDCONFIG_FILE"
	done
	${SUDO:-} ldconfig
fi
