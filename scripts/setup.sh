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

env_list=""

# Create a symlink to the installed version of CUDA
# RUN ln -sf /usr/local/cuda-${CUDA_VERSION/-/.} /usr/local/cuda

save_env() {
	# Define environment variables to export
	local -a save_vars

	if [ -n "${TRITON_CPU_BACKEND:-}" ]; then
		save_vars+=("TRITON_CPU_BACKEND")
	fi

	if [ -n "${ROCM_VERSION:-}" ]; then
		save_vars+=("ROCM_VERSION")
	fi

	if [ -n "${HIP_VISIBLE_DEVICES:-}" ]; then
		save_vars+=("HIP_VISIBLE_DEVICES")
	fi

	if [ -n "${TORCH_VERSION:-}" ]; then
		save_vars+=("TORCH_VERSION")
	fi

	if [ -n "${DISPLAY:-}" ]; then
		save_vars+=("DISPLAY")
	fi

	if [ -n "${WAYLAND_DISPLAY:-}" ]; then
		save_vars+=("WAYLAND_DISPLAY")
	fi

	if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
		save_vars+=("XDG_RUNTIME_DIR")
	fi

	if [ -n "${MAX_JOBS:-}" ]; then
		save_vars+=("MAX_JOBS")
	fi

	# Create comma separated list for runuser
	printf -v env_list '%s,' "${save_env[@]}"
}

##
## Main
##

if [ -n "${USER:-}" ] && [ "${USER:-}" != "root" ]; then
	./setup_user.sh
	save_env
	RUN_AS_USER="runuser -w "${env_list%,}" -u "$USER" --"
fi

${RUN_AS_USER:-} ./install_software.sh

if [ "${INSTALL_LLVM:-skip}" != "skip" ]; then
	${RUN_AS_USER:-} ./setup_llvm.sh $INSTALL_LLVM
fi

if [ "${INSTALL_TRITON:-skip}" != "skip" ]; then
	${RUN_AS_USER:-} ./setup_triton.sh $INSTALL_TRITON
fi

if [ "${INSTALL_TORCH:-skip}" != "skip" ]; then
	${RUN_AS_USER:-} ./setup_torch.sh $INSTALL_TORCH
fi

if [ "${INSTALL_VLLM:-skip}" != "skip" ]; then
	${RUN_AS_USER:-} ./setup_vllm.sh $INSTALL_VLLM
fi
