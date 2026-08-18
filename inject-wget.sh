#!/usr/bin/env bash
#
# inject-wget.sh - Copy pinned busybox wget into an initrd main/ tree.
#
# Usage: inject-wget.sh <path-to-main>
# Expects busybox_WGET beside this script (fetched by install-dependencies.sh:
# static musl busybox 1.35.0 WGET applet). No shared libs required.
#
set -euo pipefail
IFS=$'\n\t'

readonly __script_path="${BASH_SOURCE[0]}"
# shellcheck disable=SC2155
readonly __progname="$(basename "${__script_path}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

readonly WGET_HOST_NAME="busybox_WGET"
readonly WGET_DEST_REL="usr/bin/wget"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname} <path-to-main>" >&2

	exit 1
}

main() {
	[[ "$#" -ne 1 ]] && \
		usage

	for bin in cp mkdir dirname chmod; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r tree="${1}"
	local -r repo_root="$(cd "$(dirname "${__script_path}")" && pwd)"
	local -r host_bin="${repo_root}/${WGET_HOST_NAME}"
	local -r dest_bin="${tree}/${WGET_DEST_REL}"
	local dest_dir=""

	[ ! -d "${tree}" ] && \
		errx "main tree not found: ${tree}"

	[ ! -f "${host_bin}" ] && \
		errx "missing ${host_bin} (run ./install-dependencies.sh)"
	[ ! -s "${host_bin}" ] && \
		errx "empty binary: ${host_bin}"

	dest_dir="$(dirname -- "${dest_bin}")"
	mkdir -p -- "${dest_dir}"
	cp -f -- "${host_bin}" "${dest_bin}"
	chmod 0755 -- "${dest_bin}"

	echo "${__progname}: installed ${dest_bin} (from ${host_bin})"
}

main "$@"
