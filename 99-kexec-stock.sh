#!/bin/sh
#
# 99-kexec-stock.sh - After stage-1 payload, kexec stock kernel+initrd from disk.
#
# Runs in the UKI's bootkit initrd (pre-pivot). If BOOTKIT_MARKER=1 is present,
# resolves the stock boot target the way AL2023 GRUB would (BLS + grubenv,
# then grub.cfg menuentry lines, then newest /boot/vmlinuz-*), loads it with a
# cleaned cmdline (marker stripped), then kexec -e.
#
# On any failure: log and return 0 so dracut can still pivot into the UKI kernel
# (degraded mode). Never kexec the research UKI PE.
#
# Dracut *sources* hooks: use return, never exit (exit aborts the hook runner).
# Plain POSIX sh (no local); set +e; optional HELLO.TXT breadcrumbs.
#

# Parent dracut may run with set -e; do not abort the hook on soft failures.
set +e

log() {
	echo "99-kexec-stock: $*" >&2
}

note() {
	[ -d /sysroot/root ] || \
		return 0
	echo "99-kexec-stock: $*" >>/sysroot/root/HELLO.TXT 2>/dev/null
}

# Map a BLS/grub path (/vmlinuz-X or /boot/vmlinuz-X) onto /sysroot/boot/...
boot_path() {
	_bp="$1"

	case "${_bp}" in
	"")
		return 1
		;;
	/boot/*)
		_bp="${_bp#/boot}"
		;;
	esac
	_bp="${_bp#/}"
	printf '%s\n' "/sysroot/boot/${_bp}"
	return 0
}

# Strip GRUB $variables and research marker; collapse whitespace.
clean_cmdline() {
	_cc="$1"

	_cc="$(printf '%s\n' "${_cc}" | sed 's/\$[A-Za-z_][A-Za-z0-9_]*//g')"
	_cc="$(printf '%s\n' "${_cc}" | sed 's/[[:space:]]*BOOTKIT_MARKER=1//g')"
	_cc="$(printf '%s\n' "${_cc}" | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//')"
	printf '%s\n' "${_cc}"
}

# Ensure root= is present: prefer existing; else copy from stage-1 /proc/cmdline.
ensure_root_param() {
	_er="$1"
	_root=""

	case " ${_er} " in
	*" root="*)
		printf '%s\n' "${_er}"
		return 0
		;;
	esac

	_root="$(cat /proc/cmdline 2>/dev/null)"
	_root="$(printf '%s\n' "${_root}" | tr ' ' '\n' | grep -m1 '^root=')"
	if [ -z "${_root}" ]; then
		printf '%s\n' "${_er}"
		return 0
	fi
	printf '%s\n' "${_er} ${_root}"
	return 0
}

# Read one key=value from a GRUB environment block file.
grubenv_get() {
	_ge_file="$1"
	_ge_key="$2"
	_ge_line=""

	[ -f "${_ge_file}" ] || \
		return 1

	while IFS= read -r _ge_line || [ -n "${_ge_line}" ]; do
		case "${_ge_line}" in
		\#*|"")
			continue
			;;
		"${_ge_key}="*)
			printf '%s\n' "${_ge_line#${_ge_key}=}"
			return 0
			;;
		esac
	done <"${_ge_file}"

	return 1
}

# Parse a BLS .conf: set RESOLVED_VMLINUZ, RESOLVED_INITRD, RESOLVED_CMDLINE.
parse_bls_conf() {
	_pbc="$1"
	_pbc_line=""
	_pbc_key=""
	_pbc_val=""
	_pbc_linux=""
	_pbc_initrd=""
	_pbc_options=""
	_pbc_path=""

	[ -f "${_pbc}" ] || \
		return 1

	case "${_pbc}" in
	*rescue*)
		return 1
		;;
	esac

	while IFS= read -r _pbc_line || [ -n "${_pbc_line}" ]; do
		_pbc_line="${_pbc_line#"${_pbc_line%%[![:space:]]*}"}"
		case "${_pbc_line}" in
		""|\#*)
			continue
			;;
		esac
		_pbc_key="${_pbc_line%%[[:space:]]*}"
		_pbc_val="${_pbc_line#"${_pbc_key}"}"
		_pbc_val="${_pbc_val#"${_pbc_val%%[![:space:]]*}"}"
		case "${_pbc_key}" in
		linux|linuxefi)
			_pbc_linux="${_pbc_val%%[[:space:]]*}"
			;;
		initrd|initrdefi)
			_pbc_initrd="${_pbc_val%%[[:space:]]*}"
			;;
		options)
			_pbc_options="${_pbc_val}"
			;;
		esac
	done <"${_pbc}"

	[ -n "${_pbc_linux}" ] || \
		return 1
	[ -n "${_pbc_initrd}" ] || \
		return 1

	_pbc_path="$(boot_path "${_pbc_linux}")"
	[ -n "${_pbc_path}" ] && [ -f "${_pbc_path}" ] || \
		return 1
	RESOLVED_VMLINUZ="${_pbc_path}"

	_pbc_path="$(boot_path "${_pbc_initrd}")"
	[ -n "${_pbc_path}" ] && [ -f "${_pbc_path}" ] || \
		return 1
	RESOLVED_INITRD="${_pbc_path}"

	if [ -n "${_pbc_options}" ]; then
		RESOLVED_CMDLINE="$(clean_cmdline "${_pbc_options}")"
		RESOLVED_CMDLINE="$(ensure_root_param "${RESOLVED_CMDLINE}")"
	else
		RESOLVED_CMDLINE=""
	fi

	RESOLVED_SOURCE="bls:${_pbc##*/}"
	return 0
}

# Prefer grubenv saved_entry → matching BLS; else highest-version non-rescue BLS.
resolve_bls() {
	_rb_entries="/sysroot/boot/loader/entries"
	_rb_env=""
	_rb_saved=""
	_rb_conf=""
	_rb_best=""
	_rb_ver=""
	_rb_best_ver=""
	_rb_id=""
	_rb_higher=""

	[ -d "${_rb_entries}" ] || \
		return 1

	# AL2023: only /boot/grub2/grubenv (seen as /sysroot/boot/grub2/grubenv pre-pivot).
	_rb_env="/sysroot/boot/grub2/grubenv"
	if [ -f "${_rb_env}" ]; then
		_rb_saved="$(grubenv_get "${_rb_env}" saved_entry)"
	fi

	if [ -n "${_rb_saved}" ]; then
		for _rb_conf in \
			"${_rb_entries}/${_rb_saved}.conf" \
			"${_rb_entries}/${_rb_saved}"
		do
			if parse_bls_conf "${_rb_conf}"; then
				return 0
			fi
		done
		for _rb_conf in "${_rb_entries}"/*.conf; do
			[ -f "${_rb_conf}" ] || \
				continue
			_rb_id="${_rb_conf##*/}"
			_rb_id="${_rb_id%.conf}"
			case "${_rb_id}" in
			*"${_rb_saved}"*)
				if parse_bls_conf "${_rb_conf}"; then
					return 0
				fi
				;;
			esac
		done
		log "grubenv saved_entry='${_rb_saved}' not usable; trying newest BLS"
	fi

	_rb_best=""
	_rb_best_ver=""
	for _rb_conf in "${_rb_entries}"/*.conf; do
		[ -f "${_rb_conf}" ] || \
			continue
		case "${_rb_conf}" in
		*rescue*)
			continue
			;;
		esac
		_rb_ver="$(grep -m1 '^version[[:space:]]' -- "${_rb_conf}" 2>/dev/null | awk '{print $2}')"
		[ -n "${_rb_ver}" ] || \
			_rb_ver="${_rb_conf##*/}"
		if [ -z "${_rb_best}" ]; then
			_rb_best="${_rb_conf}"
			_rb_best_ver="${_rb_ver}"
			continue
		fi
		_rb_higher="$(printf '%s\n%s\n' "${_rb_best_ver}" "${_rb_ver}" | sort -V | tail -n1)"
		if [ "${_rb_higher}" = "${_rb_ver}" ] && [ "${_rb_ver}" != "${_rb_best_ver}" ]; then
			_rb_best="${_rb_conf}"
			_rb_best_ver="${_rb_ver}"
		fi
	done

	[ -n "${_rb_best}" ] || \
		return 1
	parse_bls_conf "${_rb_best}"
}

# Fall back: first non-rescue linux/initrd pair in stock grub.cfg (legacy layout).
resolve_grub_cfg() {
	_rg_cfg=""
	_rg_line=""
	_rg_linux=""
	_rg_initrd=""
	_rg_path=""
	_rg_in_entry=0
	_rg_skip=0

	# AL2023: only /boot/grub2/grub.cfg (legacy fallback; usually blscfg-only).
	_rg_cfg="/sysroot/boot/grub2/grub.cfg"
	[ -f "${_rg_cfg}" ] || \
		return 1

	_rg_linux=""
	_rg_initrd=""
	_rg_in_entry=0
	_rg_skip=0
	while IFS= read -r _rg_line || [ -n "${_rg_line}" ]; do
		_rg_line="${_rg_line#"${_rg_line%%[![:space:]]*}"}"
		case "${_rg_line}" in
		menuentry\ *)
			_rg_in_entry=1
			_rg_skip=0
			case "${_rg_line}" in
			*rescue*|*Rescue*|*recovery*)
				_rg_skip=1
				;;
			esac
			_rg_linux=""
			_rg_initrd=""
			;;
		\})
			if [ "${_rg_in_entry}" -eq 1 ] && [ "${_rg_skip}" -eq 0 ] && \
				[ -n "${_rg_linux}" ] && [ -n "${_rg_initrd}" ]; then
				_rg_path="$(boot_path "${_rg_linux}")"
				if [ -n "${_rg_path}" ] && [ -f "${_rg_path}" ]; then
					RESOLVED_VMLINUZ="${_rg_path}"
					_rg_path="$(boot_path "${_rg_initrd}")"
					if [ -n "${_rg_path}" ] && [ -f "${_rg_path}" ]; then
						RESOLVED_INITRD="${_rg_path}"
						RESOLVED_CMDLINE=""
						RESOLVED_SOURCE="grub.cfg:${_rg_cfg}"
						return 0
					fi
				fi
			fi
			_rg_in_entry=0
			_rg_skip=0
			_rg_linux=""
			_rg_initrd=""
			;;
		linux\ *|linuxefi\ *)
			if [ "${_rg_in_entry}" -eq 1 ] && [ "${_rg_skip}" -eq 0 ]; then
				_rg_linux="$(printf '%s\n' "${_rg_line}" | awk '{print $2}')"
			fi
			;;
		initrd\ *|initrdefi\ *)
			if [ "${_rg_in_entry}" -eq 1 ] && [ "${_rg_skip}" -eq 0 ]; then
				_rg_initrd="$(printf '%s\n' "${_rg_line}" | awk '{print $2}')"
			fi
			;;
		esac
	done <"${_rg_cfg}"

	return 1
}

# Last resort: newest non-rescue vmlinuz + matching initramfs name.
resolve_newest_vmlinuz() {
	_rn_f=""
	_rn_higher=""
	_rn_vmlinuz=""
	_rn_kver=""
	_rn_initrd=""

	for _rn_f in /sysroot/boot/vmlinuz-*; do
		[ -f "${_rn_f}" ] || \
			continue
		case "${_rn_f}" in
		*rescue*|*INSERT*|*insert*)
			continue
			;;
		esac
		if [ -z "${_rn_vmlinuz}" ]; then
			_rn_vmlinuz="${_rn_f}"
			continue
		fi
		_rn_higher="$(printf '%s\n%s\n' "${_rn_vmlinuz}" "${_rn_f}" | sort -V | tail -n1)"
		_rn_vmlinuz="${_rn_higher}"
	done

	[ -n "${_rn_vmlinuz}" ] || \
		return 1

	_rn_kver="${_rn_vmlinuz##*/vmlinuz-}"
	_rn_initrd="/sysroot/boot/initramfs-${_rn_kver}.img"
	[ -f "${_rn_initrd}" ] || \
		return 1

	RESOLVED_VMLINUZ="${_rn_vmlinuz}"
	RESOLVED_INITRD="${_rn_initrd}"
	RESOLVED_CMDLINE=""
	RESOLVED_SOURCE="newest-vmlinuz"
	return 0
}

RESOLVED_VMLINUZ=""
RESOLVED_INITRD=""
RESOLVED_CMDLINE=""
RESOLVED_SOURCE=""

# Prove the hook ran even if we exit early (parent set -e used to hide this).
note "start"
log "start"

# Only hand off on the research stage-1 path.
case " $(cat /proc/cmdline 2>/dev/null) " in
*" BOOTKIT_MARKER=1 "*)
	note "marker present"
	;;
*)
	note "no BOOTKIT_MARKER; skip"
	return 0
	;;
esac

if [ ! -d /sysroot/boot ]; then
	log "no /sysroot/boot; falling through to UKI pivot"
	note "no /sysroot/boot; fall-through"
	return 0
fi
note "sysroot/boot ok"

KEXEC=""
for c in /usr/sbin/kexec /sbin/kexec; do
	if [ -x "${c}" ]; then
		KEXEC="${c}"
		break
	fi
done

if [ -z "${KEXEC}" ]; then
	log "kexec binary missing in initrd; falling through to UKI pivot"
	note "kexec missing; fall-through"
	return 0
fi
note "kexec=${KEXEC}"

# AL2023: dnf/grubby configure BLS + grubenv; grub.cfg usually only loads blscfg.
if ! resolve_bls; then
	note "bls resolve failed"
	if ! resolve_grub_cfg; then
		note "grub.cfg resolve failed"
		if ! resolve_newest_vmlinuz; then
			log "could not resolve stock kernel; falling through"
			note "resolve failed; fall-through"
			return 0
		fi
	fi
fi

VMLINUZ="${RESOLVED_VMLINUZ}"
INITRD="${RESOLVED_INITRD}"

if [ -n "${RESOLVED_CMDLINE}" ]; then
	CMDLINE="${RESOLVED_CMDLINE}"
else
	CMDLINE="$(cat /proc/cmdline)"
	CMDLINE="$(clean_cmdline "${CMDLINE}")"
fi
CMDLINE="$(ensure_root_param "${CMDLINE}")"
CMDLINE="$(clean_cmdline "${CMDLINE}")"

if [ -z "${CMDLINE}" ]; then
	log "empty cmdline after resolve; falling through"
	note "empty cmdline; fall-through"
	return 0
fi

log "resolved via ${RESOLVED_SOURCE}"
log "loading stock ${VMLINUZ} + ${INITRD}"
note "resolve=${RESOLVED_SOURCE}"
note "kexec -l ${VMLINUZ##*/} ${INITRD##*/}"
note "cmdline=${CMDLINE}"

if ! "${KEXEC}" -l "${VMLINUZ}" --initrd="${INITRD}" --command-line="${CMDLINE}"; then
	log "kexec -l failed rc=$?; falling through to UKI pivot"
	note "kexec -l failed; fall-through"
	return 0
fi
note "kexec -l ok"

sync

log "kexec -e (stage-2 stock kernel)"
note "kexec -e"
"${KEXEC}" -e
_ke_rc=$?

log "kexec -e returned rc=${_ke_rc}; falling through to UKI pivot"
note "kexec -e returned rc=${_ke_rc}; fall-through"
return 0
