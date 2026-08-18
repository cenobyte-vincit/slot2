#!/usr/bin/env bash
#
# initrd-packer.sh - Pack or unpack a dracut-built initramfs (Amazon Linux 2023).
#
# Usage: initrd-packer.sh <pack|unpack> <initrd path> <directory>
#
# Amazon Linux 2023 builds initramfs with dracut (compress=zstd, early microcode
# cpio + main archive). This script packs/unpacks that layout for surgical edits.
#
# unpack:
#   1. skipcpio (from the dracut package) + zstd + cpio
#   2. else pure newc parse (python3) + zstd + cpio  [same AL2023 layout]
#
# pack:
#   Reassemble dracut-style: early newc cpio + 512-byte pad + zstd main cpio.
#   Aimed at bit-stable output for the same tree + SOURCE_DATE_EPOCH:
#   - sorted find (stable member order; readdir order is not)
#   - clamp file mtimes to SOURCE_DATE_EPOCH (default 0 if unset)
#   - fixed cpio owner 0:0 and --reproducible when GNU cpio supports it
#   - zstd single-thread (-T1) so multi-thread compress does not reshuffle output
#
# For a full regenerate from the running system (when possible):
#   dracut -f /boot/initramfs-<kver>.img <kver>
#   (stock dracut images are a separate reproducibility problem)
#
# Requires Amazon Linux (Linux), cpio, zstd; python3 only for the parse fallback.
# Optional: lsinitrd, /usr/lib/dracut/skipcpio
#
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2155
readonly __progname="$(basename "${BASH_SOURCE[0]}")"
readonly PATH="/usr/sbin:/usr/bin:/sbin:/bin"

readonly META_NAME=".dracut-initrd-meta"
readonly COMPRESS_DEFAULT="zstd"
readonly ALIGN=512
readonly CPIO_MAGIC="070701"
readonly ZSTD_MAGIC_HEX="28b52ffd"

# dracut skipcpio is not on PATH.
readonly SKIPCPIO_CANDIDATES=(
	/usr/lib/dracut/skipcpio
	/usr/libexec/dracut/skipcpio
)

errx() {
	echo -e "${__progname}: $*" >&2

	exit 1
}

usage() {
	echo -e "usage: ${__progname} <pack|unpack> <initrd path> <directory>" >&2

	exit 1
}

# Print path of executable skipcpio, or return 1.
find_skipcpio() {
	local i

	for i in "${SKIPCPIO_CANDIDATES[@]}"; do
		[ -x "${i}" ] && \
			echo "${i}" && return 0
	done

	return 1
}

# Ensure path is an empty directory, or create it.
ensure_empty_dir() {
	local -r dir="${1}"
	local entries=""

	if [ -e "${dir}" ]; then
		[ ! -d "${dir}" ] && \
			errx "path exists and is not a directory: ${dir}"
		entries="$(find "${dir}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
		[ "${entries}" -ne 0 ] && \
			errx "directory is not empty: ${dir}"
	else
		mkdir -p -- "${dir}"
	fi

	# Happy path ends with a false [ ] && errx (status 1); force success under set -e.
	return 0
}

# Epoch used for clamped mtimes (and documented for callers). Prefer env pin.
pack_source_date_epoch() {
	if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
		printf '%s\n' "${SOURCE_DATE_EPOCH}"
		return 0
	fi

	printf '%s\n' "0"

	return 0
}

# Clamp mtimes under dir so newc headers do not carry host "now" or unpack noise.
# Uses SOURCE_DATE_EPOCH when set, otherwise 0 (Unix epoch).
clamp_tree_mtimes() {
	local -r dir="${1}"
	local -r epoch="${2}"

	# -h: do not follow symlinks; only touch what we pack as directory entries.
	find "${dir}" \( -type f -o -type d -o -type l \) -exec \
		touch -h -d "@${epoch}" -- {} +

	return 0
}

# Emit a newc cpio of dir on stdout (deterministic member order and metadata).
cpio_from_dir() {
	local -r dir="${1}"
	local -a cpio_opts=()

	# Sorted paths: plain find order follows readdir and varies by FS/host.
	# --null / -0: safe for odd filenames; -H newc: dracut-compatible format.
	cpio_opts=(--null -o -H newc --quiet)

	# GNU cpio: drop host dev/ino noise that would change the archive bytes.
	if cpio --help 2>&1 | grep -qE -- '--reproducible\b'; then
		cpio_opts+=(--reproducible)
	fi

	# Fixed owner/group so UID/GID of the build user is not recorded.
	if cpio --help 2>&1 | grep -qE -- '--owner\b'; then
		cpio_opts+=(--owner=0:0)
	elif cpio --help 2>&1 | grep -qE -- '-R\b'; then
		cpio_opts+=(-R "0:0")
	fi

	(
		cd -- "${dir}" && find . \
			! -name "${META_NAME}" \
			! -path "./${META_NAME}" \
			-print0 |
			LC_ALL=C sort -z |
			cpio "${cpio_opts[@]}"
	)
}

# Extract a newc cpio file into destdir.
extract_cpio_file() {
	local -r archive="${1}"
	local -r destdir="${2}"

	(
		cd -- "${destdir}" && cpio -idmu --quiet
	) <"${archive}"
}

# Append zero bytes until size is a multiple of ALIGN.
pad_file_to_align() {
	local -r path="${1}"
	local size pad

	size="$(wc -c <"${path}" | tr -d ' ')"
	pad=$(( (ALIGN - (size % ALIGN)) % ALIGN ))
	if [ "${pad}" -eq 0 ]; then
		return 0
	fi

	head -c "${pad}" /dev/zero >>"${path}"

	return 0
}

# Compress stdin to stdout (dracut main archive on AL2023).
# -T1 / single-thread: multi-threaded zstd can produce different frames for the
# same input; single-thread keeps the compressed main blob stable.
compress_main() {
	if zstd --help 2>&1 | grep -qE -- '-T#|--threads'; then
		zstd -19 -T1 -c
	else
		zstd -19 -c
	fi
}

# Detect layout after unpack: early+main or flat.
detect_layout() {
	local -r dir="${1}"

	if [ -d "${dir}/early" ] && [ -d "${dir}/main" ]; then
		echo "early+main"
		return 0
	fi

	echo "flat"
}

# Optional lsinitrd Version: line.
lsinitrd_version() {
	local -r img="${1}"
	local line=""

	command -v lsinitrd >/dev/null 2>&1 || \
		return 0

	line="$(lsinitrd "${img}" 2>/dev/null | grep -m1 '^Version:' || true)"
	[ -n "${line}" ] && \
		echo "${line#Version: }"
}

# Write unpack metadata for pack.
write_meta() {
	local -r dir="${1}"
	local -r img="${2}"
	local -r layout="${3}"
	local -r version="${4}"
	local -r method="${5}"

	{
		echo "tool=dracut"
		echo "layout=${layout}"
		echo "compress=${COMPRESS_DEFAULT}"
		echo "unpack_method=${method}"
		echo "source=$(basename -- "${img}")"
		if [ -n "${version}" ]; then
			echo "dracut_version=${version}"
		fi
	} >"${dir}/${META_NAME}"

	return 0
}

# Read layout= and compress= from meta; sets globals layout compress.
read_meta() {
	local -r dir="${1}"
	local -r meta="${dir}/${META_NAME}"
	local line key val

	layout="early+main"
	compress="${COMPRESS_DEFAULT}"

	[ ! -f "${meta}" ] && \
		return 0

	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && \
			continue
		[[ "${line}" =~ ^# ]] && \
			continue
		key="${line%%=*}"
		val="${line#*=}"
		case "${key}" in
		layout)
			layout="${val}"
			;;
		compress)
			compress="${val}"
			;;
		esac
	done <"${meta}"
}

# Print "early_end main_off" for early-newc + zstd-main; fail otherwise.
split_offsets() {
	local -r img="${1}"

	python3 - "${img}" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as f:
	data = f.read()

if not data.startswith(b"070701"):
	sys.stderr.write("image does not start with newc cpio magic 070701\n")
	sys.exit(1)

pos = 0
while pos + 110 <= len(data):
	magic = data[pos : pos + 6]
	if magic not in (b"070701", b"070702"):
		sys.stderr.write(
			f"unexpected data at offset {pos} while parsing early cpio\n"
		)
		sys.exit(1)
	namesize = int(data[pos + 94 : pos + 102], 16)
	filesize = int(data[pos + 54 : pos + 62], 16)
	name_start = pos + 110
	name_end = name_start + namesize
	name_pad_end = (name_end + 3) & ~3
	name = data[name_start : name_end - 1]
	data_end = name_pad_end + filesize
	pos = (data_end + 3) & ~3
	if name == b"TRAILER!!!":
		break
else:
	sys.stderr.write("early cpio TRAILER!!! not found\n")
	sys.exit(1)

early_end = pos
main_off = early_end
while main_off < len(data) and data[main_off] == 0:
	main_off += 1

if main_off + 4 > len(data) or data[main_off : main_off + 4] != b"\x28\xb5/\xfd":
	sys.stderr.write(
		f"main archive is not zstd at offset {main_off} "
		f"(expected magic 28b52ffd)\n"
	)
	sys.exit(1)

print(f"{early_end} {main_off}")
PY
}

# Unpack via skipcpio + zstd (dracut helper present on most AL2023 installs).
unpack_skipcpio() {
	local -r img="${1}"
	local -r outdir="${2}"
	local -r skipcpio="${3}"
	local tmpdir="" rest img_sz rest_sz early_sz

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	rest="${tmpdir}/rest"
	"${skipcpio}" "${img}" >"${rest}"

	img_sz="$(wc -c <"${img}" | tr -d ' ')"
	rest_sz="$(wc -c <"${rest}" | tr -d ' ')"
	[ "${img_sz}" -ge "${rest_sz}" ] || \
		errx "skipcpio produced a larger payload than the image"

	mkdir -p -- "${outdir}/early" "${outdir}/main"

	if [ "${img_sz}" -gt "${rest_sz}" ]; then
		early_sz=$((img_sz - rest_sz))
		head -c "${early_sz}" -- "${img}" | (
			cd -- "${outdir}/early" && cpio -idmu --quiet
		)
	fi

	# skipcpio may leave leading NULs before the zstd frame; strip them.
	python3 - "${rest}" "${tmpdir}/main.zst" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
i = 0
while i < len(data) and data[i] == 0:
	i += 1
if data[i : i + 4] != b"\x28\xb5/\xfd":
	sys.stderr.write(f"skipcpio remainder is not zstd (offset {i})\n")
	sys.exit(1)
open(dst, "wb").write(data[i:])
PY

	zstd -t -- "${tmpdir}/main.zst" >/dev/null
	zstd -dc -- "${tmpdir}/main.zst" | (
		cd -- "${outdir}/main" && cpio -idmu --quiet
	)

	# No early prefix: keep an empty early/ so pack always has early+main.
	mkdir -p -- "${outdir}/early"

	rm -rf -- "${tmpdir}"
}

# Unpack via pure newc walk + zstd (no dracut helpers required).
unpack_parse() {
	local -r img="${1}"
	local -r outdir="${2}"
	local offsets early_end main_off
	local tmpdir=""

	local -r head6="$(head -c 6 -- "${img}")"
	[ "${head6}" != "${CPIO_MAGIC}" ] && \
		errx "not a newc early+zstd initramfs (expected leading ${CPIO_MAGIC})"

	offsets="$(split_offsets "${img}")" || \
		errx "image is not early-newc + zstd main (see stderr)"
	early_end="${offsets%% *}"
	main_off="${offsets#* }"

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	local -r early_cpio="${tmpdir}/early.cpio"
	local -r main_zst="${tmpdir}/main.zst"

	head -c "${early_end}" -- "${img}" >"${early_cpio}"
	tail -c "+$((main_off + 1))" -- "${img}" >"${main_zst}"

	local -r magic_hex="$(head -c 4 -- "${main_zst}" | od -An -tx1 | tr -d ' \n')"
	[ "${magic_hex}" != "${ZSTD_MAGIC_HEX}" ] && \
		errx "main payload is not zstd (magic ${magic_hex})"

	zstd -t -- "${main_zst}" >/dev/null

	mkdir -p -- "${outdir}/early" "${outdir}/main"
	extract_cpio_file "${early_cpio}" "${outdir}/early"
	zstd -dc -- "${main_zst}" | (
		cd -- "${outdir}/main" && cpio -idmu --quiet
	)

	rm -rf -- "${tmpdir}"
}

# unpack: prefer dracut tools, fall back to AL2023 layout parser.
cmd_unpack() {
	local -r img="${1}"
	local -r outdir="${2}"
	local layout version="" method="" skipcpio=""

	[ ! -f "${img}" ] && \
		errx "initrd not found: ${img}"

	[ ! -r "${img}" ] && \
		errx "initrd not readable: ${img}"

	ensure_empty_dir "${outdir}"

	version="$(lsinitrd_version "${img}" || true)"

	if skipcpio="$(find_skipcpio)"; then
		method="skipcpio+zstd"
		for bin in python3 head; do
			! command -v "${bin}" >/dev/null 2>&1 && \
				errx "cannot find '${bin}' in 'PATH=${PATH}'"
		done
		unpack_skipcpio "${img}" "${outdir}" "${skipcpio}"
	else
		method="newc-parse+zstd"
		for bin in python3 head tail od tr; do
			! command -v "${bin}" >/dev/null 2>&1 && \
				errx "cannot find '${bin}' in 'PATH=${PATH}'"
		done
		unpack_parse "${img}" "${outdir}"
	fi

	layout="$(detect_layout "${outdir}")"
	# Ensure pack always has early+main on AL2023-style images.
	if [ "${layout}" = "flat" ]; then
		errx "unpack produced a flat tree; expected early/ and main/ (dracut multi-part)"
	fi

	write_meta "${outdir}" "${img}" "${layout}" "${version}" "${method}"

	echo "${__progname}: unpacked '${img}' -> '${outdir}'"
	echo "${__progname}: method=${method} layout=${layout} compress=${COMPRESS_DEFAULT}"
	if [ -n "${version}" ]; then
		echo "${__progname}: source dracut version: ${version}"
	fi
	echo "${__progname}: metadata: ${outdir}/${META_NAME}"
	echo "${__progname}: edit under ${outdir}/main/ (or early/), then pack"

	return 0
}

# pack: reassemble dracut-style early+main zstd initramfs.
cmd_pack() {
	local -r img="${1}"
	local -r indir="${2}"
	local layout="" compress=""
	local tmpdir=""
	local early_cpio main_blob

	[ ! -d "${indir}" ] && \
		errx "directory not found: ${indir}"

	read_meta "${indir}"

	if [ -d "${indir}/early" ] && [ -d "${indir}/main" ]; then
		layout="early+main"
	elif [ -d "${indir}/early" ] || [ -d "${indir}/main" ]; then
		errx "incomplete tree: need both early/ and main/ (dracut multi-part)"
	else
		errx "missing early/ and main/ (run unpack first)"
	fi

	[ "${compress}" != "zstd" ] && \
		errx "only zstd main compression is supported (got '${compress}')"

	local -r indir_abs="$(cd -- "${indir}" && pwd)"
	local -r img_dir="$(dirname -- "${img}")"

	mkdir -p -- "${img_dir}"

	local -r img_abs="$(cd -- "${img_dir}" && pwd)/$(basename -- "${img}")"

	case "${img_abs}" in
	"${indir_abs}"|"${indir_abs}"/*)
		errx "initrd path must not be inside the directory tree"
		;;
	esac

	trap '[ -n "${tmpdir}" ] && rm -rf -- "${tmpdir}"' EXIT

	tmpdir="$(mktemp -d "/tmp/${__progname}.XXXXXX")"
	[ -d "${tmpdir}" ] || \
		errx "mktemp -d"

	early_cpio="${tmpdir}/early.cpio"
	main_blob="${tmpdir}/main.zst"

	local epoch=""
	epoch="$(pack_source_date_epoch)"
	echo "${__progname}: packing with SOURCE_DATE_EPOCH=${epoch} (clamped mtimes, sorted cpio, zstd -T1)"

	# Normalise mtimes before cpio reads them into newc headers.
	clamp_tree_mtimes "${indir}/early" "${epoch}"
	clamp_tree_mtimes "${indir}/main" "${epoch}"

	cpio_from_dir "${indir}/early" >"${early_cpio}"
	pad_file_to_align "${early_cpio}"
	cpio_from_dir "${indir}/main" | compress_main >"${main_blob}"
	cat -- "${early_cpio}" "${main_blob}" >"${tmpdir}/out.img"
	mv -f -- "${tmpdir}/out.img" "${img_abs}"

	rm -rf -- "${tmpdir}"
	tmpdir=""
	trap - EXIT

	echo "${__progname}: packed dracut-style image '${indir}' -> '${img_abs}'"
	echo "${__progname}: layout=early+main compress=zstd (reproducible pack options on)"
	echo "${__progname}: tip: full host rebuild: dracut -f <initrd> <kver>"

	return 0
}

main() {
	[[ "$#" -ne 3 ]] && \
		usage

	[[ ! "$(uname -s)" =~ ^Linux ]] && \
		errx "Linux required"

	for bin in cpio zstd find mktemp uname head wc cat basename; do
		! command -v "${bin}" >/dev/null 2>&1 && \
			errx "cannot find '${bin}' in 'PATH=${PATH}'"
	done

	local -r mode="${1}"
	local -r initrd="${2}"
	local -r directory="${3}"

	case "${mode}" in
	unpack)
		cmd_unpack "${initrd}" "${directory}"
		;;
	pack)
		cmd_pack "${initrd}" "${directory}"
		;;
	*)
		usage
		;;
	esac

	return 0
}

main "$@"

