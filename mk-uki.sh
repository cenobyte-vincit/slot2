#!/usr/bin/env bash
#
# mk-uki.sh - Assemble a Unified Kernel Image (UKI) on Amazon Linux 2023.
#
# Packs kernel + initrd + portable PE .cmdline onto the systemd linuxx64 EFI
# stub with objcopy (default). Optional --method dracut uses dracut --uefi then
# repacks onto the stub so .cmdline is correct (dracut does not reliably set it).
# Root is supplied at boot by mk-bootx64-efi.sh (GRUB probe + LoadOptions).
#
# Default output: ./uki.efi (current working directory). Does not modify the ESP
# or NVRAM; use ./deploy -y to install to /var/lib/systemd/boot/uki.efi.
#
# Secure Boot is out of scope: stock EC2 instances boot with Secure Boot off.
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Fixed basename and default stage path (not versioned; not on the tiny ESP).
readonly UKI_BASENAME="uki.efi"
# Build product in the caller's cwd; ./deploy installs to /var/lib/systemd/boot/.
readonly DEFAULT_OUTPUT="${UKI_BASENAME}"

# Portable PE .cmdline only — no host-specific root=. GRUB passes root=UUID=...
# via EFI LoadOptions at chainload time (see mk-bootx64-efi.sh).
# BOOTKIT_MARKER: stage-1 proof token in PE .cmdline (must match mk-bootx64-efi.sh LoadOptions extras).
readonly LINUX_CMDLINE="ro console=tty0 console=ttyS0,115200n8 BOOTKIT_MARKER=1"

readonly -a STUB_CANDIDATES=(
	/usr/lib/systemd/boot/efi/linuxx64.efi.stub
	/lib/systemd/boot/efi/linuxx64.efi.stub
)

# systemd EFI stub PE section layout (systemd ~252 / common ukify offsets).
readonly OBJCOPY_OSREL_VMA="0x20000"
readonly OBJCOPY_CMDLINE_VMA="0x30000"
readonly OBJCOPY_LINUX_VMA="0x2000000"
readonly OBJCOPY_INITRD_VMA="0x3000000"
# PE section flags required for the stub to see payload (not just a header name).
readonly OBJCOPY_SEC_FLAGS="contents,alloc,load,readonly,data"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname} [--kver <version>] [--linux <vmlinuz>]" >&2
	echo -e "       [--initrd <img>] [--output <path>] [--method auto|objcopy|dracut]" >&2
	echo -e "  default output: ${DEFAULT_OUTPUT}" >&2
	echo -e "  default method: auto (objcopy pack; reliable .cmdline)" >&2
	echo -e "  default linux/initrd: /boot/vmlinuz-<kver> and /boot/initramfs-<kver>.img" >&2

	exit 1
}

# Require Amazon Linux 2023 (dracut packaging and stub paths match this distro).
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

	return 0
}

# Locate the systemd EFI stub for packing.
find_stub() {
	local p=""

	for p in "${STUB_CANDIDATES[@]}"; do
		if [ -f "${p}" ]; then
			printf '%s\n' "${p}"
			return 0
		fi
	done

	return 1
}

# True if BOOTKIT_MARKER=1 bytes appear in the PE (grep -a: do not trust plain strings).
uki_has_cmdline_marker() {
	local -r uki="${1}"

	grep -aF 'BOOTKIT_MARKER=1' -- "${uki}" >/dev/null 2>&1
}

# Pack os-release, cmdline, linux, initrd onto stub -> out (objcopy + section flags).
objcopy_pack_uki() {
	local -r stub="${1}"
	local -r osrel="${2}"
	local -r cmdline_file="${3}"
	local -r linux="${4}"
	local -r initrd="${5}"
	local -r out="${6}"

	[ ! -f "${stub}" ] && \
		errx "stub not found: ${stub}"
	[ ! -f "${osrel}" ] && \
		errx "os-release not found: ${osrel}"
	[ ! -f "${cmdline_file}" ] && \
		errx "cmdline file not found: ${cmdline_file}"
	[ ! -f "${linux}" ] && \
		errx "kernel image not found: ${linux}"
	[ ! -f "${initrd}" ] && \
		errx "initrd not found: ${initrd}"

	# Write to a temp name then mv so a failed pack never leaves a half file at out.
	objcopy \
		--add-section ".osrel=${osrel}" \
		--change-section-vma ".osrel=${OBJCOPY_OSREL_VMA}" \
		--set-section-flags ".osrel=${OBJCOPY_SEC_FLAGS}" \
		--add-section ".cmdline=${cmdline_file}" \
		--change-section-vma ".cmdline=${OBJCOPY_CMDLINE_VMA}" \
		--set-section-flags ".cmdline=${OBJCOPY_SEC_FLAGS}" \
		--add-section ".linux=${linux}" \
		--change-section-vma ".linux=${OBJCOPY_LINUX_VMA}" \
		--set-section-flags ".linux=${OBJCOPY_SEC_FLAGS}" \
		--add-section ".initrd=${initrd}" \
		--change-section-vma ".initrd=${OBJCOPY_INITRD_VMA}" \
		--set-section-flags ".initrd=${OBJCOPY_SEC_FLAGS}" \
		-- "${stub}" "${out}.new"

	[ -s "${out}.new" ] || \
		errx "objcopy produced empty UKI: ${out}.new"

	mv -f -- "${out}.new" "${out}"
}

# Assemble UKI from kernel + initrd files + portable cmdline via objcopy.
build_with_objcopy() {
	local -r out="${1}"
	local -r linux="${2}"
	local -r initrd="${3}"
	local -r cmdline="${4}"
	local -r stub="${5}"
	local tmpdir=""
	local osrel=""
	local cmdline_file=""

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	osrel="${tmpdir}/os-release"
	cmdline_file="${tmpdir}/cmdline"
	cp -f -- /etc/os-release "${osrel}"
	# NUL-terminated payload for systemd-stub .cmdline consumers.
	printf '%s\0' "${cmdline}" >"${cmdline_file}"

	echo "${__progname}: objcopy packing stub=${stub}"
	objcopy_pack_uki "${stub}" "${osrel}" "${cmdline_file}" "${linux}" "${initrd}" "${out}"
	rm -rf -- "${tmpdir}"

	return 0
}

# Dump one PE section to a file.
dump_pe_section() {
	local -r uki="${1}"
	local -r section="${2}"
	local -r out="${3}"
	local dummy=""

	dummy="${out}.pe-dummy"
	rm -f -- "${out}" "${dummy}"

	if objcopy --dump-section "${section}=${out}" -- "${uki}" "${dummy}" 2>/dev/null \
		&& [ -s "${out}" ]; then
		rm -f -- "${dummy}"
		return 0
	fi

	rm -f -- "${out}" "${dummy}"
	if objcopy -O binary --only-section="${section}" -- "${uki}" "${out}" 2>/dev/null \
		&& [ -s "${out}" ]; then
		return 0
	fi

	rm -f -- "${out}"
	return 1
}

# dracut --uefi assemble only (no usable guarantee on .cmdline); caller repacks.
build_with_dracut() {
	local -r out="${1}"
	local -r kver="${2}"
	local -r linux="${3}"
	local -r stub="${4}"
	local -a cmd=()
	local help=""

	cmd=(
		dracut
		--force
		--uefi
		--uefi-stub "${stub}"
		--kernel-image "${linux}"
	)

	help="$(dracut --help 2>&1 || true)"

	if printf '%s\n' "${help}" | grep -qE -- '--no-ukify\b'; then
		cmd+=(--no-ukify)
	fi

	if printf '%s\n' "${help}" | grep -qE -- '--no-hostonly-cmdline\b'; then
		cmd+=(--no-hostonly-cmdline)
	fi

	cmd+=("${out}" "${kver}")

	echo "${__progname}: running: ${cmd[*]}"
	"${cmd[@]}"
}

# After dracut --uefi: extract .linux/.initrd and repack with our .cmdline.
repack_uki_with_cmdline() {
	local -r uki="${1}"
	local -r cmdline="${2}"
	local -r stub="${3}"
	local tmpdir=""
	local linux_bin=""
	local initrd_bin=""
	local osrel=""
	local cmdline_file=""

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	linux_bin="${tmpdir}/linux"
	initrd_bin="${tmpdir}/initrd"
	osrel="${tmpdir}/os-release"
	cmdline_file="${tmpdir}/cmdline"

	echo "${__progname}: repacking UKI from stub with embedded .cmdline"

	dump_pe_section "${uki}" ".linux" "${linux_bin}" || \
		errx "cannot dump .linux from ${uki} (objdump -h ${uki}?)"
	dump_pe_section "${uki}" ".initrd" "${initrd_bin}" || \
		errx "cannot dump .initrd from ${uki}"

	if ! dump_pe_section "${uki}" ".osrel" "${osrel}"; then
		cp -f -- /etc/os-release "${osrel}"
	fi

	printf '%s\0' "${cmdline}" >"${cmdline_file}"

	echo "${__progname}: dumped .linux=$(stat -c '%s' -- "${linux_bin}") bytes" \
		".initrd=$(stat -c '%s' -- "${initrd_bin}") bytes"

	objcopy_pack_uki "${stub}" "${osrel}" "${cmdline_file}" \
		"${linux_bin}" "${initrd_bin}" "${uki}"

	rm -rf -- "${tmpdir}"

	return 0
}

# Ensure BOOTKIT_MARKER is in the PE; repack if needed.
ensure_pe_cmdline() {
	local -r uki="${1}"
	local -r cmdline="${2}"
	local -r stub="${3}"

	if uki_has_cmdline_marker "${uki}"; then
		echo "${__progname}: verified BOOTKIT_MARKER=1 already in ${uki}"
		return 0
	fi

	echo "${__progname}: BOOTKIT_MARKER=1 missing; embedding PE .cmdline"
	repack_uki_with_cmdline "${uki}" "${cmdline}" "${stub}"

	uki_has_cmdline_marker "${uki}" || \
		errx "PE .cmdline embed failed: BOOTKIT_MARKER=1 not found in ${uki} (try: grep -aF BOOTKIT_MARKER ${uki})"

	echo "${__progname}: verified BOOTKIT_MARKER=1 in PE"

	return 0
}

main() {
	local kver=""
	local linux=""
	local initrd=""
	local output="${DEFAULT_OUTPUT}"
	local method="auto"
	local stub=""
	local -r cmdline="${LINUX_CMDLINE}"
	local out_sz=0
	local arg=""

	while [ "$#" -gt 0 ]; do
		arg="${1}"
		case "${arg}" in
		--kver)
			[ "$#" -lt 2 ] && \
				usage
			kver="${2}"
			shift 2
			;;
		--linux)
			[ "$#" -lt 2 ] && \
				usage
			linux="${2}"
			shift 2
			;;
		--initrd)
			[ "$#" -lt 2 ] && \
				usage
			initrd="${2}"
			shift 2
			;;
		--output)
			[ "$#" -lt 2 ] && \
				usage
			output="${2}"
			shift 2
			;;
		--method)
			[ "$#" -lt 2 ] && \
				usage
			method="${2}"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			usage
			;;
		esac
	done

	case "${method}" in
	auto|dracut|objcopy)
		;;
	*)
		errx "invalid --method '${method}' (want auto, objcopy, or dracut)"
		;;
	esac

	require_amazon_linux_2023

	for bin in uname mktemp cp grep stat objcopy mv; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	[ -z "${kver}" ] && \
		kver="$(uname -r)"

	[ -z "${linux}" ] && \
		linux="/boot/vmlinuz-${kver}"

	[ -z "${initrd}" ] && \
		initrd="/boot/initramfs-${kver}.img"

	[ ! -f "${linux}" ] && \
		errx "kernel image not found: ${linux}"

	[ ! -f "${initrd}" ] && \
		errx "initrd not found: ${initrd}"

	stub="$(find_stub)" || \
		errx "no linuxx64.efi.stub found (install systemd-boot-unsigned)"

	# Resolve relative --output against cwd; ensure parent is writable.
	case "${output}" in
	/*)
		;;
	*)
		output="$(pwd)/${output}"
		;;
	esac
	local out_dir=""
	out_dir="$(dirname -- "${output}")"
	[ -d "${out_dir}" ] || \
		errx "output directory does not exist: ${out_dir}"
	[ -w "${out_dir}" ] || \
		errx "output directory not writable: ${out_dir}"

	echo "${__progname}: kver=${kver}"
	echo "${__progname}: linux=${linux}"
	echo "${__progname}: initrd=${initrd}"
	echo "${__progname}: stub=${stub}"
	echo "${__progname}: output=${output}"
	echo "${__progname}: method=${method}"
	echo "${__progname}: cmdline=${cmdline} (PE .cmdline; GRUB adds root= at boot)"

	case "${method}" in
	objcopy|auto)
		# Default: pack existing kernel+initrd; reliable .cmdline with section flags.
		build_with_objcopy "${output}" "${linux}" "${initrd}" "${cmdline}" "${stub}"
		;;
	dracut)
		! command -v dracut >/dev/null 2>&1 && \
			errx "cannot find 'dracut' in 'PATH=${PATH}'"
		build_with_dracut "${output}" "${kver}" "${linux}" "${stub}"
		ensure_pe_cmdline "${output}" "${cmdline}" "${stub}"
		;;
	esac

	[ ! -f "${output}" ] && \
		errx "UKI was not created: ${output}"

	# Objcopy path should already contain the marker; check all methods.
	uki_has_cmdline_marker "${output}" || \
		errx "BOOTKIT_MARKER=1 not found in ${output} after build"

	echo "${__progname}: verified BOOTKIT_MARKER=1 in ${output}"

	out_sz="$(stat -c '%s' -- "${output}")"
	[ "${out_sz}" -lt 1024 ] && \
		errx "UKI looks too small (${out_sz} bytes): ${output}"

	echo "${__progname}: done"
	echo "${__progname}:   output: ${output}"
	echo "${__progname}:   size:   ${out_sz} bytes"
	echo "${__progname}: next: mk-bootx64-efi.sh, then ./deploy -y"
}

main "$@"
