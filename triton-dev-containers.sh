#! /bin/bash -e

trap "echo -e '\nScript interrupted. Exiting gracefully.'; exit 1" SIGINT

# Copyright (C) 2024-2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
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

# If you are on an OS that has the user in /etc/passwd then we can pass
# the user from the host to the pod. Otherwise we default to create the
# user inside the container.
# With podman if you aren't creating the user you need to explicitly pass
# the user as --user $(USER) to start the container as that user.

# Global Default Variables
## Image versions
UBI_VERSION=10
CUDA_VERSION=13-0
ROCM_VERSION=7.1

IMAGE_REPO=quay.io/triton-dev-containers

GITCONFIG_PATH="${HOME}/.gitconfig"
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-0}
ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-0}

# PyPi Index URLs
PIP_TORCH_INDEX_URL=https://download.pytorch.org/whl

## Jupyter notebook
INSTALL_JUPYTER=false
DEFAULT_PORT=8888

## Image modifiers
MAX_JOBS=${MAX_JOBS:-$(nproc --all)}
USE_CCACHE=0

## Adds --rm to the runtime args
DELETE_ON_EXIT=false

# Container runtime command option arrays
declare -a CTR_ENV_OPTS
declare -a CTR_DEVICE_OPTS
declare -a CTR_SECURITY_OPTS
declare -a CTR_VOLUME_OPTS

declare -A OPTS=(
	["INSTALL_JUPYTER"]="true | false"
	["INSTALL_TOOLS"]="true | false"
	["INSTALL_LLVM"]="source | skip"
	["INSTALL_TORCH"]="nightly | release | source | test | skip"
	["INSTALL_TRITON"]="release | source | skip"
	["INSTALL_VLLM"]="nightly | release | source | skip"
)

usage() {
	cat >&2 <<EOF
Usage: ${0##*/} [OPTION]... DEVICE
    DEVICE                   Target device [ rocm | cpu | cuda ]
Options
    -c REMOTE_CONNECTION     Use the remote podman system
    -d                       Remove the container on exit
    -j MAX_JOBS              Maximum number of jobs to use when building Triton/PyTorch/vLLM (Default: $MAX_JOBS)
    -o OPTION=ARGUMENT       Specify a argument for an option
        CUDA_VERSION             CUDA version (Default: $CUDA_VERSION)
        CUDA_VISIBLE_DEVICES     List of NVIDIA device indices (i.e. 0,2)
        GITCONFIG                /path/to/.gitconfig (Default: $GITCONFIG_PATH)
        INSTALL_JUPYTER          Install the Jupyter notebook server
                                     [ ${OPTS["INSTALL_JUPYTER"]} ]
        INSTALL_TOOLS            Install debugging and profiling tools (i.e. NSIGHT or ROCm Systems)
                                     [ ${OPTS["INSTALL_TOOLS"]} ]
        INSTALL_LLVM             Setup the container to build LLVM from source
                                     [ ${OPTS["INSTALL_LLVM"]} ]
        INSTALL_TORCH            Install or setup the container for building PyTorch
                                     [ ${OPTS["INSTALL_TORCH"]} ]
        INSTALL_TRITON           Install or setup the container for building Triton
                                     [ ${OPTS["INSTALL_TRITON"]} ]
        INSTALL_VLLM             Install or setup the container for building vLLM
                                     [ ${OPTS["INSTALL_VLLM"]} ]
        PIP_TORCH_INDEX_URL      http://<url> (Default: $PIP_TORCH_INDEX_URL)
        PIP_TORCH_VERSION        Torch wheel version
        PIP_TRITON_VERSION       Triton wheel version
        PIP_VLLM_EXTRA_INDEX_URL http://<url> (Not used with VLLM_COMMIT)
        PIP_VLLM_VERSION         vLLM wheel version
        ROCM_VERSION             ROCm version (Default: $ROCM_VERSION)
        ROCR_VISIBLE_DEVICES     List of AMD device indices or UUIDs (i.e. 0,GPU-DEADBEEFDEADBEEF)
        UBI_VERSION              Ubi image version (Default: $UBI_VERSION)
        USE_CCACHE               Enable ccache [ 0 | 1 ] (Default: $USE_CCACHE)
        UV_TORCH_BACKEND         Framwork version: [ cu${CUDA_VERSION//-/} | rocm${ROCM_VERSION%.*} | cpu ]
        VLLM_COMMIT              vLLM git commit hash for wheel install (https://wheels.vllm.ai/<commit>)
    -p [ DEFAULT | PORT ]    Expose the specified port for the Jupyter notebook server (Default: $DEFAULT_PORT)
    -r IMAGE_REPO            Image repository (Default: $IMAGE_REPO)
    -s SOURCE=PATH           Local source directories to mount as volumes
        LLVM                     /path/to/llvm/source
        TORCH                    /path/to/torch/source
        TRITON                   /path/to/triton/source
        USER                     /path/to/user/source
        VLLM                     /path/to/vllm/source
    -t IMAGE_TAG             Image tag (Default: ubi${UBI_VERSION})
    -u USERNAME              Username to use inside the image
    -h                       Print usage
    -v                       Verbose
EOF
}

set_env_var() {
	local key=$1
	local value=$2

	if [[ ! "${CTR_ENV_OPTS[*]}" =~ $key ]]; then
		if [[ "${!OPTS[*]}" =~ $key ]]; then
			if [[ ! "${OPTS[$key]}" =~ $value ]]; then
				echo "Bad option, $value, for $key, can only be ${OPTS[$key]}"
				exit 1
			fi
		fi

		CTR_ENV_OPTS+=("-e $key=$value")
	fi
}

set_container_runtime() {
	if command -v podman &>/dev/null; then
		CTR_CMD=podman
	elif command -v docker &>/dev/null; then
		CTR_CMD=docker
	else
		echo "Could not find the podman or docker container runtime."
		echo "Please install one of them."
		exit 1
	fi
}

setup_volumes() {
	local selinux_flag

	# Set selinux volume flag if enforcing
	if command -v getenforce &>/dev/null && [ "$(getenforce 2>/dev/null)" == "Enforcing" ]; then
		selinux_flag=:z
	fi

	# Custom LLVM source code path
	if [ -n "${LLVM_PATH:-}" ]; then
		if [ -d "${LLVM_PATH:-}" ]; then
			CTR_VOLUME_OPTS+=("-v ${LLVM_PATH}:/workspace/llvm-project${selinux_flag:-}")
			set_env_var INSTALL_LLVM source
		else
			echo "Specified LLVM path does not exist."
			exit 1
		fi
	fi

	# Triton Lang source code path
	if [ -n "${TRITON_PATH:-}" ]; then
		if [ -d "${TRITON_PATH:-}" ]; then
			CTR_VOLUME_OPTS+=("-v ${TRITON_PATH}:/workspace/triton${selinux_flag:-}")
			set_env_var INSTALL_TRITON source
		else
			echo "Specified triton path does not exist."
			exit 1
		fi
	fi

	# PyTorch source code path
	if [ -n "${TORCH_PATH:-}" ]; then
		if [ -d "${TORCH_PATH:-}" ]; then
			CTR_VOLUME_OPTS+=("-v ${TORCH_PATH}:/workspace/torch${selinux_flag:-}")
			set_env_var INSTALL_TORCH source
		else
			echo "Specified torch path does not exist."
			exit 1
		fi
	fi

	# vLLM source code path
	if [ -n "${VLLM_PATH:-}" ]; then
		if [ -d "${VLLM_PATH:-}" ]; then
			CTR_VOLUME_OPTS+=("-v ${VLLM_PATH}:/workspace/vllm${selinux_flag:-}")
			set_env_var INSTALL_VLLM source
		else
			echo "Specified vllm path does not exist."
			exit 1
		fi
	fi

	# Add a user path if one is specified (should verify it exists)
	if [ -n "${USER_PATH:-}" ]; then
		if [ -d "${USER_PATH:-}" ]; then
			CTR_VOLUME_OPTS+=("-v ${USER_PATH}:/workspace/user${selinux_flag:-}")
		else
			echo "Specified user path does not exist."
			exit 1
		fi
	fi

	# User management for non-Mac OS's
	if [ "$(uname -s)" != "Darwin" ] && ! getent passwd "$USER" >/dev/null && [ -n "${USERNAME:-}" ]; then
		CTR_VOLUME_OPTS+=("-v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro")
	fi

	# Gitconfig
	if [ -f "${GITCONFIG_PATH:-}" ]; then
		CTR_VOLUME_OPTS+=("-v ${GITCONFIG_PATH}:/etc/gitconfig${selinux_flag:-}")
	fi
}

set_device_opts() {
	case $TARGET_DEVICE in
	rocm)
		CTR_DEVICE_OPTS+=(
			"--device=/dev/kfd"
			"--device=/dev/dri"
		)
		CTR_SECURITY_OPTS+=(
			"--cap-add=SYS_PTRACE"
			"--group-add=render"
			"--group-add=video"
			"--ipc=host"
			"--security-opt seccomp=unconfined"
		)

		set_env_var ROCM_VERSION "$ROCM_VERSION"
		set_env_var ROCR_VISIBLE_DEVICES "$ROCR_VISIBLE_DEVICES"
		IMAGE_TAG=${IMAGE_TAG:-${ROCM_VERSION}-ubi${UBI_VERSION}}
		;;
	cuda)
		if command -v nvidia-ctk >/dev/null 2>&1 && nvidia-ctk cdi list | grep -q "nvidia.com/gpu=all"; then
			CTR_DEVICE_OPTS+=("--device nvidia.com/gpu=all")
		else
			CTR_DEVICE_OPTS+=("--runtime=nvidia --gpus=all")
		fi

		CTR_SECURITY_OPTS+=("--security-opt label=disable")

		if [ "${INSTALL_TOOLS:-}" = "true" ]; then
			CTR_SECURITY_OPTS+=(
				"--privileged"
				"--cap-add=SYS_ADMIN"
			)

			if [ -n "${DISPLAY:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
				set_env_var DISPLAY "$DISPLAY"
				set_env_var WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
				set_env_var XDG_RUNTIME_DIR /tmp

				CTR_VOLUME_OPTS+=(
					"-v ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/tmp/${WAYLAND_DISPLAY}:ro"
				)
			else
				echo "WARNING: No DISPLAY or WAYLAND_DISPLAY configured"
			fi
		fi

		set_env_var CUDA_VERSION "$CUDA_VERSION"
		set_env_var CUDA_VISIBLE_DEVICES "$CUDA_VISIBLE_DEVICES"
		IMAGE_TAG=${IMAGE_TAG:-${CUDA_VERSION}-ubi${UBI_VERSION}}
		;;
	esac
}

set_user_args() {
	if [ -z "${USERNAME:-}" ] && [ "$(whoami)" != "root" ]; then
		USERNAME=$(whoami)
	fi

	if [ -n "${USERNAME:-}" ] && [ "${USERNAME:-}" != "root" ]; then
		set_env_var USER "$USERNAME"
		set_env_var USER_UID "$(id -u "$USER")"
		set_env_var USER_GID "$(id -g "$USER")"
	elif [ "$(basename "$CTR_CMD")" = "docker" ]; then
		CTR_ARGS=(
			"--user $(id -u):$(id -g)"
		)
	elif [ "$(basename "$CTR_CMD")" = "podman" ]; then
		CTR_ARGS=(
			"--user $USER"
		)
	fi
}

##
## MAIN
##

while getopts "c:dj:o:p:r:s:t:u:hv" opt; do
	case "$opt" in
	c)
		REMOTE_CONNECTION=$OPTARG
		;;
	d)
		DELETE_ON_EXIT=true
		;;
	j)
		MAX_JOBS=$OPTARG
		;;
	o)
		case "${OPTARG/=*/}" in
		cuda_version | CUDA_VERSION)
			CUDA_VERSION="${OPTARG/*=/}"
			;;
		cuda_visible_devices | CUDA_VISIBLE_DEVICES)
			CUDA_VISIBLE_DEVICES="${OPTARG/*=/}"
			;;
		gitconfig | GITCONFIG)
			GITCONFIG_PATH="${OPTARG/*=/}"
			;;
		install_jupyter | INSTALL_JUPYTER)
			INSTALL_JUPYTER="${OPTARG/*=/}"
			;;
		install_tools | INSTALL_TOOLS)
			set_env_var INSTALL_TOOLS "${OPTARG/*=/}"
			;;
		install_llvm | INSTALL_LLVM)
			set_env_var INSTALL_LLVM "${OPTARG/*=/}"
			;;
		install_torch | INSTALL_TORCH)
			set_env_var INSTALL_TORCH "${OPTARG/*=/}"
			;;
		install_triton | INSTALL_TRITON)
			set_env_var INSTALL_TRITON "${OPTARG/*=/}"
			;;
		install_vllm | INSTALL_VLLM)
			set_env_var INSTALL_VLLM "${OPTARG/*=/}"
			;;
		pip_torch_version | PIP_TORCH_VERSION)
			set_env_var PIP_TORCH_VERSION "${OPTARG/*=/}"
			;;
		pip_torch_index_url | PIP_TORCH_INDEX_URL)
			set_env_var PIP_TORCH_INDEX_URL "${OPTARG/*=/}"
			;;
		pip_triton_version | PIP_TRITON_VERSION)
			set_env_var PIP_TRITON_VERSION "${OPTARG/*=/}"
			;;
		pip_vllm_extra_index_url | PIP_VLLM_EXTRA_INDEX_URL)
			set_env_var PIP_VLLM_EXTRA_INDEX_URL "${OPTARG/*=/}"
			;;
		pip_vllm_version | PIP_VLLM_VERSION)
			set_env_var PIP_VLLM_VERSION "${OPTARG/*=/}"
			;;
		rocm_version | ROCM_VERSION)
			ROCM_VERSION="${OPTARG/*=/}"
			;;
		rorc_visible_devices | ROCR_VISIBLE_DEVICES)
			ROCR_VISIBLE_DEVICES="${OPTARG/*=/}"
			;;
		ubi_version | UBI_VERSION)
			UBI_VERSION="${OPTARG/*=/}"
			;;
		use_ccache | USE_CCACHE)
			set_env_var USE_CCACHE "${OPTARG/*=/}"
			;;
		uv_torch_backend | UV_TORCH_BACKEND)
			set_env_var UV_TORCH_BACKEND "${OPTARG/*=/}"
			;;
		vllm_commit | VLLM_COMMIT)
			set_env_var VLLM_COMMIT "${OPTARG/*=/}"
			;;
		*)
			echo "Unknown option ${OPTARG}."
			exit 1
			;;
		esac
		;;
	p)
		INSTALL_JUPYTER=true
		if [ "${OPTARG^^}" = "AUTO" ]; then
			JUPYTER_NOTEBOOK_PORT=$DEFAULT_PORT
		else
			JUPYTER_NOTEBOOK_PORT=$OPTARG
		fi
		;;
	r)
		IMAGE_REPO=$OPTARG
		;;
	s)
		case "${OPTARG/=*/}" in
		llvm | LLVM)
			LLVM_PATH="${OPTARG/*=/}"
			;;
		torch | TORCH)
			TORCH_PATH="${OPTARG/*=/}"
			;;
		triton | TRITON)
			TRITON_PATH="${OPTARG/*=/}"
			;;
		vllm | VLLM)
			VLLM_PATH="${OPTARG/*=/}"
			;;
		user | USER)
			USER_PATH="${OPTARG/*=/}"
			;;
		*)
			echo "Unknown source path $OPTARG"
			exit 1
			;;
		esac
		;;
	t)
		IMAGE_TAG=$OPTARG
		;;
	u)
		USERNAME=$OPTARG
		;;
	h)
		usage
		exit 0
		;;
	v)
		set -x
		;;
	*)
		echo "Unknown option $opt."
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

[ "${1:-}" = "--" ] && shift

if [ -z "${1:-}" ]; then
	echo "No DEVICE specified."
	usage
	exit 1
fi

TARGET_DEVICE="${1:-}"
IMAGE_NAME=$TARGET_DEVICE

##
## Command Configuration
##

# Container Runtime
set_container_runtime

# Setup Volumes
setup_volumes

# Device specific arguments (AMD, NVIDIA, etc)
set_device_opts

# Runtime Arguments
if [ "$(basename "$CTR_CMD")" = "podman" ]; then
	CTR_SECURITY_OPTS+=("--userns=keep-id")
fi

# Jupyter Notebook
if [ "${INSTALL_JUPYTER:-}" = "true" ]; then
	CTR_PORT_OPT="-p ${JUPYTER_NOTEBOOK_PORT:-$DEFAULT_PORT}:${JUPYTER_NOTEBOOK_PORT:-$DEFAULT_PORT}"
	set_env_var INSTALL_JUPYTER "$INSTALL_JUPYTER"
	set_env_var NOTEBOOK_PORT "${JUPYTER_NOTEBOOK_PORT:-$DEFAULT_PORT}"
fi

# Environment Arguments
set_env_var MAX_JOBS "$MAX_JOBS"

# User args
set_user_args

CTR_ARGS+=(
	"${CTR_ENV_OPTS[@]:-}"
	"${CTR_DEVICE_OPTS[@]:-}"
	"${CTR_PORT_OPT:-}"
	"${CTR_SECURITY_OPTS[@]:-}"
	"${CTR_VOLUME_OPTS[@]:-}"
)

if [ -n "${REMOTE_CONNECTION:-}" ]; then
	CTR_CONNECTION="-r -c $REMOTE_CONNECTION"
fi

if [ "${DELETE_ON_EXIT:-}" = "true" ]; then
	CTR_ARGS+=("--rm")
fi

printf "Running container image: %s/%s:%s with %s\n" "$IMAGE_REPO" "$IMAGE_NAME" \
	"${IMAGE_TAG:-ubi${UBI_VERSION}}" "$CTR_CMD"
printf "%s %s run -ti %s %s/%s:%s bash\n" "$CTR_CMD" "${CTR_CONNECTION:-}" \
	"${CTR_ARGS[*]}" "$IMAGE_REPO" "$IMAGE_NAME" "${IMAGE_TAG:-ubi${UBI_VERSION}}"
$CTR_CMD ${CTR_CONNECTION:-} run -ti ${CTR_ARGS[@]} \
	"${IMAGE_REPO}/${IMAGE_NAME}:${IMAGE_TAG:-ubi${UBI_VERSION}}" bash
