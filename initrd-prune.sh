#!/usr/bin/env bash
#
# initrd-prune.sh - Remove rescue/debug paths from an initrd main/ tree.
#
# Drops unused CLIs so the packed initrd (and thus the UKI) is smaller.
# Usage: initrd-prune.sh <path-to-main>
# Runs after inject-*.sh and before initrd-packer.sh pack.
#
# High-confidence removals only: CLIs not used by 98-payload.sh,
# 99-kexec-stock.sh, or the stock systemd/dracut path to pre-pivot + kexec.
# Missing paths are skipped (stock initrd content varies).
#
# Do not add: bash, sh, mount, coreutils used by hooks, kmod/modprobe/insmod,
# udevadm, systemd daemons, kexec, udhcpc, wget, blkid, or FS modules.
# Optional later (test boot first): systemctl, systemd-ask-password,
# systemd-tty-ask-password-agent, systemd-tmpfiles, systemd-sysusers.
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Paths relative to main/ (no leading slash).
readonly -a PRUNE_PATHS=(
	# Largest / clear wins
	usr/libexec/vi
	usr/bin/less
	# systemd / udev debug CLI (daemons stay)
	usr/bin/journalctl
	usr/bin/systemd-cgls
	usr/bin/systemd-escape
	usr/bin/systemd-run
	usr/bin/ps
	usr/bin/dmesg
	# Unused daemons / admin toys
	usr/sbin/rngd
	usr/bin/keyctl
)

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname} <path-to-main>" >&2

	exit 1
}

# True if rel path is safe under tree (no absolute, no .. components).
path_is_safe() {
	local -r rel="${1}"

	[ -n "${rel}" ] || \
		return 1
	[[ "${rel}" == /* ]] && \
		return 1
	[[ "${rel}" == *..* ]] && \
		return 1

	return 0
}

# Unlink one relative path under tree. Prints: removed|missing <bytes> <rel>
# Unsafe paths call errx.
prune_one() {
	local -r tree="${1}"
	local -r rel="${2}"
	local -r target="${tree}/${rel}"
	local sz=0

	if ! path_is_safe "${rel}"; then
		errx "refusing unsafe path in PRUNE_PATHS: ${rel}"
	fi

	if [ ! -e "${target}" ] && [ ! -L "${target}" ]; then
		# Tab-separated: global IFS is newline/tab only (no space).
		printf 'missing\t0\t%s\n' "${rel}"
		return 0
	fi

	if [ -f "${target}" ] || [ -L "${target}" ]; then
		sz="$(stat -c '%s' -- "${target}" 2>/dev/null || echo 0)"
	elif [ -d "${target}" ]; then
		sz="$(du -sb -- "${target}" 2>/dev/null | awk '{print $1}' || echo 0)"
	fi

	rm -rf -- "${target}"
	printf 'removed\t%s\t%s\n' "${sz}" "${rel}"
	return 0
}

main() {
	[[ "$#" -ne 1 ]] && \
		usage

	for bin in rm stat awk; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r tree="${1}"
	local rel=""
	local status=""
	local sz=0
	local removed=0
	local missing=0
	local bytes=0
	local total_before=0
	local i=0
	local out=""

	[ ! -d "${tree}" ] && \
		errx "main tree not found: ${tree}"

	[ "${#PRUNE_PATHS[@]}" -eq 0 ] && \
		errx "PRUNE_PATHS is empty"

	total_before="$(du -sb -- "${tree}" 2>/dev/null | awk '{print $1}' || echo 0)"

	echo "${__progname}: tree=${tree}"
	echo "${__progname}: entries=${#PRUNE_PATHS[@]}"

	for ((i = 0; i < ${#PRUNE_PATHS[@]}; i++)); do
		rel="${PRUNE_PATHS[i]}"
		out="$(prune_one "${tree}" "${rel}")"
		read -r status sz rel <<<"${out}"

		case "${status}" in
		removed)
			removed=$((removed + 1))
			bytes=$((bytes + sz))
			echo "${__progname}: removed ${rel} (${sz} bytes)"
			;;
		missing)
			missing=$((missing + 1))
			echo "${__progname}: missing ${rel} (ok)"
			;;
		*)
			errx "internal status from prune_one: ${status}"
			;;
		esac
	done

	echo "${__progname}: removed=${removed} missing=${missing}" \
		"bytes_unlinked=${bytes} tree_before=${total_before}"
}

main "$@"
