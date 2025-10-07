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

DEFAULT_UID=1000
USER_ID=${USER_UID:-1000}
GROUP_ID=${USER_GID:-1000}

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

install_sudo() {
	info "Installing and configuring sudo for $USER ..."
	dnf -y install sudo
	tee -a /etc/sudoers.d/${USER} <<EOF
# Enable the user account to run sudo without a password
$USER ALL=(ALL) NOPASSWD:ALL
EOF
}

# Function to update MAX_UID and MAX_GID in /etc/login.defs
update_max_uid_gid() {
	local current_max_uid
	local current_max_gid
	local current_min_uid
	local current_min_gid

	info "Updating max UID and GID ..."

	# Get current max UID and GID from /etc/login.defs
	current_max_uid=$(grep "^UID_MAX" /etc/login.defs | awk '{print $2}')
	current_max_gid=$(grep "^GID_MAX" /etc/login.defs | awk '{print $2}')
	current_min_uid=$(grep "^UID_MIN" /etc/login.defs | awk '{print $2}')
	current_min_gid=$(grep "^GID_MIN" /etc/login.defs | awk '{print $2}')

	# Check and update MAX_UID if necessary
	if [ "$USER_ID" -gt "$current_max_uid" ]; then
		echo "Updating UID_MAX from $current_max_uid to $USER_ID"
		sed -i "s/^UID_MAX.*/UID_MAX $USER_ID/" /etc/login.defs
	fi

	# Check and update MAX_GID if necessary
	if [ "$GROUP_ID" -gt "$current_max_gid" ]; then
		echo "Updating GID_MAX from $current_max_gid to $GROUP_ID"
		sed -i "s/^GID_MAX.*/GID_MAX $GROUP_ID/" /etc/login.defs
	fi

	# Check and update MIN_UID if necessary
	if [ "$USER_ID" -lt "$current_min_uid" ]; then
		echo "Updating UID_MIN from $current_min_uid to $USER_ID"
		sed -i "s/^UID_MIN.*/UID_MIN $USER_ID/" /etc/login.defs
	fi

	# Check and update MIN_GID if necessary
	if [ "$GROUP_ID" -lt "$current_min_gid" ]; then
		echo "Updating GID_MIN from $current_min_gid to $GROUP_ID"
		sed -i "s/^GID_MIN.*/GID_MIN $GROUP_ID/" /etc/login.defs
	fi
}

create_user() {
	# Create user if it doesn't exist
	if ! id -u "$USER" >/dev/null 2>&1; then
		echo "Creating user $USER with UID $USER_ID and GID $GROUP_ID"
		
		# Create group if it doesn't exist
		if ! getent group "$USER_GID" >/dev/null; then
		  groupadd --gid "$USER_GID" "$USER"
		else # modify the name
		  gname=$(getent group "$USER_GID" | cut -d: -f1)
		  groupmod -g "$USER_GID" -n "$USER" "$gname"
		fi

		# Check if the UID is in use
		if getent passwd "$USER_UID" >/dev/null; then
		  echo "Warning: UID $USER_UID is already in use. Creating the user with UID $DEFAULT_UID instead." >&2
		  USER_UID=$DEFAULT_UID
		fi

		# Create user if it doesn't exist
		if ! getent passwd "$USER" >/dev/null; then
		  useradd --uid "$USER_UID" --gid "$USER_GID" -m "$USER"
		fi

		# Add current (arbitrary) user to /etc/passwd and /etc/group
		if ! whoami >/dev/null 2>&1; then
		  if [ -w /etc/passwd ]; then
		    echo "update passwd file"
		    echo "${USER:-user}:x:$(id -u):0:${USER:-user} user:${HOME}:/bin/bash" >> /etc/passwd
		    echo "${USER:-user}:x:$(id -u):" >> /etc/group
		  fi
		fi

		# Fix up permissions
		chown "$USER:$USER_GID" -R "${HOME}"
		chown "$USER:$USER_GID" -R /opt
		chown "$USER:$USER_GID" -R ${WORKSPACE}
		mkdir -p "/run/user/$USER_UID"
		chown "$USER:$USER_GID" "/run/user/$USER_UID"
	fi
}

##
## Main
##

if [ -n "${USER:-}" ] && [ "${USER:-}" != "root" ]; then
	hdr "Creating user $USER ..."
	update_max_uid_gid
	create_user
	install_sudo
else
	hdr "No user specified or user is root, not creating a user ..."
fi
