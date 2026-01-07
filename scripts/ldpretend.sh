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

if [ -d "${PYTHONPATH}/nvidia" ]; then
	echo "Fixing the system not seeing the NVIDIA CUDA libraries installed from pip ..."
	readarray -d ' ' cuda_libs < <(find "${PYTHONPATH}"/nvidia -iname '*.so*')

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

	echo "Adding the NVIDIA CUDA libraries to LD_LIBRARY_PATH ..."
	readarray -d ' ' cuda_dirs < <(find "${PYTHONPATH}/nvidia" -maxdepth 1 -mindepth 1 -type d ! -name '__pycache__')
	printf -v cuda_ld_paths '%s/lib:' "${cuda_dirs[@]}"
	if [ -z "${LD_LIBRARY_PATH:-}" ]; then
		LD_LIBRARY_PATH=${cuda_ld_paths%:}
	else
		LD_LIBRARY_PATH=${cuda_ld_paths}${LD_LIBRARY_PATH}
	fi
	echo export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}" >>"${HOME}"/.bashrc
fi
