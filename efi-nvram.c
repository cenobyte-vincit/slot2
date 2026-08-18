/*
 * efi-nvram.c - UEFI boot variable dump and Boot0002 create (shared).
 *
 * Used by deploy(1). Public entry points are declared in efi-nvram.h.
 *
 * efi_nvram_create() validates Boot0001 against EC2 policy, resolves the
 * ESP from /boot/efi via sysfs, ensures Boot0002 is a load option labelled
 * like Boot0001 pointing at \EFI\BOOT\.BOOTX64.EFI (no-op if already
 * correct), and prepends Boot0002 to BootOrder when writing. Callers own
 * before/after dumps via efi_nvram_dump_boot_vars().
 */

/*
 * glibc + -std=c17: need a feature macro for strdup/realpath (not in pure ISO C).
 * _DEFAULT_SOURCE is the usual Linux set; keeps both POSIX and XSI bits visible.
 */
#define _DEFAULT_SOURCE

#include "efi-nvram.h"

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <efiboot.h>
#include <efivar.h>

extern char *__progname;

/* UEFI load-option attribute: entry is active in the boot manager. */
#define LOAD_OPTION_ACTIVE	0x00000001U

/* Loader path written into the new Boot#### entry (UEFI File() form). */
#define NEW_LOADER_PATH		"\\EFI\\BOOT\\.BOOTX64.EFI"

/* Fixed slot used by deploy -y (NVRAM create) for the NEW loader entry. */
#define CREATE_BOOT_NUM		0x0002U
#define CREATE_BOOT_NAME	"Boot0002"

/*
 * ---------------------------------------------------------------------------
 * EC2-specific policy
 *
 * These prefixes hardcode NVRAM create to Amazon EC2 UEFI boot entries.
 * To support bare-metal / non-EC2 hardware later: delete (or stub out)
 * check_ec2_boot0001() and remove the call from cmd_create(). ESP discovery
 * via /boot/efi + sysfs is intentionally generic and should remain.
 * ---------------------------------------------------------------------------
 */
#define EC2_LABEL_PREFIX	"UEFI Amazon Elastic Block Store"
/* Full PCI/NVMe form (common on Boot0002-style whole-disk entries). */
#define EC2_PATH_PREFIX_PCI	"PciRoot(0x0)/Pci"
/* Abbreviated GPT HD+File form (common on Boot0001 -> \\EFI\\BOOT\\BOOTX64.EFI). */
#define EC2_PATH_PREFIX_HD	"HD("

typedef struct boot_entry {
	char		*name;
	uint8_t		*data;
	size_t		data_size;
	uint16_t	num;
} boot_entry_t;

static int read_u16_var(const char *, uint16_t *);
static void print_boot_order(void);
static int is_boot_var(const efi_guid_t *, const char *);
static int collect_boot_entries(boot_entry_t **, size_t *);
static void free_boot_entries(boot_entry_t *, size_t);
static int boot_entry_cmp(const void *, const void *);
static void print_boot_entry(const boot_entry_t *);
static char *format_device_path(efi_load_option *, size_t);
static void print_device_path(efi_load_option *, size_t);
static char *skip_token(char **);
static int devpath_from_maj_min(unsigned int, unsigned int, char *, size_t);
static int find_boot_efi_blockdev(char *, size_t);
static void resolve_esp_from_boot_efi(char *, size_t);
static void disk_and_part_from_dev(const char *, char *, size_t, int *);
static void load_boot0001(uint8_t **, size_t *);
static char *label_from_boot0001(const uint8_t *, size_t);
static void check_ec2_boot0001(const uint8_t *, size_t);
static uint8_t *generate_esp_device_path(const char *, int, ssize_t *);
static int boot0002_already_desired(const char *, const char *, int);
static void prepend_boot_order(uint16_t);
static void create_boot_entry(const char *, int, const char *, uint16_t);

/*
 * Require root and that EFI variables are readable on this host.
 */
void
efi_nvram_require_root_and_efi(void)
{
	if (geteuid() != 0)
		errx(1, "must be run as root");
	if (!efi_variables_supported())
		errx(1, "EFI variables are not supported on this system");
}

/*
 * Read a 16-bit EFI global variable. Returns 0 on success, -1 if missing
 * or invalid (errno set).
 */
static int
read_u16_var(const char *name, uint16_t *out)
{
	uint8_t *data;
	size_t data_size;
	uint32_t attributes;
	int rc;

	data = NULL;
	data_size = 0;
	attributes = 0;
	rc = efi_get_variable(efi_guid_global, name, &data, &data_size,
	    &attributes);
	if (rc < 0)
		return (-1);
	if (data_size != sizeof(*out)) {
		free(data);
		errno = EINVAL;
		return (-1);
	}
	memcpy(out, data, sizeof(*out));
	free(data);
	return (0);
}

/*
 * Print BootOrder as comma-separated hex IDs.
 */
static void
print_boot_order(void)
{
	uint8_t *data;
	size_t data_size, n, i;
	uint32_t attributes;
	uint16_t *order;
	int rc;

	data = NULL;
	data_size = 0;
	attributes = 0;
	rc = efi_get_variable(efi_guid_global, "BootOrder", &data, &data_size,
	    &attributes);
	if (rc < 0) {
		if (errno == ENOENT) {
			printf("No BootOrder is set; firmware will attempt "
			    "recovery\n");
			return;
		}
		err(1, "cannot read BootOrder");
	}
	if (data_size == 0) {
		free(data);
		printf("No BootOrder is set; firmware will attempt recovery\n");
		return;
	}
	if (data_size % sizeof(uint16_t) != 0) {
		free(data);
		errx(1, "BootOrder has invalid size");
	}
	order = (uint16_t *)(void *)data;
	n = data_size / sizeof(uint16_t);
	printf("BootOrder: ");
	for (i = 0; i < n; i++) {
		printf("%04X", order[i]);
		if (i + 1 < n)
			printf(",");
	}
	printf("\n");
	free(data);
}

/*
 * True when name is Boot#### under the EFI global GUID.
 */
static int
is_boot_var(const efi_guid_t *guid, const char *name)
{
	if (efi_guid_cmp(guid, &efi_guid_global) != 0)
		return (0);
	if (strncmp(name, "Boot", 4) != 0)
		return (0);
	if (!isxdigit((unsigned char)name[4]) ||
	    !isxdigit((unsigned char)name[5]) ||
	    !isxdigit((unsigned char)name[6]) ||
	    !isxdigit((unsigned char)name[7]))
		return (0);
	if (name[8] != '\0')
		return (0);
	return (1);
}

/*
 * Collect Boot#### variables into a newly allocated array. Caller frees
 * with free_boot_entries().
 */
static int
collect_boot_entries(boot_entry_t **out, size_t *out_n)
{
	boot_entry_t *entries;
	efi_guid_t *guid;
	char *name;
	size_t n, cap;
	int rc;

	entries = NULL;
	guid = NULL;
	name = NULL;
	n = 0;
	cap = 0;

	while ((rc = efi_get_next_variable_name(&guid, &name)) > 0) {
		boot_entry_t *e;
		unsigned int num;
		uint8_t *data;
		size_t data_size;
		uint32_t attributes;

		if (!is_boot_var(guid, name))
			continue;
		if (sscanf(name, "Boot%04X", &num) != 1)
			continue;

		data = NULL;
		data_size = 0;
		attributes = 0;
		rc = efi_get_variable(efi_guid_global, name, &data, &data_size,
		    &attributes);
		if (rc < 0) {
			warn("skipping unreadable variable %s", name);
			continue;
		}

		if (n == cap) {
			boot_entry_t *tmp;
			size_t new_cap;

			new_cap = cap == 0 ? 8 : cap * 2;
			tmp = realloc(entries, new_cap * sizeof(*entries));
			if (tmp == NULL)
				errx(1, "realloc");
			entries = tmp;
			cap = new_cap;
		}

		e = &entries[n];
		e->name = strdup(name);
		if (e->name == NULL)
			errx(1, "malloc");
		e->data = data;
		e->data_size = data_size;
		e->num = (uint16_t)num;
		n++;
	}
	if (rc < 0)
		err(1, "enumerating EFI variables");

	*out = entries;
	*out_n = n;
	return (0);
}

/*
 * Free boot entry array and per-entry name/data buffers.
 */
static void
free_boot_entries(boot_entry_t *entries, size_t n)
{
	size_t i;

	if (entries == NULL)
		return;
	for (i = 0; i < n; i++) {
		free(entries[i].name);
		free(entries[i].data);
	}
	free(entries);
}

/*
 * Sort Boot#### by variable name (Boot0000, Boot0001, ...).
 */
static int
boot_entry_cmp(const void *a, const void *b)
{
	const boot_entry_t *ea = a;
	const boot_entry_t *eb = b;

	return (strcmp(ea->name, eb->name));
}

/*
 * Format the load-option device path into a newly allocated C string.
 * Returns NULL if the path is missing or cannot be parsed.
 */
static char *
format_device_path(efi_load_option *load_option, size_t data_size)
{
	char *text_path;
	size_t text_path_len;
	uint16_t pathlen;
	efidp dp;
	ssize_t rc;

	pathlen = efi_loadopt_pathlen(load_option, (ssize_t)data_size);
	dp = efi_loadopt_path(load_option, (ssize_t)data_size);
	if (dp == NULL || pathlen == 0)
		return (NULL);

	rc = efidp_format_device_path(NULL, 0, dp, pathlen);
	if (rc < 0)
		return (NULL);
	text_path_len = (size_t)rc + 1;
	text_path = malloc(text_path_len);
	if (text_path == NULL)
		errx(1, "malloc");

	rc = efidp_format_device_path((unsigned char *)text_path,
	    text_path_len, dp, pathlen);
	if (rc < 0) {
		free(text_path);
		return (NULL);
	}
	return (text_path);
}

/*
 * Format and print the load-option device path after a tab.
 */
static void
print_device_path(efi_load_option *load_option, size_t data_size)
{
	char *text_path;

	text_path = format_device_path(load_option, data_size);
	if (text_path == NULL) {
		printf("\n");
		return;
	}
	printf("\t%s\n", text_path);
	free(text_path);
}

/*
 * Print one Boot#### line: name, active marker, description, device path.
 */
static void
print_boot_entry(const boot_entry_t *entry)
{
	efi_load_option *load_option;
	const unsigned char *desc;
	uint32_t attrs;

	if (!efi_loadopt_is_valid((efi_load_option *)entry->data,
	    entry->data_size)) {
		printf("%s  <invalid load option>\n", entry->name);
		return;
	}

	load_option = (efi_load_option *)entry->data;
	attrs = efi_loadopt_attrs(load_option);
	desc = efi_loadopt_desc(load_option, (ssize_t)entry->data_size);

	printf("%s%c ", entry->name,
	    (attrs & LOAD_OPTION_ACTIVE) ? '*' : ' ');
	if (desc != NULL)
		printf("%s", desc);
	print_device_path(load_option, entry->data_size);
}

/*
 * Print the full boot-variable listing.
 */
void
efi_nvram_dump_boot_vars(void)
{
	boot_entry_t *entries;
	size_t n, i;
	uint16_t val;

	if (read_u16_var("BootNext", &val) == 0)
		printf("BootNext: %04X\n", val);

	if (read_u16_var("BootCurrent", &val) == 0)
		printf("BootCurrent: %04X\n", val);
	else if (errno != ENOENT)
		err(1, "cannot read BootCurrent");

	if (read_u16_var("Timeout", &val) == 0)
		printf("Timeout: %u seconds\n", (unsigned int)val);

	print_boot_order();

	entries = NULL;
	n = 0;
	collect_boot_entries(&entries, &n);
	if (n > 1)
		qsort(entries, n, sizeof(*entries), boot_entry_cmp);
	for (i = 0; i < n; i++)
		print_boot_entry(&entries[i]);
	free_boot_entries(entries, n);
}

/*
 * Null-terminate the next whitespace-delimited token in *pp and advance.
 * Returns the token start, or NULL at end of line.
 */
static char *
skip_token(char **pp)
{
	char *p;
	char *start;

	p = *pp;
	while (*p == ' ' || *p == '\t')
		p++;
	if (*p == '\0' || *p == '\n') {
		*pp = p;
		return (NULL);
	}
	start = p;
	while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\n')
		p++;
	if (*p != '\0')
		*p++ = '\0';
	*pp = p;
	return (start);
}

/*
 * Map a kernel maj:min to /dev/<name> via /sys/dev/block/M:N.
 * Returns 0 on success, -1 if the node is missing or not resolvable.
 */
static int
devpath_from_maj_min(unsigned int maj, unsigned int min, char *devpath,
    size_t devpath_sz)
{
	char sys[64];
	char resolved[PATH_MAX];
	const char *base;

	/* 0:0 is used by autofs placeholders, not a real block device. */
	if (maj == 0 && min == 0)
		return (-1);

	if (snprintf(sys, sizeof(sys), "/sys/dev/block/%u:%u", maj, min) >=
	    (int)sizeof(sys))
		return (-1);
	if (realpath(sys, resolved) == NULL)
		return (-1);

	base = strrchr(resolved, '/');
	if (base == NULL || base[1] == '\0')
		return (-1);
	base++;

	if (snprintf(devpath, devpath_sz, "/dev/%s", base) >= (int)devpath_sz)
		return (-1);
	return (0);
}

/*
 * Scan mountinfo for a real filesystem on /boot/efi (skip autofs stubs).
 * Prefer maj:min -> /sys/dev/block; fall back to a /dev/ source path.
 * Returns 0 on success, -1 if no suitable mount is present.
 */
static int
find_boot_efi_blockdev(char *devpath, size_t devpath_sz)
{
	FILE *fp;
	char line[4096];
	int found;

	fp = fopen("/proc/self/mountinfo", "r");
	if (fp == NULL)
		err(1, "cannot open /proc/self/mountinfo");

	found = 0;
	while (fgets(line, sizeof(line), fp) != NULL) {
		char *p;
		char *tok;
		char *mount_point;
		char *fstype;
		char *source;
		char *colon;
		unsigned int maj, min;
		int field;

		p = line;
		mount_point = NULL;
		maj = 0;
		min = 0;

		/*
		 * mountinfo: id parent major:minor root mountpoint ...
		 * field index 0..4 above; field 2 is "maj:min".
		 */
		for (field = 0; field < 5; field++) {
			tok = skip_token(&p);
			if (tok == NULL)
				break;
			if (field == 2) {
				colon = strchr(tok, ':');
				if (colon == NULL)
					break;
				*colon = '\0';
				maj = (unsigned int)strtoul(tok, NULL, 10);
				min = (unsigned int)strtoul(colon + 1, NULL,
				    10);
			}
			if (field == 4)
				mount_point = tok;
		}
		if (mount_point == NULL ||
		    strcmp(mount_point, "/boot/efi") != 0)
			continue;

		/* Field 5: mount options. */
		if (skip_token(&p) == NULL)
			continue;

		/* Optional fields, then "-". */
		for (;;) {
			tok = skip_token(&p);
			if (tok == NULL)
				break;
			if (strcmp(tok, "-") == 0)
				break;
		}
		if (tok == NULL || strcmp(tok, "-") != 0)
			continue;

		fstype = skip_token(&p);
		source = skip_token(&p);
		if (fstype == NULL || source == NULL)
			continue;

		/* systemd .automount leaves an autofs stub (source systemd-1). */
		if (strcmp(fstype, "autofs") == 0)
			continue;

		if (devpath_from_maj_min(maj, min, devpath, devpath_sz) == 0) {
			found = 1;
			break;
		}
		if (strncmp(source, "/dev/", 5) == 0) {
			if (snprintf(devpath, devpath_sz, "%s", source) >=
			    (int)devpath_sz)
				errx(1, "device path too long");
			found = 1;
			break;
		}
	}
	fclose(fp);

	return (found ? 0 : -1);
}

/*
 * Resolve the block device for /boot/efi.
 * Triggers systemd automount if only an autofs stub is present, then maps
 * maj:min (or /dev source) to a partition path such as /dev/nvme0n1p128.
 */
static void
resolve_esp_from_boot_efi(char *devpath, size_t devpath_sz)
{
	struct stat st;

	if (find_boot_efi_blockdev(devpath, devpath_sz) == 0)
		return;

	/*
	 * Common on Amazon Linux: /boot/efi is systemd-automounted. Touching
	 * the path forces the real vfat mount into mountinfo.
	 */
	if (stat("/boot/efi", &st) != 0)
		err(1, "cannot access /boot/efi");

	if (find_boot_efi_blockdev(devpath, devpath_sz) == 0)
		return;

	errx(1, "/boot/efi is not mounted on a block device "
	    "(is the ESP automount working?)");
}

/*
 * From a partition device path, use sysfs to learn the GPT partition
 * number and whole-disk path for libefiboot.
 *
 *   /dev/nvme0n1p128  ->  disk=/dev/nvme0n1  part=128
 *
 * Reads /sys/class/block/<base>/partition and the parent of the realpath
 * of /sys/class/block/<base>.
 */
static void
disk_and_part_from_dev(const char *devpath, char *disk, size_t disksz,
    int *part)
{
	const char *base;
	char sys_part[PATH_MAX];
	char sys_link[PATH_MAX];
	char resolved[PATH_MAX];
	char *slash;
	FILE *fp;
	unsigned int partnum;
	int rc;

	base = strrchr(devpath, '/');
	if (base == NULL || base[1] == '\0')
		errx(1, "invalid device path %s", devpath);
	base++;

	if (snprintf(sys_part, sizeof(sys_part),
	    "/sys/class/block/%s/partition", base) >= (int)sizeof(sys_part))
		errx(1, "sysfs path too long");

	fp = fopen(sys_part, "r");
	if (fp == NULL)
		err(1, "%s is not a partition device", devpath);
	rc = fscanf(fp, "%u", &partnum);
	fclose(fp);
	if (rc != 1)
		errx(1, "cannot read partition number for %s", devpath);
	if (partnum > INT_MAX)
		errx(1, "partition number out of range");
	*part = (int)partnum;

	if (snprintf(sys_link, sizeof(sys_link),
	    "/sys/class/block/%s", base) >= (int)sizeof(sys_link))
		errx(1, "sysfs path too long");

	if (realpath(sys_link, resolved) == NULL)
		err(1, "realpath %s", sys_link);

	/* .../block/<disk>/<part>  -> parent basename is the disk name. */
	slash = strrchr(resolved, '/');
	if (slash == NULL || slash == resolved)
		errx(1, "unexpected sysfs layout for %s", base);
	*slash = '\0';
	slash = strrchr(resolved, '/');
	if (slash == NULL || slash[1] == '\0')
		errx(1, "unexpected sysfs layout for %s", base);

	if (snprintf(disk, disksz, "/dev/%s", slash + 1) >= (int)disksz)
		errx(1, "disk path too long");
}

/*
 * Load the Boot0001 variable payload. Caller frees *data.
 */
static void
load_boot0001(uint8_t **data, size_t *data_size)
{
	uint32_t attributes;
	int rc;

	*data = NULL;
	*data_size = 0;
	attributes = 0;
	rc = efi_get_variable(efi_guid_global, "Boot0001", data, data_size,
	    &attributes);
	if (rc < 0)
		err(1, "cannot read Boot0001");
	if (!efi_loadopt_is_valid((efi_load_option *)*data, *data_size))
		errx(1, "Boot0001 is not a valid load option");
}

/*
 * Return a newly allocated copy of Boot0001's description string.
 */
static char *
label_from_boot0001(const uint8_t *data, size_t data_size)
{
	efi_load_option *opt;
	const unsigned char *desc;
	char *label;

	opt = (efi_load_option *)data;
	desc = efi_loadopt_desc(opt, (ssize_t)data_size);
	if (desc == NULL || desc[0] == '\0')
		errx(1, "Boot0001 has an empty description");
	label = strdup((const char *)desc);
	if (label == NULL)
		errx(1, "malloc");
	return (label);
}

/*
 * EC2-specific gates on Boot0001. Remove this function (and its caller)
 * to allow create on non-EC2 UEFI systems.
 */
static void
check_ec2_boot0001(const uint8_t *data, size_t data_size)
{
	efi_load_option *opt;
	const unsigned char *desc;
	char *path;

	opt = (efi_load_option *)data;
	desc = efi_loadopt_desc(opt, (ssize_t)data_size);
	if (desc == NULL)
		errx(1, "Boot0001 has no description");

	/* EC2: label must identify an Amazon EBS boot entry. */
	if (strncmp((const char *)desc, EC2_LABEL_PREFIX,
	    strlen(EC2_LABEL_PREFIX)) != 0)
		errx(1, "Boot0001 label must start with \"%s\" (got \"%s\")",
		    EC2_LABEL_PREFIX, desc);

	path = format_device_path(opt, data_size);
	if (path == NULL)
		errx(1, "Boot0001 has no usable device path");

	/*
	 * EC2: accept either abbreviated HD(...)/File(...) (typical Boot0001
	 * ESP loader path) or PciRoot(0x0)/Pci... (full Nitro path). Both show
	 * up on Amazon Linux EC2 depending on how the entry was created.
	 */
	if (strncmp(path, EC2_PATH_PREFIX_HD, strlen(EC2_PATH_PREFIX_HD)) != 0 &&
	    strncmp(path, EC2_PATH_PREFIX_PCI,
	    strlen(EC2_PATH_PREFIX_PCI)) != 0) {
		errx(1, "Boot0001 path must start with \"%s\" or \"%s\" (got \"%s\")",
		    EC2_PATH_PREFIX_HD, EC2_PATH_PREFIX_PCI, path);
	}
	free(path);
}

/*
 * Build the HD+File device path for disk/part + NEW_LOADER_PATH.
 * Caller frees the returned buffer; *out_len is set to its size.
 */
static uint8_t *
generate_esp_device_path(const char *disk, int part, ssize_t *out_len)
{
	uint8_t *dp;
	ssize_t needed;

	needed = efi_generate_file_device_path_from_esp(NULL, 0, disk, part,
	    NEW_LOADER_PATH, EFIBOOT_ABBREV_HD, 0x80);
	if (needed < 0)
		err(1, "cannot generate device path for %s part %d", disk,
		    part);

	dp = malloc((size_t)needed);
	if (dp == NULL)
		errx(1, "malloc");

	needed = efi_generate_file_device_path_from_esp(dp, needed, disk, part,
	    NEW_LOADER_PATH, EFIBOOT_ABBREV_HD, 0x80);
	if (needed < 0) {
		free(dp);
		dp = NULL;
		err(1, "cannot generate device path for %s part %d", disk,
		    part);
	}
	*out_len = needed;
	return (dp);
}

/*
 * True when Boot0002 already has the expected label and the device path
 * we would write for disk/part + NEW_LOADER_PATH (no NVRAM change needed).
 */
static int
boot0002_already_desired(const char *label, const char *disk, int part)
{
	uint8_t *data;
	uint8_t *want_dp;
	size_t data_size;
	uint32_t attributes;
	ssize_t want_len;
	efi_load_option *opt;
	const unsigned char *desc;
	efidp got_dp;
	uint16_t got_len;
	int rc;
	int match;

	data = NULL;
	data_size = 0;
	attributes = 0;
	rc = efi_get_variable(efi_guid_global, CREATE_BOOT_NAME, &data,
	    &data_size, &attributes);
	if (rc < 0) {
		if (errno == ENOENT)
			return (0);
		err(1, "cannot read %s", CREATE_BOOT_NAME);
	}

	if (!efi_loadopt_is_valid((efi_load_option *)data, data_size)) {
		free(data);
		return (0);
	}

	opt = (efi_load_option *)data;
	desc = efi_loadopt_desc(opt, (ssize_t)data_size);
	if (desc == NULL || strcmp((const char *)desc, label) != 0) {
		free(data);
		return (0);
	}

	want_dp = generate_esp_device_path(disk, part, &want_len);
	got_len = efi_loadopt_pathlen(opt, (ssize_t)data_size);
	got_dp = efi_loadopt_path(opt, (ssize_t)data_size);

	match = 0;
	if (got_dp != NULL && (ssize_t)got_len == want_len &&
	    memcmp(got_dp, want_dp, (size_t)want_len) == 0)
		match = 1;

	free(want_dp);
	free(data);
	return (match);
}

/*
 * Prepend bootnum to BootOrder (create if missing). Drops any prior
 * duplicate of bootnum so it appears once at the front.
 */
static void
prepend_boot_order(uint16_t bootnum)
{
	uint8_t *old_data;
	size_t old_size, new_size, old_n, new_n, i;
	uint32_t attributes;
	uint16_t *old_order;
	uint16_t *new_order;
	int rc;

	old_data = NULL;
	old_size = 0;
	attributes = EFI_VARIABLE_NON_VOLATILE |
	    EFI_VARIABLE_BOOTSERVICE_ACCESS |
	    EFI_VARIABLE_RUNTIME_ACCESS;

	rc = efi_get_variable(efi_guid_global, "BootOrder", &old_data,
	    &old_size, &attributes);
	if (rc < 0) {
		if (errno != ENOENT)
			err(1, "cannot read BootOrder");
		old_data = NULL;
		old_size = 0;
		attributes = EFI_VARIABLE_NON_VOLATILE |
		    EFI_VARIABLE_BOOTSERVICE_ACCESS |
		    EFI_VARIABLE_RUNTIME_ACCESS;
	}

	/* Clear Apple-style high attribute bit if present. */
	attributes &= ~(uint32_t)(1U << 31);

	old_n = old_size / sizeof(uint16_t);
	old_order = (uint16_t *)(void *)old_data;

	new_n = 1;
	for (i = 0; i < old_n; i++) {
		if (old_order[i] != bootnum)
			new_n++;
	}

	new_size = new_n * sizeof(uint16_t);
	new_order = malloc(new_size);
	if (new_order == NULL)
		errx(1, "malloc");

	new_order[0] = bootnum;
	new_n = 1;
	for (i = 0; i < old_n; i++) {
		if (old_order[i] == bootnum)
			continue;
		new_order[new_n++] = old_order[i];
	}

	rc = efi_set_variable(efi_guid_global, "BootOrder",
	    (uint8_t *)new_order, new_n * sizeof(uint16_t), attributes, 0644);
	free(new_order);
	free(old_data);
	if (rc < 0)
		err(1, "cannot set BootOrder");
}

/*
 * Build and write Boot#### with an HD+File path to NEW_LOADER_PATH.
 */
static void
create_boot_entry(const char *disk, int part, const char *label,
    uint16_t bootnum)
{
	uint8_t *dp;
	uint8_t *opt;
	ssize_t dp_needed;
	ssize_t opt_needed;
	uint32_t var_attrs;
	char name[16];
	int rc;

	dp = generate_esp_device_path(disk, part, &dp_needed);

	opt_needed = efi_loadopt_create(NULL, 0, LOAD_OPTION_ACTIVE,
	    (efidp)dp, dp_needed, (unsigned char *)label, NULL, 0);
	if (opt_needed < 0) {
		free(dp);
		err(1, "cannot build boot entry for %s part %d", disk, part);
	}

	opt = malloc((size_t)opt_needed);
	if (opt == NULL) {
		free(dp);
		errx(1, "malloc");
	}

	opt_needed = efi_loadopt_create(opt, opt_needed, LOAD_OPTION_ACTIVE,
	    (efidp)dp, dp_needed, (unsigned char *)label, NULL, 0);
	free(dp);
	if (opt_needed < 0) {
		free(opt);
		err(1, "cannot build boot entry for %s part %d", disk, part);
	}

	if (snprintf(name, sizeof(name), "Boot%04X", bootnum) >=
	    (int)sizeof(name)) {
		free(opt);
		errx(1, "boot variable name too long");
	}

	var_attrs = (uint32_t)(EFI_VARIABLE_NON_VOLATILE |
	    EFI_VARIABLE_BOOTSERVICE_ACCESS |
	    EFI_VARIABLE_RUNTIME_ACCESS);

	rc = efi_set_variable(efi_guid_global, name, opt, (size_t)opt_needed,
	    var_attrs, 0644);
	free(opt);
	if (rc < 0)
		err(1, "cannot set %s", name);

	printf("Created %s label=\"%s\" disk=%s part=%d loader=%s\n",
	    name, label, disk, part, NEW_LOADER_PATH);
}

/*
 * EC2-gated new boot entry from /boot/efi + Boot0001 label.
 * Does not dump variables; callers print before/after as needed.
 */
void
efi_nvram_create(void)
{
	uint8_t *boot0001;
	size_t boot0001_size;
	char *label;
	char part_dev[PATH_MAX];
	char disk[PATH_MAX];
	int part;

	boot0001 = NULL;
	boot0001_size = 0;
	load_boot0001(&boot0001, &boot0001_size);

	/* EC2-only: remove this call for generic hardware. */
	check_ec2_boot0001(boot0001, boot0001_size);

	label = label_from_boot0001(boot0001, boot0001_size);
	free(boot0001);
	boot0001 = NULL;

	resolve_esp_from_boot_efi(part_dev, sizeof(part_dev));
	disk_and_part_from_dev(part_dev, disk, sizeof(disk), &part);

	/*
	 * Idempotent: Boot0002 already has the label we would copy and the
	 * HD+File path we would set for NEW_LOADER_PATH on this ESP.
	 */
	if (boot0002_already_desired(label, disk, part)) {
		printf("%s already has the expected label and device path; "
		    "nothing to do\n", CREATE_BOOT_NAME);
		free(label);
		return;
	}

	create_boot_entry(disk, part, label, (uint16_t)CREATE_BOOT_NUM);
	prepend_boot_order((uint16_t)CREATE_BOOT_NUM);
	free(label);
}
