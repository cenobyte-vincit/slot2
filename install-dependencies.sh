#!/usr/bin/env bash
#
# install-dependencies.sh - Install packages needed by the UKI / BOOTX64 build.
#
# Checks for tools and libraries used by mk-uki.sh, mk-bootx64-efi.sh,
# deploy build (magic/trailer), efi/deploy C sources, cppcheck, and pinned
# busybox static binaries (udhcpc + wget; sha256-verified) for stage-1.
# Runs dnf install only when something is missing. Must be run as root.
# Targets Amazon Linux 2023 dnf packaging (x86_64).
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Package that ships /usr/lib/grub/x86_64-efi/{kernel.img,*.mod,moddep.lst}.
readonly GRUB_EFI_MODULES_PKG="grub2-efi-x64-modules"
readonly GRUB_EFI_MODDIR="/usr/lib/grub/x86_64-efi"

# systemd EFI stub for UKI assembly (linuxx64.efi.stub).
readonly SYSTEMD_BOOT_STUB_PKG="systemd-boot-unsigned"

# Headers + pkg-config data for deploy/efi-nvram (efiboot.h / efivar.h).
readonly EFIVAR_DEVEL_PKG="efivar-devel"

# ---------------------------------------------------------------------------
# busybox static musl applets for the bootkit initrd (stage-1 DHCP + HTTP).
#
# Version pinning: the download URL embeds a fixed busybox release and
# architecture (1.35.0-x86_64-linux-musl). Do not switch to a "latest" URL.
# Integrity: SHA-256 of each binary is verified after every fetch (and when
# the file already exists) so a wrong or tampered blob cannot slip into the
# UKI. URL version path and sha256 must be updated together when deliberately
# upgrading; re-verify on the build host (sha256sum) before committing the pin.
# ---------------------------------------------------------------------------
readonly BUSYBOX_VERSION="1.35.0"
readonly BUSYBOX_ARCH="x86_64-linux-musl"
readonly BUSYBOX_BASE_URL="https://busybox.net/downloads/binaries/${BUSYBOX_VERSION}-${BUSYBOX_ARCH}"

readonly UDHCPC_BASENAME="busybox_UDHCPC"
readonly UDHCPC_URL="${BUSYBOX_BASE_URL}/${UDHCPC_BASENAME}"
readonly UDHCPC_SHA256="a1cf6fc2d220bd41c4ebf835284a5b4aade54b51d72561b88e6782108d32cca8"

readonly WGET_BASENAME="busybox_WGET"
readonly WGET_URL="${BUSYBOX_BASE_URL}/${WGET_BASENAME}"
readonly WGET_SHA256="6f962014746ec88aeb8271ba63d05fa5616e0eca014259b0fd29d0d29de9192a"

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

# Require a Linux host running Amazon Linux 2023.
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

# Install one dnf package if it is not already installed.
ensure_package() {
	local -r pkg="${1}"

	if rpm -q --quiet -- "${pkg}"; then
		echo "${__progname}: package already installed: ${pkg}"
		return 0
	fi

	echo "${__progname}: installing package: ${pkg}"
	dnf install -y -- "${pkg}"
}

# Ensure a command exists; install pkg if the command is missing.
ensure_command() {
	local -r bin="${1}"
	local -r pkg="${2}"

	if command -v "${bin}" >/dev/null 2>&1; then
		echo "${__progname}: found ${bin} ($(command -v "${bin}"))"
		return 0
	fi

	echo "${__progname}: ${bin} not found; installing ${pkg}"
	ensure_package "${pkg}"

	! command -v "${bin}" >/dev/null 2>&1 && \
		errx "still cannot find '${bin}' after installing ${pkg}"

	# Happy path ends with a false ! cmd && errx (status 1); force success under set -e.
	return 0
}

# Ensure the x86_64 EFI GRUB module tree is present.
ensure_grub_efi_modules() {
	if [ -f "${GRUB_EFI_MODDIR}/kernel.img" ] && \
		[ -f "${GRUB_EFI_MODDIR}/moddep.lst" ]; then
		echo "${__progname}: found GRUB EFI modules under ${GRUB_EFI_MODDIR}"
		return 0
	fi

	echo "${__progname}: GRUB EFI modules missing under ${GRUB_EFI_MODDIR}"
	ensure_package "${GRUB_EFI_MODULES_PKG}"

	[ ! -f "${GRUB_EFI_MODDIR}/kernel.img" ] && \
		errx "still missing ${GRUB_EFI_MODDIR}/kernel.img after installing ${GRUB_EFI_MODULES_PKG}"
	[ ! -f "${GRUB_EFI_MODDIR}/moddep.lst" ] && \
		errx "still missing ${GRUB_EFI_MODDIR}/moddep.lst after installing ${GRUB_EFI_MODULES_PKG}"

	# Happy path ends with a false [ ] && errx (status 1); force success under set -e.
	return 0
}

# Ensure the systemd linuxx64 EFI stub used by mk-uki.sh is present.
ensure_uki_stub() {
	local p=""

	for p in \
		/usr/lib/systemd/boot/efi/linuxx64.efi.stub \
		/lib/systemd/boot/efi/linuxx64.efi.stub
	do
		if [ -f "${p}" ]; then
			echo "${__progname}: found UKI stub: ${p}"
			return 0
		fi
	done

	echo "${__progname}: UKI stub missing; installing ${SYSTEMD_BOOT_STUB_PKG}"
	ensure_package "${SYSTEMD_BOOT_STUB_PKG}"

	[ ! -f /usr/lib/systemd/boot/efi/linuxx64.efi.stub ] && \
		[ ! -f /lib/systemd/boot/efi/linuxx64.efi.stub ] && \
		errx "still missing linuxx64.efi.stub after installing ${SYSTEMD_BOOT_STUB_PKG}"

	# Happy path ends with a false [ ] && errx (status 1); force success under set -e.
	return 0
}

# Ensure efivar/efiboot devel files for compiling deploy (efi-nvram).
ensure_efivar_devel() {
	if pkg-config --exists efivar efiboot 2>/dev/null; then
		echo "${__progname}: found pkg-config modules efivar efiboot"
		return 0
	fi

	echo "${__progname}: efivar/efiboot pkg-config missing; installing ${EFIVAR_DEVEL_PKG}"
	ensure_package "${EFIVAR_DEVEL_PKG}"

	! pkg-config --exists efivar efiboot 2>/dev/null && \
		errx "pkg-config still cannot find efivar efiboot after installing ${EFIVAR_DEVEL_PKG}"

	# Happy path ends with a false ! cmd && errx (status 1); force success under set -e.
	return 0
}

# SHA-256 of a file (hex only); uses sha256sum or openssl.
file_sha256() {
	local -r path="${1}"
	local line=""
	local hash=""

	if command -v sha256sum >/dev/null 2>&1; then
		line="$(sha256sum -- "${path}")"
		hash="${line%% *}"
	elif command -v openssl >/dev/null 2>&1; then
		# openssl dgst -sha256 -> "SHA256(path)= hex"
		line="$(openssl dgst -sha256 -- "${path}")"
		hash="${line##*= }"
		hash="${hash##* }"
	else
		errx "cannot find sha256sum or openssl in 'PATH=${PATH}'"
	fi

	printf '%s\n' "${hash}"
}

# Fetch one pinned busybox static binary; verify SHA-256 (version pin + integrity).
# Args: dest_path url expected_sha256 label (for log lines).
ensure_busybox_binary() {
	local -r dest="${1}"
	local -r url="${2}"
	local -r want_sha="${3}"
	local -r label="${4}"
	local actual=""
	local tmp=""
	local dest_dir=""

	dest_dir="$(dirname -- "${dest}")"
	[ -d "${dest_dir}" ] || \
		errx "destination directory missing: ${dest_dir}"

	if [ -f "${dest}" ]; then
		actual="$(file_sha256 "${dest}")"
		if [ "${actual}" = "${want_sha}" ]; then
			echo "${__progname}: found ${dest} (sha256 ok, busybox ${BUSYBOX_VERSION} ${label})"
			chmod 0755 -- "${dest}"
			return 0
		fi
		echo "${__progname}: ${dest} sha256 mismatch (got ${actual}, want ${want_sha}); re-fetching"
		rm -f -- "${dest}"
	fi

	for bin in curl chmod mktemp mv rm; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}' (need curl to fetch busybox)"
	done

	echo "${__progname}: fetching busybox ${label} ${BUSYBOX_VERSION} (${BUSYBOX_ARCH})"
	echo "${__progname}:   url=${url}"
	echo "${__progname}:   sha256=${want_sha} (version pin + integrity)"

	tmp="$(mktemp "/tmp/${__progname}.busybox.XXXXXX")"
	[ -f "${tmp}" ] || \
		errx "mktemp"

	# Always verify hash after download; never install on mismatch.
	if ! curl -fsSL --connect-timeout 30 --max-time 120 \
		-o "${tmp}" -- "${url}"; then
		rm -f -- "${tmp}"
		errx "download failed: ${url}"
	fi

	actual="$(file_sha256 "${tmp}")"
	if [ "${actual}" != "${want_sha}" ]; then
		rm -f -- "${tmp}"
		errx "sha256 mismatch after download (got ${actual}, want ${want_sha})"
	fi

	chmod 0755 -- "${tmp}"
	mv -f -- "${tmp}" "${dest}"

	echo "${__progname}: installed ${dest} (sha256 verified)"
}

main() {
	[ "$(id -u)" -ne 0 ] && \
		errx "must be run as root"

	[[ "$#" -ne 0 ]] && \
		errx "usage: ${__progname}"

	require_amazon_linux_2023

	for bin in dnf rpm; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# mk-bootx64-efi.sh
	ensure_command grub2-mkimage grub2-tools
	ensure_grub_efi_modules

	# mk-uki.sh
	ensure_command dracut dracut
	ensure_command objcopy binutils
	ensure_uki_stub

	# efi / deploy C (efi-nvram, trailer append)
	ensure_command cc gcc
	ensure_command pkg-config pkgconf
	ensure_efivar_devel
	ensure_command openssl openssl
	ensure_command xxd vim-common
	ensure_command cppcheck cppcheck

	# Bootkit initrd stage-2 handoff (inject-kexec.sh copies binary + libs).
	ensure_command kexec kexec-tools

	# Host curl only to download pinned busybox blobs (not injected into the UKI).
	ensure_command curl curl-minimal

	# Stage-1: pinned busybox udhcpc + wget (inject-*.sh -> initrd).
	# Version pin is in BUSYBOX_BASE_URL; integrity is per-binary SHA-256.
	ensure_busybox_binary "${repo_root}/${UDHCPC_BASENAME}" \
		"${UDHCPC_URL}" "${UDHCPC_SHA256}" "udhcpc"
	ensure_busybox_binary "${repo_root}/${WGET_BASENAME}" \
		"${WGET_URL}" "${WGET_SHA256}" "wget"

	echo "${__progname}: dependencies OK"
}

main "$@"
