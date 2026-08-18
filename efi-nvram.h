/*
 * efi-nvram.h - Shared UEFI NVRAM dump and Boot0002 create API.
 *
 * Implemented in efi-nvram.c; used by deploy(1).
 * Linux + libefivar/libefiboot (Amazon Linux 2023 EC2 UEFI x86_64).
 */

#ifndef EFI_NVRAM_H
#define EFI_NVRAM_H

/*
 * Abort unless running as root and EFI variables are supported/readable.
 */
void efi_nvram_require_root_and_efi(void);

/*
 * Print BootNext/BootCurrent/Timeout/BootOrder and each Boot#### entry.
 */
void efi_nvram_dump_boot_vars(void);

/*
 * Ensure Boot0002 points at \EFI\BOOT\.BOOTX64.EFI and is first in
 * BootOrder (EC2-gated). Idempotent. Does not dump variables.
 */
void efi_nvram_create(void);

#endif /* EFI_NVRAM_H */
