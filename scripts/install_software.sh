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

if command -v sudo &>/dev/null; then
	SUDO=sudo
	export SUDO
fi

echo "Upgrading pip and uv ..."
python${PYTHON_VERSION} -m pip install --upgrade pip uv

if [ "${INSTALL_TOOLS:-}" = "true" ]; then
	echo "Installing triton proton dependencies ..."
	uv pip install llnl-hatchet
fi

if [ "${INSTALL_JUPYTER:-}" = "true" ]; then
	echo "Installing Jupyter Notebook ..."
	uv pip install jupyter

	echo "Installing PDF export support for Jupyter Notebook ..."
	${SUDO:-} dnf -y install pandoc texlive-adjustbox \
		texlive-collection-fontsrecommended texlive-eurosym texlive-fontspec \
		texlive-grffile texlive-jknapltx texlive-metafont texlive-parskip \
		texlive-soul texlive-tcolorbox texlive-titling texlive-upquote \
		texlive-ulem texlive-unicode-math texlive-xetex
	${SUDO:-} dnf clean all

	echo "Adding start_jupyter script to /usr/local/bin/start_jupyter"
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
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
	
uv run jupyter notebook --ip=0.0.0.0 --port=\${NOTEBOOK_PORT:-8888} --no-browser \\
	--allow-root --notebook-dir=\${NOTEBOOK_DIR:-\${WORKSPACE}}
EOF
	${SUDO:-} chmod +x /usr/local/bin/start_jupyter
	echo "start_jupyter added!"
fi

if [ ${USE_CCACHE:-0} -ne 0 ]; then
	echo "Installing ccache ..."
	${SUDO:-} dnf -y install ccache

	echo "Adding CCACHE environment variables to ${HOME}/.bashrc ..."
	tee -a "${HOME}/.bashrc" <<EOF

# Enable CCACHE use
export CCACHE_DIR=${WORKSPACE}/.cache/ccache
export CCACHE_NOHASHDIR="true"
EOF
fi

if [ -n "${CUDA_VERSION:-}" ]; then
	echo "Installing the NVIDIA CUDA repository ..."
	CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel${CENTOS_VERSION}/x86_64/cuda-rhel${CENTOS_VERSION}.repo"
	${SUDO:-} dnf -y config-manager --add-repo "$CUDA_REPO"

	echo "Installing CUDA build dependencies ..."
	${SUDO:-} dnf -y install cuda-minimal-build-$CUDA_VERSION \
		cuda-libraries-devel-$CUDA_VERSION cuda-nvml-devel-$CUDA_VERSION

	echo "Adding CUDA paths to the user environment ..."
	tee -a "${HOME}/.bashrc" <<EOF

export CUDA_HOME=/usr/local/cuda
export PATH=/usr/local/cuda/bin:\$PATH
EOF

	if [ "${INSTALL_TOOLS:-}" = "true" ]; then
		echo "Installing NVIDIA Nsight ..."
		${SUDO:-} dnf -y install cublasmp cuda-cupti-$CUDA_VERSION \
			cuda-gdb-$CUDA_VERSION cuda-nsight-$CUDA_VERSION \
			cuda-nsight-compute-$CUDA_VERSION cuda-nsight-systems-$CUDA_VERSION
		${SUDO:-} dnf clean all

		# Create a symlink to the installed version of CUDA
		COMPUTE_VERSION=$(ls /opt/nvidia/nsight-compute)
		${SUDO:-} alternatives --install /usr/local/bin/ncu ncu \
			"/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu" 100
		${SUDO:-} alternatives --install /usr/local/bin/ncu-ui ncu-ui \
			"/opt/nvidia/nsight-compute/${COMPUTE_VERSION}/ncu-ui" 100

		uv pip install jupyterlab-nvidia-nsight nvtx
	fi
elif [ -n "${ROCM_VERSION:-}" ]; then
	echo "Installing ROCm build dependencies ..."
	${SUDO:-} dnf -y install miopen-hip rocm-core rocm-hip-libraries

	if [ "${INSTALL_TOOLS:-}" = "true" ]; then
		echo "Installing ROCm Developer Tools ..."
		${SUDO:-} dnf -y install rocm-developer-tools rocprofiler-compute

		if [ -f "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt" ]; then
			uv pip install -r /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt
		fi

		echo "Installing ROCm build dependencies ..."
		if [ -e "/opt/rocm/share/amd_smi" ]; then
			uv pip install /opt/rocm/share/amd_smi
		fi
	fi
fi
