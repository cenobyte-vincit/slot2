#!/usr/bin/env bash
#
# inject-kexec.sh - Copy host kexec and missing shared libs into an initrd main/ tree.
#
# Usage: inject-kexec.sh <path-to-main>
# Expects Amazon Linux 2023 layout (kexec from kexec-tools). Skips libraries
# already present under the tree so stock dracut libc/ld stay preferred.
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname} <path-to-main>" >&2

	exit 1
}

# Copy one absolute host path into tree at the same absolute path if missing.
copy_if_missing() {
	local -r host_path="${1}"
	local -r tree="${2}"
	local -r dest="${tree}${host_path}"
	local dest_dir=""

	[ -f "${host_path}" ] || \
		return 0

	[ -e "${dest}" ] && \
		return 0

	dest_dir="$(dirname -- "${dest}")"
	mkdir -p -- "${dest_dir}"
	cp -a -- "${host_path}" "${dest}"

	return 0
}

# Parse ldd lines; copy NEEDED shared objects and the dynamic linker if absent.
copy_ldd_deps() {
	local -r host_bin="${1}"
	local -r tree="${2}"
	local line=""
	local path=""

	while IFS= read -r line || [ -n "${line}" ]; do
		path=""
		if [[ "${line}" =~ \=\>\ (/[^[:space:]]+) ]]; then
			path="${BASH_REMATCH[1]}"
		elif [[ "${line}" =~ ^[[:space:]]*(/[^[:space:]]+/ld-linux[^[:space:]]*) ]]; then
			path="${BASH_REMATCH[1]}"
		fi

		[ -z "${path}" ] && \
			continue
		[ "${path}" = "not" ] && \
			continue

		copy_if_missing "${path}" "${tree}"
	done < <(ldd -- "${host_bin}" 2>/dev/null || true)

	return 0
}

main() {
	[[ "$#" -ne 1 ]] && \
		usage

	for bin in kexec ldd cp mkdir dirname; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r tree="${1}"
	local kexec_host=""
	local -r dest_bin="${tree}/usr/sbin/kexec"

	[ ! -d "${tree}" ] && \
		errx "main tree not found: ${tree}"

	kexec_host="$(command -v kexec)"
	[ ! -x "${kexec_host}" ] && \
		errx "kexec not executable: ${kexec_host}"

	mkdir -p -- "${tree}/usr/sbin"
	cp -f -- "${kexec_host}" "${dest_bin}"
	chmod 0755 -- "${dest_bin}"

	copy_ldd_deps "${kexec_host}" "${tree}"

	echo "${__progname}: installed ${dest_bin} (from ${kexec_host})"
	echo "${__progname}: shared libs copied only when missing under tree"
}

main "$@"
