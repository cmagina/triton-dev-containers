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

NOTEBOOK_PORT=${NOTEBOOK_PORT:-8888}
DEMO_FLASH_ATTN_KERNEL=https://raw.githubusercontent.com/fulvius31/triton-cache-comparison/refs/heads/main/scripts/flash_attention.py

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

install_user_deps() {
	hdr "Installing user dependencies ..."
	info "Upgrading pip and installing uv ..."
	python${PYTHON_VERSION} -m pip install --upgrade pip uv
}

install_jupyter_notebook() {
	info "Installing Jupyter Notebook ..."
	uv pip install jupyter

	if [ -f "${HOME}/.bashrc" ] && grep -q "start_jupyter()" "${HOME}/.bashrc"; then
		info "start_jupyter function already exists in "${HOME}/.bashrc""
	else
		info "Adding start_jupyter function to "${HOME}/.bashrc""
		${SUDO:-} tee /usr/local/bin/start_jupyter <<EOF
#! /bin/bash -e

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
	
uv run jupyter notebook --ip=0.0.0.0 --port=\$NOTEBOOK_PORT --no-browser \\
	--allow-root --notebook-dir=\${NOTEBOOK_DIR:-\${WORKSPACE}}
EOF
		${SUDO:-} chmod +x /usr/local/bin/start_jupyter
		echo "start_jupyter added!"
	fi
}

install_tools() {
	if [ ! -f "flash_attention.py" ]; then
		info "Downloading a test flash attention triton kernel ..."
		curl -o $(basename $DEMO_FLASH_ATTN_KERNEL) $DEMO_FLASH_ATTN_KERNEL
	fi

	if command ccache &>/dev/null; then
		info "Adding CCACHE environment variables to ${HOME}/.bashrc ..."
		tee -a ${HOME}/.bashrc <<EOF

# Enable CCACHE use
export USE_CCACHE=1
export CCACHE_NOHASHDIR="true"
EOF
	fi

	if [ -n "${CUDA_VERSION:-}" ]; then
		info "Installing the NVIDIA CUDA repository ..."
		${SUDO:-} dnf -y config-manager --add-repo \
			https://developer.download.nvidia.com/compute/cuda/repos/rhel${UBI_VERSION}/x86_64/cuda-rhel${UBI_VERSION}.repo

		if [ "${INSTALL_TOOLS:-}" = "true" ]; then
			info "Installing NVIDIA Nsight ..."
			${SUDO:-} dnf -y install cublasmp cuda-cupti-${CUDA_VERSION} \
				cuda-gdb-${CUDA_VERSION} cuda-nsight-${CUDA_VERSION} \
				cuda-nsight-compute-${CUDA_VERSION} cuda-nsight-systems-${CUDA_VERSION}
			${SUDO:-} dnf clean all

			# Create a symlink to the installed version of CUDA
			COMPUTE_VERSION=$(ls /opt/nvidia/nsight-compute)
			${SUDO:-} alternatives --install /usr/local/bin/ncu ncu "/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu" 100
			${SUDO:-} alternatives --install /usr/local/bin/ncu-ui ncu-ui "/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu-ui" 100

			uv pip install jupyterlab-nvidia-nsight nvtx
		fi
	elif [ -n "${ROCM_VERSION:-}" ] && [ "${INSTALL_TOOLS:-}" = "true" ]; then
		info "Installing ROCm Developer Tools ..."
		${SUDO:-} dnf -y install rocm-developer-tools

		if [ -f "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt" ]; then
			uv pip install -r /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt
		fi
	fi

}

##
## Main
##

if command -v sudo &>/dev/null; then
	export SUDO=$(which sudo)
fi

install_user_deps
hdr "Installing tools ..."
install_jupyter_notebook
install_tools
