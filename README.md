# slot2

slot2: a two-stage UEFI GRUB2 bootkit that persists a pre-OS networked implant on Amazon Linux 2023 on AWS EC2 UEFI x86_64.

by cenobyte <vincitamorpatriae@gmail.com> 2026

https://github.com/cenobyte-vincit/slot2

## Summary

slot2 is a bootkit for Amazon Linux 2023 on EC2. The AWS EC2 UEFI firmware loads it first. An embedded implant runs in the bootkit UKI (Unified Kernel Image: one EFI file with a bootkit kernel and initrd) before the stock OS boots, network included, then `kexec` is used to start the stock kernel a normal boot would have used. The operating system that comes up is the real, stock one.

Persistence is via a UEFI NVRAM load option and two files, a bootkit ESP file and a bootkit UKI; no userspace helper/rootkit service is used/required, and not a replaced vendor bootloader. In slot2, `98-payload.sh` is the implant that's used for pre-boot C2/infil/exfil and arbitrary disk writes to insert payloads such as RATs or kernel-based rootkits on the target's filesystems. The implant in this tree is a demonstration: it writes `/root/HELLO.TXT` and brings up the network to establish an Internet/network connection, which in an operation could be a network infil or exfil.

## Boot chain

UEFI firmware does not pick a kernel by itself. It walks a BootOrder of NVRAM load options, each a numbered slot (Boot0001, Boot0002, ...) that points at one EFI executable on the ESP. On EC2, Boot0001 is always present: the Amazon EBS entry that starts stock `\EFI\BOOT\BOOTX64.EFI`. slot2 adds Boot0002, pointing at a second file on that same ESP, and puts Boot0002 first on BootOrder. Firmware still has Boot0001 as fallback.

That second file has to be something firmware can execute, and it has to reach the bootkit UKI on the root filesystem, which firmware cannot see. GRUB is used because it can read GPT and XFS, find the UKI, and chainload it. The image is a custom `grub2-mkimage`, not the packaged Amazon GRUB; stock `BOOTX64.EFI` stays where the vendor put it. GRUB's only job here is to hand off to the UKI.

The UKI kernel then runs `98-payload.sh`, then `99-kexec-stock.sh` uses `kexec` to start the stock kernel and initrd a normal BLS boot would have used.

```text
  EC2 UEFI NVRAM
  ├── Boot0001 -> stock \EFI\BOOT\BOOTX64.EFI     (untouched)
  └── Boot0002 -> bootkit \EFI\BOOT\.BOOTX64.EFI  (created; first on BootOrder)
       |
       v
  ESP (VFAT)  /boot/efi
  └── /EFI/BOOT/
      ├── BOOTX64.EFI          stock (untouched) <- Boot0001
      └── .BOOTX64.EFI         bootkit GRUB2 PE  --chainload--+  <- Boot0002
                                                              |
  root FS (XFS, typical AL2023)                               |
  └── /var/lib/systemd/boot/                                  |
      └── uki.efi  <------------------------------------------+
            |
            |  98-payload.sh, then 99-kexec-stock.sh
            |  resolve stock target under /sysroot/boot/:
            |    loader/entries/*.conf  (BLS + grubenv; AL2023 primary)
            |    grub2/grub.cfg         (legacy fallback)
            |
            +-- kexec ----------------------------------------+
                                                              |
  /boot (stock, untouched)                                    |
  ├── vmlinuz-*  <--------------------------------------------+
  └── initramfs-*.img
            |
            +-- stock initrd -> stage-2 stock userspace
```

If `kexec` fails, stage 1 continues on the UKI kernel. The box stays bootable.

## Payload

The implant is `98-payload.sh`, a dracut pre-pivot hook inside the bootkit UKI. It is not a post-boot userspace service. This tree's implementation is a demo: remount `/sysroot` read-write, write `/root/HELLO.TXT`, bring NICs up, DHCP, then `wget` ifconfig.me (5s budget). The DHCP lease and resolver file stay in the initrd (`/tmp/udhcpc.*.lease`, `/etc/resolv.conf`); they are not written onto the real root. Network failure does not block `kexec`.

Stage 1 has the real root at `/sysroot` (typically XFS, remounted rw). `/boot` is `/sysroot/boot`. Extra EBS volumes are not mounted unless the hook mounts them. The slim initrd ships busybox `udhcpc` and `wget`. `ip(8)` is the real-root binary, run via the initrd loader.

## Requirements

### Runtime host

The runtime host is the **target** (the EC2 instance that runs `deploy` and then reboots into the bootkit).

- Amazon Linux 2023 x86_64
- EC2 instances that support UEFI with AMI boot mode `uefi` or `uefi-preferred`
- Root
- ESP mounted at `/boot/efi` (systemd automount is fine; `deploy` will trigger it)
- `libefivar` and `libefiboot` (`deploy` is dynamically linked; both come with the stock OS)

ARM64 / Graviton is not tested and thus not supported (yet?).

### Build host

Amazon Linux 2023 x86_64.

- Root for `./install-dependencies.sh`
- The running kernel's `/boot/vmlinuz-$(uname -r)` and `/boot/initramfs-$(uname -r).img` (those files are packed into the UKI)
- `cc`, `make`, `pkg-config`, `grub2-mkimage`, `objcopy`, `kexec`, `openssl`, `xxd`

`./install-dependencies.sh` is the bootstrap. It installs the dnf packages above (plus `grub2-efi-x64-modules`, `systemd-boot-unsigned`, `efivar-devel`, `dracut`) and fetches the pinned busybox `udhcpc` and `wget` binaries.

## Build

On the **build host**:

```bash
./install-dependencies.sh
make
```

Bare `make` writes `uki.efi`, `BOOTX64.EFI`, and `deploy`. It does not write the ESP, `/var/lib/systemd/boot`, or NVRAM. Trailer magic and `SOURCE_DATE_EPOCH` are in ARCHITECTURE.md.

## Deploy

Copy the shipped `deploy` ELF onto the **target**. No compiler. `uki.efi` and `BOOTX64.EFI` are already inside the trailer.

```bash
scp deploy user@target-host:~/
```

On a colocated AL2023 instance the copy is optional; run `./deploy` from the build tree.

On the next reboot, firmware Boot0002 loads the ESP PE, the PE chainloads the UKI, the payload runs, then `kexec` starts the stock BLS kernel (ARCHITECTURE.md). If `deploy` prints `EFI variables are not supported on this system`, this boot is BIOS; see Requirements.


## Usage

`deploy` requires root. With no arguments it dumps trailer offsets and NVRAM and writes nothing. `-y` plants the images and NVRAM, then wipes and unlinks this executable. Any other argument prints usage.

```bash
./deploy          # dump only: trailer offsets and NVRAM; no writes
./deploy -y       # plant, then wipe and unlink this binary
reboot
```

On a successful `-y` run the process schedules a wipe of its own executable (`/dev/urandom`, truncate, unlink) after it exits, so `ls deploy` should fail. The planted UKI and bootkit GRUB image stay.

`-y` writes `/var/lib/systemd/boot/uki.efi` (`root:root`, `0500`) and `/boot/efi/EFI/BOOT/.BOOTX64.EFI` (`root:root`, best-effort `0700` on VFAT), then creates NVRAM Boot0002 and puts it first on BootOrder. Stock `BOOTX64.EFI` remains Boot0001.

## Verify

### Build host

```bash
make
```

That builds the three products. There is no in-tree test suite. A colocated `make` on an AL2023 instance that will later run `./deploy -y` is not a clean-runtime proof.

### Runtime host

After reboot you should be in stage-2 stock userspace: the kernel, `/proc/cmdline`, and initrd path that a normal BLS boot would have used.

```bash
cat /root/HELLO.TXT
# expect: stage-1 cmdline with BOOTKIT_MARKER, 98-payload.sh banner,
#         pre-OS network breadcrumbs (NIC up, DHCP/udhcpc, default route),
#         wget / external_ip=... / result, then
#         99-kexec-stock: resolve=bls:..., kexec -l ok, kexec -e

grep BOOTKIT_MARKER /proc/cmdline || echo "no marker (stage-2 ok)"
# expect: no marker

dmesg | head -3
# expect: stock-style cmdline (BLS options), not BOOTKIT_MARKER=1

uname -r
# expect: the dnf/grubby default on disk
```

## Files

`deploy -y` writes the defaults below. NVRAM BootOrder and Boot0002 are firmware state, not files.

| Path | Role |
|------|------|
| `/var/lib/systemd/boot/uki.efi` | Stage-1 UKI (kernel, bootkit initrd, cmdline) |
| `/boot/efi/EFI/BOOT/.BOOTX64.EFI` | Bootkit GRUB2 PE; firmware Boot0002 loads this |
| `/boot/efi/EFI/BOOT/BOOTX64.EFI` | Stock PE (untouched); Boot0001 fallback |
| `/boot/vmlinuz-*`, `/boot/initramfs-*.img`, `/boot/loader/entries/` | Stock kernel, initrd, and BLS; what `kexec` loads |

If you change the ESP PE name or the UKI path, keep `mk-bootx64-efi.sh`, `deploy.c`, and the NVRAM entry in sync (see ARCHITECTURE.md).

## Limitations

- The tree gates on Amazon Linux 2023 (`amzn` / 2023) and an EC2-shaped Boot0001. Embedded PE checks require AMD64 (`0x8664`). ARM64 / Graviton is not (yet?) supported.
- Secure Boot is out of scope. Stock EC2 has it off. Images are unsigned.
- This is persistence/bootkit only. The UKI and ESP PE remain visible to a full disk walk. Filtering directory listings or `open` by a rootkit LKM is out of scope for this project.
- The `deploy` self-wipe is best-effort. It is not a secure erase on SSD or NVMe. A custom `deploy` is recommended for full weaponisation and a higher degree of OPSEC.
- Developed and exercised on `c5a.xlarge` and `t3.nano`.

## See also

- ARCHITECTURE.md
