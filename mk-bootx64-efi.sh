#!/usr/bin/env bash
#
# mk-bootx64-efi.sh - Build BOOTX64.EFI that chainloads a UKI via GRUB.
#
# Stages GRUB modules, strips them safely for size, writes a generated early
# config, and invokes grub2-mkimage. The embedded early config finds
# /var/lib/systemd/boot/uki.efi with search.file, probes that filesystem's UUID,
# and chainloads the UKI with portable cmdline extras plus root=UUID=... as
# EFI LoadOptions.
# (The AL2023 systemd stub was observed to apply chainloader LoadOptions as the
# effective kernel cmdline; root UUID must stay runtime-probed, not baked in.)
# Always writes ./BOOTX64.EFI. Does not install to the ESP.
#
# Restricted to Amazon Linux 2023 because this script depends on that distro's
# GRUB packaging and layout: grub2-mkimage, and the x86_64-efi module tree
# (kernel.img, moddep.lst, *.mod under /usr/lib/grub/x86_64-efi from
# grub2-efi-x64-modules), including chain and probe.
#
# Secure Boot is out of scope: stock EC2 instances boot with Secure Boot off,
# so this image is unsigned and is not part of a verified-boot design.
#
# Build the UKI first with mk-uki.sh (./uki.efi; ./deploy installs it to
# /var/lib/systemd/boot/uki.efi where this image will search.file it).
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Default module source (Amazon Linux / Fedora layout).
readonly DEFAULT_MODDIR="/usr/lib/grub/x86_64-efi"
readonly OUTPUT_NAME="BOOTX64.EFI"
readonly DEFAULT_FORMAT="x86_64-efi"

# Path of the UKI on the *target* root filesystem (what GRUB search.file finds).
# Must match DEPLOY_UKI in deploy.c (install location under /var/lib/systemd/boot).
readonly UKI_PATH="/var/lib/systemd/boot/uki.efi"

# Portable extras (must match mk-uki.sh LINUX_CMDLINE). No root=UUID= here —
# that is probed at boot and appended on the chainloader line.
# BOOTKIT_MARKER: stage-1 proof token so /proc/cmdline shows the UKI payload ran.
readonly UKI_CMDLINE_EXTRA="ro console=tty0 console=ttyS0,115200n8 BOOTKIT_MARKER=1"

# grub2-mkimage requires -p and embeds it as OBJ_TYPE_PREFIX. On the happy path
# (modules + -c early config ending in chainloader/boot) GRUB never uses $prefix.
# If the early config fails or returns, normal mode starts and opens
# $prefix/grub.cfg — that is the only case this value matters.
readonly MKIMAGE_PREFIX="/EFI/BOOT"

# GPT + XFS + search.file + probe (runtime root UUID) + chainloader + boot.
readonly -a MODULES=(
	part_gpt
	xfs
	search
	search_fs_file
	probe
	chain
	boot
	echo
	reboot
	gzio
)

# Early-config template. Placeholder __UKI__ is substituted at build time
# (path on the target root filesystem, not necessarily present on the build host).
#
# search.file sets $root to the first device that contains __UKI__.
# probe --set=rootuuid --fs-uuid $root reads that filesystem's UUID at boot.
# chainloader passes portable extras + root=UUID=$rootuuid as EFI LoadOptions
# (stock EC2 Secure Boot off; this is what shows up in /proc/cmdline).
# shellcheck disable=SC2016
readonly GRUB_CFG_TEMPLATE='search.file __UKI__ root
set no_modules=y
probe --set=rootuuid --fs-uuid $root
chainloader __UKI__ '"${UKI_CMDLINE_EXTRA}"' root=UUID=$rootuuid
boot
'

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname}" >&2
	echo -e "  embeds early config: search ${UKI_PATH}, probe UUID, chainload + root=" >&2
	echo -e "  writes ./${OUTPUT_NAME} in the current directory" >&2

	exit 1
}

# Resolve moddep.lst dependencies into name_list (nameref to an array of names).
resolve_module_deps() {
	local -r moddep="${1}"
	local -n name_list="${2}"
	shift 2

	local -A seen=()
	local -a queue=()
	local -a dep_arr=()
	local name=""
	local line=""
	local dep=""
	local deps=""

	for name in "$@"; do
		queue+=("${name}")
	done

	while [ "${#queue[@]}" -gt 0 ]; do
		name="${queue[0]}"
		queue=("${queue[@]:1}")

		[ -n "${seen[${name}]+x}" ] && \
			continue

		seen["${name}"]=1
		name_list+=("${name}")

		line="$(grep -E "^${name}:" -- "${moddep}" 2>/dev/null || true)"
		[ -z "${line}" ] && \
			continue

		deps="${line#*:}"
		# Global IFS is newline/tab only; split dep fields on spaces explicitly.
		dep_arr=()
		IFS=' ' read -r -a dep_arr <<< "${deps}"
		for dep in "${dep_arr[@]}"; do
			dep="${dep//$'\r'/}"
			[ -z "${dep}" ] && \
				continue
			[ -n "${seen[${dep}]+x}" ] && \
				continue
			queue+=("${dep}")
		done
	done

	return 0
}

# Copy one module and strip it the way GRUB's genmod.sh does (safe for dl load).
stage_module() {
	local -r src_mod="${1}"
	local -r dst_mod="${2}"

	cp -f -- "${src_mod}" "${dst_mod}"

	# Keep modname/moddeps/relocs and grub_mod_{init,fini}; drop unneeded symbols.
	strip --strip-unneeded \
		-K grub_mod_init -K grub_mod_fini \
		-K _grub_mod_init -K _grub_mod_fini \
		-R .note.GNU-stack \
		-R .note.gnu.gold-version \
		-R .note.gnu.property \
		-R .gnu.build.attributes \
		-R .rel.gnu.build.attributes \
		-R .rela.gnu.build.attributes \
		-R .eh_frame -R .rela.eh_frame -R .rel.eh_frame \
		-R .note -R .comment \
		-- "${dst_mod}" 2>/dev/null || \
		strip --strip-unneeded \
			-K grub_mod_init -K grub_mod_fini \
			-K _grub_mod_init -K _grub_mod_fini \
			-- "${dst_mod}"
}

# Expand GRUB_CFG_TEMPLATE and write the early config for grub2-mkimage -c.
write_embedded_cfg() {
	local -r out="${1}"
	local -r uki="${2}"
	local cfg=""

	cfg="${GRUB_CFG_TEMPLATE//__UKI__/${uki}}"

	printf '%s\n' "${cfg}" >"${out}"
}

# Require Amazon Linux 2023 (grub2-mkimage + /usr/lib/grub/x86_64-efi modules).
require_amazon_linux_2023() {
	local id=""
	local version_id=""

	[ "$(uname -s)" != "Linux" ] && \
		errx "Linux required (uname -s reported '$(uname -s)')"

	[ ! -r /etc/os-release ] && \
		errx "cannot read /etc/os-release"

	# shellcheck disable=SC1091
	. /etc/os-release

	id="${ID:-}"
	version_id="${VERSION_ID:-}"

	[ "${id}" != "amzn" ] && \
		errx "Amazon Linux required (os-release ID='${id:-unknown}')"

	[ "${version_id}" != "2023" ] && \
		errx "Amazon Linux 2023 required (os-release VERSION_ID='${version_id:-unknown}')"

	# Last guard is a false [ ] && on the happy path (status 1); force success under set -e.
	return 0
}

# Join array elements with spaces (global IFS is newline/tab, so [*] is wrong).
join_spaces() {
	local e=""
	local first=1

	for e in "$@"; do
		if [ "${first}" -eq 1 ]; then
			printf '%s' "${e}"
			first=0
		else
			printf ' %s' "${e}"
		fi
	done
	echo
}

main() {
	[[ "$#" -ne 0 ]] && \
		usage

	local -r moddir="${DEFAULT_MODDIR}"
	local -r uki_path="${UKI_PATH}"

	require_amazon_linux_2023

	for bin in grub2-mkimage strip mktemp cp grep; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	[ ! -d "${moddir}" ] && \
		errx "module directory not found: ${moddir} (run install-dependencies.sh?)"

	[ ! -f "${moddir}/kernel.img" ] && \
		errx "missing ${moddir}/kernel.img (install grub2-efi-x64-modules?)"

	[ ! -f "${moddir}/moddep.lst" ] && \
		errx "missing ${moddir}/moddep.lst"

	[ ! -f "${moddir}/chain.mod" ] && \
		errx "missing ${moddir}/chain.mod (required for chainloader)"

	# Global so the EXIT trap can still remove the dir after main returns.
	tmpdir=""
	local -a resolved=()
	local name=""
	local src=""
	local dst=""
	local cfg_dst=""
	local out_abs=""
	local after=""

	echo "${__progname}: building ${OUTPUT_NAME} (format ${DEFAULT_FORMAT})"
	echo "${__progname}: UKI path (on target root FS): ${uki_path}"
	echo "${__progname}: module source: ${moddir}"

	trap '[ -n "${tmpdir}" ] && rm -rf -- "${tmpdir}"' EXIT

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	echo "${__progname}: staging in ${tmpdir}"

	# mkimage reads kernel + moddep + *.mod only from -d.
	cp -f -- "${moddir}/kernel.img" "${tmpdir}/kernel.img"
	cp -f -- "${moddir}/moddep.lst" "${tmpdir}/moddep.lst"
	echo "${__progname}: copied kernel.img and moddep.lst"

	resolve_module_deps "${moddir}/moddep.lst" resolved "${MODULES[@]}"

	[ "${#resolved[@]}" -eq 0 ] && \
		errx "no modules resolved"

	printf '%s: requested modules: ' "${__progname}"
	join_spaces "${MODULES[@]}"
	printf '%s: dependency-closed set (%d): ' "${__progname}" "${#resolved[@]}"
	join_spaces "${resolved[@]}"
	echo "${__progname}: copying and stripping modules"

	for name in "${resolved[@]}"; do
		src="${moddir}/${name}.mod"
		dst="${tmpdir}/${name}.mod"

		[ ! -f "${src}" ] && \
			errx "module not found: ${src}"

		stage_module "${src}" "${dst}"
	done

	cfg_dst="${tmpdir}/embedded.cfg"
	write_embedded_cfg "${cfg_dst}" "${uki_path}"
	echo "${__progname}: embedded early config:"
	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && \
			continue
		echo "${__progname}:   ${line}"
	done <"${cfg_dst}"

	out_abs="$(pwd)/${OUTPUT_NAME}"

	echo "${__progname}: running grub2-mkimage -O ${DEFAULT_FORMAT} -p ${MKIMAGE_PREFIX}"
	grub2-mkimage \
		-O "${DEFAULT_FORMAT}" \
		-o "${out_abs}" \
		-c "${cfg_dst}" \
		-d "${tmpdir}" \
		-p "${MKIMAGE_PREFIX}" \
		"${MODULES[@]}"

	after="$(stat -c '%s' -- "${out_abs}")"

	echo "${__progname}: done"
	echo "${__progname}:   output:  ${out_abs}"
	echo "${__progname}:   size:    ${after} bytes"
	printf '%s:   modules: ' "${__progname}"
	join_spaces "${resolved[@]}"
}

main "$@"
