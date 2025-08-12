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

## Jupyter notebook
jupyter_notebook=false
default_port=8888

## Image modifiers
custom_llvm=false
create_user=true
debugging_tools=false

gitconfig_path="${HOME}/.gitconfig"
hip_devices=${HIP_VISIBLE_DEVICES:-0}

declare -a ctr_env_opts
declare -a ctr_device_opts
declare -a ctr_security_opts
declare -a ctr_volume_opts

usage() {
	printf "Usage: %s [OPTION]... DEVICE\n" "$(basename "$0")"
	printf "\tDEVICE\t\tTarget device, [amd | cpu | nvidia].\n"
	printf "Options\n"
	printf "\t-r IMAGE_REPO\tImage repository (Default: %s)\n" "$image_repo"
	printf "\t-t IMAGE_TAG\tImage tag (Default: %s).\n" "$image_tag"
	printf "\t-s PATH\t\tA local project source directory.\n"
	printf "\t\t\t\tTRITON=/path/to/triton/source\n"
	printf "\t-u PATH\t\t/path/to/user/directory\n"
	printf "\t-j [AUTO|PORT]\tRun a Jupyter Notebook server.\n"
	printf "\t\t\t\t(Default: %d)\n" "$default_port"
	printf "\t-d\t\tEnable Triton debugging tools, i.e. profiling.\n"
	printf "\t-l\t\tUse a custom LLVM.\n"
	printf "\t-h\t\tPrint usage\n"
	printf "\t-v\t\tVerbose\n"
}

##
## MAIN
##
while getopts "r:t:s:u:j:dlhv" opt; do
	case "$opt" in
	r)
		image_repo=$OPTARG
		;;
	t)
		image_tag=$OPTARG
		;;
	s)
		case "${OPTARG/=*/}" in
		triton | TRITON)
			triton_path="${OPTARG/*=/}"
			;;
		*)
			echo "Unknown source path ${OPTARG}."
			exit 1
			;;
		esac
		;;
	u)
		user_path=$OPTARG
		;;
	j)
		jupyter_notebook=true
		if [ "${OPTARG^^}" = "AUTO" ]; then
			jupyter_notebook_port=$default_port
		else
			jupyter_notebook_port=$OPTARG
		fi
		;;
	d)
		debugging_tools=true
		;;
	l)
		custom_llvm=true
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

image_name="${1:-}"

# Container Runtime
if command -v podman &>/dev/null; then
	ctr_cmd=podman
elif command -v docker &>/dev/null; then
	ctr_cmd=docker
else
	echo "Could not find the podman or docker container runtime."
	echo "Please install one of them."
	exit 1
fi

# Set selinux volume flag if enforcing
if [ "$(getenforce 2>/dev/null)" == "Enforcing" ]; then
	selinux_flag=:z
fi

# Get latest PyTorch release version
torch_version=$(curl -s https://api.github.com/repos/pytorch/pytorch/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": "v?([^\"]+)".*/\1/')

echo "Running container image: ${image_repo}/${image_name}:${image_tag} with ${ctr_cmd}"

# Setup Volumes
## Add a local Triton source path if one exists
if [ -n "${triton_path:-}" ]; then
	ctr_volume_opts+=("-v ${triton_path}:/workspace/triton${selinux_flag:-}")
fi

## Add a user path if one is specified (should verify it exists)
if [ -n "${user_path:-}" ]; then
	ctr_volume_opts+=("-v ${user_path}:/workspace/user${selinux_flag:-}")
fi

## User management for non-Mac OS's
if [ "$(uname -s)" != "Darwin" ] && ! getent passwd "$USER" >/dev/null && [ "$create_user" = "false" ]; then
	ctr_volume_opts+=("-v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro")
fi

## Gitconfig
if [ -f "${gitconfig_path:-}" ]; then
	ctr_volume_opts+=("-v ${gitconfig_path}:/etc/gitconfig${selinux_flag:-}")
fi

## Device specific arguments (AMD, NVIDIA, etc)
case $image_name in
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
		"-e HIP_VISIBLE_DEVICES=${hip_devices}"
	)
	;;
nvidia)
	if command -v nvidia-ctk >/dev/null 2>&1 && nvidia-ctk cdi list | grep -q "nvidia.com/gpu=all"; then
		ctr_device_opts+=("--device nvidia.com/gpu=all")
	else
		ctr_device_opts+=("--runtime=nvidia --gpus=all")
	fi

	ctr_security_opts+=("--security-opt label=disable")

	if [ "$debugging_tools" = "true" ]; then
		ctr_env_opts+=(
			"-e DISPLAY=${DISPLAY}"
			"-e WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
			"-e XDG_RUNTIME_DIR=/tmp"
			"-e INSTALL_NSIGHT=true"
		)
		ctr_security_opts+=(
			"--privileged"
			"--cap-add=SYS_ADMIN"
		)
		ctr_volume_opts+=(
			"-v ${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:/tmp/${WAYLAND_DISPLAY}:ro"
		)
	fi
	;;
esac

## Runtime Arguments
if [ "$(basename "$ctr_cmd")" = "podman" ]; then
	ctr_security_opts+=("--userns=keep-id")
fi

## Jupyter Notebook
if [ "$jupyter_notebook" = "true" ]; then
	ctr_port_opt="-p ${jupyter_notebook_port}:${jupyter_notebook_port}"
	ctr_env_opts+=(
		"-e DEMO_TOOLS=$jupyter_notebook"
		"-e NOTEBOOK_PORT=$jupyter_notebook_port"
	)
fi

## Environment Arguments
ctr_env_opts=(
ctr_env_opts+=(
	"-e USERNAME=$USER"
	"-e TORCH_VERSION=$torch_version"
	"-e CUSTOM_LLVM=$custom_llvm"
)

## Execution
if [ "$create_user" = "true" ]; then
	ctr_args=(
		"-e CREATE_USER=$create_user"
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

ctr_args+=(
	"${ctr_env_opts[@]}"
	"${ctr_env_opts[@]:-}"
	"${ctr_device_opts[@]:-}"
	"${ctr_port_opt:-}"
	"${ctr_security_opts[@]:-}"
	"${ctr_volume_opts[@]:-}"
)

echo "$ctr_cmd run -ti ${ctr_args[*]} ${image_repo}/${image_name}:${image_tag} bash"
$ctr_cmd run -ti ${ctr_args[@]} "${image_repo}/${image_name}:${image_tag}" bash
