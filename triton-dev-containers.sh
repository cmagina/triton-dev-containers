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
image_repo=quay.io/triton-dev-containers
image_tag=latest
framework=triton

## Image versions
ubi_version=9
cuda_version=12-9
rocm_version=6.3.3

gitconfig_path="${HOME}/.gitconfig"
rocr_devices=${ROCR_VISIBLE_DEVICES:-0}

## Jupyter notebook
jupyter_notebook=false
default_port=8888

## Image modifiers
dbg_tools=false
max_jobs=$(nproc --all)

# Container runtime command option arrays
declare -a ctr_env_opts
declare -a ctr_device_opts
declare -a ctr_security_opts
declare -a ctr_volume_opts

usage() {
	printf "Usage: %s [OPTION]... IMAGE_NAME\n" "$(basename "$0")"
	printf "\tDEVICE\t\t\tTarget device, [ amd | cpu | nvidia ]\n"
	printf "Options\n"
	printf "\t-d\t\t\tInstall debugging and analysis tools (i.e. NVIDIA Nsight)\n"
	printf "\t-f FRAMEWORK\t\tImage for specific framework dev [ triton* | torch | vllm ] (Default: %s)\n" "$framework"
	printf "\t-j MAX_JOBS\t\tMaximum number of jobs to use when building Triton/PyTorch/vLLM (Default: %d)\n" "$max_jobs"
	printf "\t-o OPTION=ARGUMENT\tSpecify a value for an option\n"
	printf "\t\t\t\t\tUBI_VERSION=Ubi image version [ 9 | 10 ]\n"
	printf "\t\t\t\t\tCUDA_VERSION=CUDA version (i.e. 12-9)\n"
	printf "\t\t\t\t\tROCM_VERSION=ROCm version (i.e. 6.4.4)\n"
	printf "\t\t\t\t\tGITCONFIG=/path/to/.gitconfig\n"
	printf "\t-p [AUTO|PORT]\t\tExpose the specified port for the Jupyter notebook server (AUTO: %d)\n" "$default_port"
	printf "\t-r IMAGE_REPO\t\tImage repository (Default: %s)\n" "$image_repo"
	printf "\t-s SOURCE\t\tLocal source directories to mount as volumes\n"
	printf "\t\t\t\t\tLLVM=/path/to/llvm/source\n"
	printf "\t\t\t\t\tTORCH=/path/to/torch/source\n"
	printf "\t\t\t\t\tTRITON=/path/to/triton/source\n"
	printf "\t\t\t\t\tUSER=/path/to/user/source\n"
	printf "\t\t\t\t\tVLLM=/path/to/vllm/source\n"
	printf "\t-t IMAGE_TAG\t\tImage tag (Default: %s)\n" "$image_tag"
	printf "\t-u USERNAME\t\tUsername to use inside the image\n"
	printf "\t-h\t\t\tPrint usage\n"
	printf "\t-v\t\t\tVerbose\n"
}

set_container_runtime() {
	if command -v podman &>/dev/null; then
		ctr_cmd=podman
	elif command -v docker &>/dev/null; then
		ctr_cmd=docker
	else
		echo "Could not find the podman or docker container runtime."
		echo "Please install one of them."
		exit 1
	fi
}

setup_volumes() {
	# Set selinux volume flag if enforcing
	if command -v getenforce &>/dev/null && [ "$(getenforce 2>/dev/null)" == "Enforcing" ]; then
		selinux_flag=:z
	fi

	# Custom LLVM source code path
	if [ -n "${llvm_path:-}" ]; then
		if [ -d "${llvm_path:-}" ]; then
			ctr_volume_opts+=("-v ${llvm_path}:/workspace/llvm-project${selinux_flag:-}")
			ctr_env_opts+=("-e INSTALL_LLVM=source")
		else
			echo "Specified LLVM path does not exist."
			exit 1
		fi
	fi

	# Triton Lang source code path
	if [ -n "${triton_path:-}" ]; then
		if [ -d "${triton_path:-}" ]; then
			ctr_volume_opts+=("-v ${triton_path}:/workspace/triton${selinux_flag:-}")
			ctr_env_opts+=("-e INSTALL_TRITON=source")
		else
			echo "Specified triton path does not exist."
			exit 1
		fi
	fi

	# PyTorch source code path
	if [ -n "${torch_path:-}" ]; then
		if [ -d "${torch_path:-}" ]; then
			ctr_volume_opts+=("-v ${torch_path}:/workspace/torch${selinux_flag:-}")
			ctr_env_opts+=("-e INSTALL_TORCH=source")
		else
			echo "Specified torch path does not exist."
			exit 1
		fi
	fi

	# vLLM source code path
	if [ -n "${vllm_path:-}" ]; then
		if [ -d "${vllm_path:-}" ]; then
			ctr_volume_opts+=("-v ${vllm_path}:/workspace/vllm${selinux_flag:-}")
			ctr_env_opts+=("-e INSTALL_VLLM=source")
		else
			echo "Specified vllm path does not exist."
			exit 1
		fi
	fi

	# Add a user path if one is specified (should verify it exists)
	if [ -n "${user_path:-}" ]; then
		if [ -d "${user_path:-}" ]; then
			ctr_volume_opts+=("-v ${user_path}:/workspace/user${selinux_flag:-}")
		else
			echo "Specified user path does not exist."
			exit 1
		fi
	fi

	# User management for non-Mac OS's
	if [ "$(uname -s)" != "Darwin" ] && ! getent passwd "$USER" >/dev/null && [ -n "${username:-}" ]; then
		ctr_volume_opts+=("-v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro")
	fi

	# Gitconfig
	if [ -f "${gitconfig_path:-}" ]; then
		ctr_volume_opts+=("-v ${gitconfig_path}:/etc/gitconfig${selinux_flag:-}")
	fi
}

set_device_opts() {
	case $target_device in
	amd)
		ctr_device_opts+=(
			"--device=/dev/kfd"
			"--device=/dev/dri"
		)
		ctr_security_opts+=(
			"--cap-add=SYS_PTRACE"
			"--group-add=video"
			"--ipc=host"
			"--security-opt seccomp=unconfined"
		)
		ctr_env_opts+=(
			"-e ROCR_VISIBLE_DEVICES=${rocr_devices}"
		)

		image_name=${image_name}-${rocm_version}
		;;
	nvidia)
		if command -v nvidia-ctk >/dev/null 2>&1 && nvidia-ctk cdi list | grep -q "nvidia.com/gpu=all"; then
			ctr_device_opts+=("--device nvidia.com/gpu=all")
		else
			ctr_device_opts+=("--runtime=nvidia --gpus=all")
		fi

		ctr_security_opts+=("--security-opt label=disable")

		if [ "$dbg_tools" = "true" ]; then
			ctr_env_opts+=(
				"-e INSTALL_TOOLS=true"
			)

			ctr_security_opts+=(
				"--privileged"
				"--cap-add=SYS_ADMIN"
			)

			if [ -n "${DISPLAY:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
				ctr_env_opts+=(
					"-e DISPLAY=${DISPLAY}"
					"-e WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
					"-e XDG_RUNTIME_DIR=/tmp"
				)
				ctr_volume_opts+=(
					"-v ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/tmp/${WAYLAND_DISPLAY}:ro"
				)
			else
				echo "WARNING: No DISPLAY or WAYLAND_DISPLAY configured"
			fi
		fi

		image_name=${image_name}-${cuda_version}
		;;
	esac
}

set_user_args() {
	if [ -z "${username:-}" ] && [ "$(whoami)" != "root" ]; then
		username=$(whoami)
	fi

	if [ -n "${username:-}" ] && [ "${username:-}" != "root" ]; then
		ctr_args=(
			"-e USER=$username"
			"-e USER_UID=$(id -u "$USER")"
			"-e USER_GID=$(id -g "$USER")"
		)
	elif [ "$(basename "$ctr_cmd")" = "docker" ]; then
		ctr_args=(
			"--user $(id -u):$(id -g)"
		)
	elif [ "$(basename "$ctr_cmd")" = "podman" ]; then
		ctr_args=(
			"--user $USER"
		)
	fi
}

##
## MAIN
##

while getopts "c:df:j:o:p:r:s:t:u:hv" opt; do
	case "$opt" in
	c)
		remote_connection=$OPTARG
		;;
	d)
		dbg_tools=true
		;;
	f)
		framework=${OPTARG}
		;;
	j)
		max_jobs=$OPTARG
		;;
	o)
		case "${OPTARG/=*/}" in
		ubi_version | UBI_VERSION)
			ubi_version="${OPTARG/*=/}"
			;;
		cuda_version | CUDA_VERSION)
			cuda_version="${OPTARG/*=/}"
			;;
		rocm_version | ROCM_VERSION)
			rocm_version="${OPTARG/*=/}"
			;;
		gitconfig | GITCONFIG)
			gitconfig_path="${OPTARG/*=/}"
			;;
		*)
			echo "Unknown option ${OPTARG}."
			exit 1
			;;
		esac
		;;
	p)
		jupyter_notebook=true
		if [ "${OPTARG^^}" = "AUTO" ]; then
			jupyter_notebook_port=$default_port
		else
			jupyter_notebook_port=$OPTARG
		fi
		;;
	r)
		image_repo=$OPTARG
		;;
	s)
		case "${OPTARG/=*/}" in
		llvm | LLVM)
			llvm_path="${OPTARG/*=/}"
			;;
		triton | TRITON)
			triton_path="${OPTARG/*=/}"
			;;
		torch | TORCH)
			torch_path="${OPTARG/*=/}"
			;;
		vllm | VLLM)
			vllm_path="${OPTARG/*=/}"
			;;
		user | USER)
			user_path="${OPTARG/*=/}"
			;;
		*)
			echo "Unknown source path ${OPTARG}."
			exit 1
			;;
		esac
		;;
	t)
		image_tag=$OPTARG
		;;
	u)
		username=$OPTARG
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

target_device="${1:-}"
image_name=ubi${ubi_version}-${target_device}

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
if [ "$(basename "$ctr_cmd")" = "podman" ]; then
	ctr_security_opts+=("--userns=keep-id")
fi

# Jupyter Notebook
ctr_port_opt="-p ${jupyter_notebook_port:-$default_port}:${jupyter_notebook_port:-$default_port}"
ctr_env_opts+=("-e NOTEBOOK_PORT=${jupyter_notebook_port:-$default_port}")

# Environment Arguments
# "-e TORCH_VERSION=$torch_version"
ctr_env_opts+=(
	"-e MAX_JOBS=$max_jobs"
)

# User args
set_user_args

ctr_args+=(
	"${ctr_env_opts[@]:-}"
	"${ctr_device_opts[@]:-}"
	"${ctr_port_opt:-}"
	"${ctr_security_opts[@]:-}"
	"${ctr_volume_opts[@]:-}"
)

if [ -n "${remote_connection:-}" ]; then
	ctr_connection="-r -c $remote_connection"
fi

printf "Running container image: %s/%s-%s:%s with %s\n" "$image_repo" "$image_name" "$framework" "$image_tag" "$ctr_cmd"
printf "%s %s run -ti %s %s/%s-%s:%s bash\n" "$ctr_cmd" "${ctr_connection:-}" "${ctr_args[*]}" "$image_repo" "$image_name" "$framework" "$image_tag"
$ctr_cmd ${ctr_connection:-} run -ti ${ctr_args[@]} "${image_repo}/${image_name}-${framework}:${image_tag}" bash
