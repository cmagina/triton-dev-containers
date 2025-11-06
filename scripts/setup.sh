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

declare -a SAVE_VARS=(
	"CUDA_VERSION"
	"CUDA_VISIBLE_DEVICES"
	"DISPLAY"
	"INSTALL_JUPYTER"
	"INSTALL_TOOLS"
	"INSTALL_LLVM"
	"INSTALL_TORCH"
	"INSTALL_TRITON"
	"INSTALL_VLLM"
	"MAX_JOBS"
	"PIP_TORCH_INDEX_URL"
	"PIP_TORCH_VERSION"
	"PIP_TRITON_VERSION"
	"PIP_VLLM_EXTRA_INDEX_URL"
	"PIP_VLLM_VERSION"
	"ROCM_VERSION"
	"ROCR_VISIBLE_DEVICES"
	"TRITON_CPU_BACKEND"
	"USE_CCACHE"
	"UV_HTTP_TIMEOUT"
	"UV_TORCH_BACKEND"
	"VLLM_COMMIT"
	"WAYLAND_DISPLAY"
	"XDG_RUNTIME_DIR"
)

##
## Main
##

echo "Setting up the container environment ..."
if [ -n "${USER:-}" ] && [ "${USER:-}" != "root" ]; then
	./setup_user.sh

	# Create comma separated list for runuser
	printf -v ENV_LIST '%s,' "${SAVE_VARS[@]}"
	RUN_AS_USER="runuser -w "${ENV_LIST%,}" -u "$USER" --"
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
