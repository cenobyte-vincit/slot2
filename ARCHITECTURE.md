# Architecture

slot2 persists a pre-OS implant by owning firmware BootOrder. The installer leaves stock `\EFI\BOOT\BOOTX64.EFI` and the packaged GRUB RPM in place. It writes a second PE on the ESP, a UKI on the root filesystem, and a Boot0002 load option that firmware tries first. Stage 1 is that UKI. Stage 2 is a `kexec` of the stock kernel and initrd that a normal BLS boot would have used. The running OS is not the implant kernel.

`kexec` exists so the persistence surface is the early chain, not an alternate OS. Staying on the UKI kernel for uptime would leave a stage-1 cmdline (`BOOTKIT_MARKER=1`) and a non-stock boot path as durable signals.

## Hosts

The **build host** is Amazon Linux 2023 x86_64. That is where `./install-dependencies.sh`, `make`, `cc`, `grub2-mkimage`, `objcopy`, and cppcheck run. The UKI is packed from this host's running `/boot/vmlinuz-$(uname -r)` and `/boot/initramfs-$(uname -r).img`.

The **runtime host** is the **target**: an Amazon Linux 2023 x86_64 EC2 instance whose *this boot* is UEFI, with an EC2-shaped Boot0001. It runs the shipped `deploy` ELF and then reboots. It does not need a compiler, headers, `make`, or cppcheck. `deploy` is dynamically linked against `libefivar` and `libefiboot`.

Firmware mode is not the disk layout. Stock AL2023 often ships GPT, an ESP at `/boot/efi`, and `\EFI\BOOT\BOOTX64.EFI` on a BIOS boot. Xen types (`t2`, disks named `/dev/xvda*`) cannot do UEFI. Nitro types (`t3`, `t3a`, `c5`, `c5a`, ...) can, but only when the AMI boot mode is `uefi` or `uefi-preferred`; the default AL2023 AMI is often `legacy-bios` and then Nitro still boots BIOS. `efi_variables_supported()` in libefivar is the kernel check for `/sys/firmware/efi`. When that directory is missing, `deploy` prints `EFI variables are not supported on this system` and writes nothing. You cannot convert a running instance; launch with a UEFI AMI on Nitro. IMDS `boot-mode` and `CurrentInstanceBootMode` on the instance object report the same fact AWS used for this boot.

Colocated build-and-install on one AL2023 instance is allowed for a short test. `make` does not write the ESP, `/var/lib/systemd/boot`, or NVRAM. Colocated `make` is not a clean-runtime proof.

Automated verification is `make` (build plus cppcheck) on the build host. There is no in-tree unit or functional test suite. That run does not prove a clean target reboot.

There is no application data store. Persistence is the install: NVRAM Boot0002 / BootOrder, `/boot/efi/EFI/BOOT/.BOOTX64.EFI`, and `/var/lib/systemd/boot/uki.efi`. A fresh OS image removes those files; firmware NVRAM may survive a disk-only reimage and may not be in an EBS snapshot. Restore is a rebuild on the build host and another `deploy -y`. Backup/restore of a project database is N/A.

## Chain

`deploy` is the in-tree dropper. It unpacks two PEs and writes NVRAM. It is not the implant.

**Stage 1** is the firmware path: Boot0002 loads the bootkit GRUB2 PE, the PE chainloads the UKI, the UKI kernel runs the bootkit initrd, and dracut sources `98-payload.sh` then `99-kexec-stock.sh` at pre-pivot.

The **payload** is `98-payload.sh`. This tree's copy is a chain check (write `/root/HELLO.TXT`, optional NIC / DHCP / HTTP). Swap that file for operational command and control (C2) or infil/exfil. It is not a long-lived implant process. Occupancy of the chain is a **bootkit**: it persists in firmware and runs at bootloader time, before stock userspace. It is not a rootkit. The leading dot on `.BOOTX64.EFI` only hides the file from a bare `ls` on VFAT.

**Stage 2** is stock userspace after `kexec -e`. `99-kexec-stock.sh` is the handoff, not a second implant.

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

If `kexec` fails, stage 1 continues on the UKI kernel. The box stays bootable. Stage-1 `dmesg` does not carry into stage 2.

## Build-host bootstrap

Root on AL2023 x86_64:

```bash
./install-dependencies.sh
make
```

`install-dependencies.sh` is idempotent. It `dnf install`s only what is missing: `grub2-tools`, `grub2-efi-x64-modules`, `dracut`, `binutils`, `systemd-boot-unsigned`, `gcc`, `pkgconf`, `efivar-devel`, `openssl`, `vim-common`, `cppcheck`, `kexec-tools`, `curl-minimal`. It then fetches busybox 1.35.0 `x86_64-linux-musl` `busybox_UDHCPC` and `busybox_WGET` from a version-pinned URL and checks each SHA-256. Bump the URL path and the digest together.

`make` PATH is `/usr/sbin:/usr/bin:/sbin:/bin`. C flags are C17, `-Wall -Wextra -Werror -pedantic`, `-g0`, and prefix-map of the checkout to `.`. Link is dynamic (`pkg-config --libs efivar efiboot`). There is no codesign step. Secure Boot is out of scope; stock EC2 has it off.

`SOURCE_DATE_EPOCH` defaults to `git log -1 --pretty=%ct`, else `0`. It is compiled into the trailer magic (`gen-deploy-magic.sh`) and used to clamp initrd member mtimes (`initrd-packer.sh`). The intermediate `initramfs-$(uname -r).insert.img` is deleted after `mk-uki.sh` embeds it.

Place `deploy` on the target by copy (`scp`). Do not compile on the target.

## Components

| File | Role |
|------|------|
| `Makefile` | Builds `uki.efi`, `BOOTX64.EFI`, `deploy`; runs cppcheck |
| `install-dependencies.sh` | Build-host dnf + pinned busybox fetch |
| `mk-uki.sh` | `objcopy` pack of kernel + bootkit initrd + PE `.cmdline` onto `linuxx64.efi.stub` |
| `mk-bootx64-efi.sh` | `grub2-mkimage` PE whose early config `search.file`s the UKI |
| `initrd-packer.sh` | Unpack / pack AL2023 dracut (early newc + 512-byte pad + zstd main) |
| `initrd-prune.sh` | Drop unused CLIs from the unpacked `main/` tree |
| `inject-kexec.sh` | Copy host `kexec` and missing `ldd` libs into `main/` |
| `inject-udhcpc.sh` | Copy `busybox_UDHCPC` to `usr/sbin/udhcpc` and write `usr/share/udhcpc/default.script` |
| `inject-wget.sh` | Copy `busybox_WGET` to `usr/bin/wget` |
| `98-payload.sh` | Pre-pivot implant (swap this) |
| `99-kexec-stock.sh` | BLS / grub.cfg / newest-vmlinuz resolve, then `kexec -l` / `kexec -e` |
| `deploy.c` | Trailer parse, install, self-wipe |
| `efi-nvram.c` / `efi-nvram.h` | NVRAM dump and Boot0002 create |
| `gen-deploy-magic.sh` | Writes `deploy-magic.h` from `SOURCE_DATE_EPOCH` |
| `append-deploy-trailer.sh` | `[ELF][MAGIC][u64 le size][BOOTX64][MAGIC][u64 le size][uki]` |

## The bootkit GRUB PE

`mk-bootx64-efi.sh` requires AL2023 because it reads `/usr/lib/grub/x86_64-efi` (`kernel.img`, `moddep.lst`, `*.mod` from `grub2-efi-x64-modules`) and runs `grub2-mkimage`. The image is not the stock Amazon Linux GRUB PE on the ESP. Packaged GRUB stays clean under `rpm -V $(rpm -qa 'grub*')`.

Requested modules: `part_gpt`, `xfs`, `search`, `search_fs_file`, `probe`, `chain`, `boot`, `echo`, `reboot`, `gzio`. Dependencies are closed from `moddep.lst`. Each `.mod` is stripped the way GRUB `genmod.sh` does (`grub_mod_init` / `grub_mod_fini` kept).

Early config (placeholder expanded to `/var/lib/systemd/boot/uki.efi`):

```text
search.file /var/lib/systemd/boot/uki.efi root
set no_modules=y
probe --set=rootuuid --fs-uuid $root
chainloader /var/lib/systemd/boot/uki.efi ro console=tty0 console=ttyS0,115200n8 BOOTKIT_MARKER=1 root=UUID=$rootuuid
boot
```

`search.file` sets `$root` to the first device that contains the UKI. `probe` reads that filesystem's UUID at boot. The UUID is not baked into the PE. `chainloader` passes the portable extras plus `root=UUID=...` as EFI LoadOptions. The AL2023 systemd stub applies those LoadOptions as the effective kernel cmdline.

`grub2-mkimage -p /EFI/BOOT` embeds `$prefix`. On the happy path the early config ends in `boot` and GRUB never opens `$prefix/grub.cfg`. If early config failed or returned, normal mode would open `/EFI/BOOT/grub.cfg`. That is not the intended path.

The leading dot on `.BOOTX64.EFI` hides the file from a bare `ls` on the ESP. `ls -a` and any real tooling still see it. Prefer a VFAT path that is not next to `BOOTX64.EFI` and not a well-known name if you change it, and keep the lockstep constants below aligned.

## The UKI

`mk-uki.sh` packs kernel + bootkit initrd + a NUL-terminated PE `.cmdline` onto `/usr/lib/systemd/boot/efi/linuxx64.efi.stub` (fallback `/lib/systemd/boot/efi/linuxx64.efi.stub`) with `objcopy` section flags `contents,alloc,load,readonly,data` at the systemd ~252 / ukify VMAs (`.osrel` `0x20000`, `.cmdline` `0x30000`, `.linux` `0x2000000`, `.initrd` `0x3000000`). Nothing requires systemd-boot as the boot manager. `/var/lib/systemd/boot/uki.efi` is the install path `search.file` looks for.

Portable `.cmdline` (no `root=`):

```text
ro console=tty0 console=ttyS0,115200n8 BOOTKIT_MARKER=1
```

`root=UUID=...` comes from GRUB LoadOptions at chainload time. `BOOTKIT_MARKER=1` is a stage-1-only token. Replace the string in both `mk-uki.sh` and `mk-bootx64-efi.sh` if you adapt the tree. Stage 2 strips it.

`--method dracut` exists for experiments. `dracut --uefi` does not reliably set `.cmdline`, so that path dumps `.linux` / `.initrd` and repacks. Default `auto` is the `objcopy` pack. The build fails if `grep -aF BOOTKIT_MARKER=1` does not hit the PE.

The UKI path can be any root-filesystem path if `search.file` and `deploy.c` stay in lockstep. It is kept off the tiny ESP.

## Bootkit initrd

`Makefile` unpacks the stock `/boot/initramfs-$(uname -r).img` with `initrd-packer.sh unpack`, inserts the two hooks under `var/lib/dracut/hooks/pre-pivot/`, runs the three inject scripts and `initrd-prune.sh`, then packs. AL2023 dracut layout is early newc microcode, 512-byte pad, zstd main. Pack is deterministic for a given tree plus `SOURCE_DATE_EPOCH`: sorted `find`, clamped mtimes, cpio owner `0:0`, zstd `-T1`.

`inject-kexec.sh` copies the host `kexec` binary and any `ldd` NEEDED objects that the unpacked tree does not already have, so stock dracut libc/ld stay preferred.

`inject-udhcpc.sh` and `inject-wget.sh` copy the pinned static musl applets. `98-payload.sh` looks for `/usr/sbin/udhcpc`, `/usr/share/udhcpc/default.script`, and `/usr/bin/wget`. `ip(8)` is not shipped in the slim initrd. The hook invokes real-root `/sysroot/usr/sbin/ip` via the initrd `ld-linux` and `--library-path` pointing at `/sysroot`.

`initrd-prune.sh` deletes a short list of unused CLIs (`vi`, `less`, `journalctl`, `ps`, `dmesg`, and a few others). It must not remove `sh`, `mount`, kmod tools, `kexec`, `udhcpc`, `wget`, or filesystem modules.

Dracut *sources* pre-pivot hooks. `98-payload.sh` and `99-kexec-stock.sh` must `return`, never `exit`, or later hooks including kexec are skipped. Both run with `set +e`.

## Stage-1 payload

`98-payload.sh` remounts `/sysroot` read-write, appends `/proc/cmdline` and a banner to `/sysroot/root/HELLO.TXT`, then attempts network inside a 5 second budget. Network failure never blocks boot or kexec.

Network path: bind `/sysroot/lib/modules` and `modprobe ena` (then `virtio_net` / `xen_netfront`), bring non-`lo` ifaces up, run injected `udhcpc` (`-f -n -q -t 3 -T 1 -A 0`), apply the lease with `run_ip`, then `wget -q -T 5 -O - http://ifconfig.me/ip`. Busybox wget reads initrd `/etc/resolv.conf` (copied from `/sysroot` if needed). The GET is an example endpoint; the body proves outbound reachability before stock userspace.

Pre-OS NIC, DHCP, and HTTP run before auditd, eBPF host sensors, and other agents that load with userspace. The same traffic is visible on the network: VPC Flow Logs, DNS query logs (this tree resolves `ifconfig.me`), cloud or firewall connection logs, NIDS or a proxy on the path, and local-link DHCP.

If the build-host `uname -r` does not match a module tree on the target, `modprobe ena` can fail. Stage-1 network is best-effort. Stage 2 does not depend on it.

## Stage-2 target resolution

`99-kexec-stock.sh` runs only when `BOOTKIT_MARKER=1` is on `/proc/cmdline`. It resolves the stock target the way AL2023 GRUB does after `dnf` (`GRUB_ENABLE_BLSCFG=true`):

1. `/sysroot/boot/grub2/grubenv` `saved_entry` to the matching `/sysroot/boot/loader/entries/*.conf`
2. else the highest-`version` non-rescue BLS entry
3. else the first non-rescue `linux` / `initrd` pair in `/sysroot/boot/grub2/grub.cfg`
4. else the newest `/sysroot/boot/vmlinuz-*` with a matching `initramfs-*.img`

On AL2023, `grub.cfg` usually only loads `blscfg`. Per-kernel config lives under `/boot/loader/entries/`. When BLS provides `options`, that string is the stage-2 cmdline (`quiet`, `selinux=...`, and the rest) after `$variables` and `BOOTKIT_MARKER=1` are stripped and `root=` is ensured. Otherwise stage-1 cmdline is reused with the marker stripped.

Every failure logs and `return`s 0 so dracut can still pivot into the UKI kernel. The hook never kexecs the research UKI PE.

## deploy

`deploy` is a self-extracting ELF. After the ELF image it carries the bootkit GRUB PE and the UKI:

```text
[ELF][MAGIC 16][u64 le size][BOOTX64.EFI][MAGIC 16][u64 le size][uki.efi]
```

Magic is the first 16 bytes of SHA-256 over `grub2-bootkit-deploy-v1` || NUL || `SOURCE_DATE_EPOCH` (ASCII). The same bytes exist in `.rodata` (`deploy_magic` in `deploy-magic.h`). The parser probes every match and accepts only a complete pair of AMD64 PEs (`MZ`, `PE\0\0`, machine `0x8664`) that end at EOF. Max payload per blob is 512 MiB.

Default (no `-y`): map `/proc/self/exe`, parse the trailer, print magic and offsets, dump NVRAM. No file or firmware writes.

`-y` as root:

1. Preflight: UID 0; trailer magics and sizes; x86-64 PE headers; NVRAM readable
2. Print trailer magic and offsets
3. Dump NVRAM (before)
4. Install the UKI and `.BOOTX64.EFI` via `dest.new` + `rename` + `fsync`; print size, mode, owner:group
5. Create Boot0002 and put it first on BootOrder (idempotent; keeps EC2 Boot0001 as fallback)
6. Dump NVRAM (after)
7. On full success only, schedule wipe and unlink of this executable after exit

Install modes: UKI directory and file `root:root` `0500`; ESP PE `root:root` with best-effort `0700` (VFAT may ignore mode and owner).

### NVRAM create

`efi_nvram_create()` in `efi-nvram.c` is EC2-gated. It reads Boot0001 and requires the description to start with `UEFI Amazon Elastic Block Store` and the device path to start with `HD(` or `PciRoot(0x0)/Pci`. Remove `check_ec2_boot0001()` (and its caller) to allow create on non-EC2 UEFI. ESP discovery via `/boot/efi` + `/proc/self/mountinfo` + sysfs is generic and should stay.

ESP resolve: scan mountinfo for a real filesystem on `/boot/efi` (skip `autofs` stubs), map maj:min through `/sys/dev/block`, or fall back to a `/dev/` source. If only the systemd automount stub is present, `stat("/boot/efi")` forces the vfat mount and the scan runs again. Whole-disk name and GPT partition number come from `/sys/class/block/<part>/partition` and the parent of that sysfs node (for example `/dev/nvme0n1p128` becomes disk `/dev/nvme0n1`, part `128`).

The new load option is slot `0x0002`, label copied from Boot0001, path `\EFI\BOOT\.BOOTX64.EFI`, `EFIBOOT_ABBREV_HD`. If Boot0002 already has that label and that device path, create is a no-op. Otherwise the variable is written and Boot0002 is prepended on BootOrder (duplicates of `0x0002` dropped). Boot0001 is left in the list as firmware fallback.

### Self-wipe

Linux returns `ETXTBSY` if any process still has `deploy` mapped as its text image, including a child of `deploy`. The wipe helper therefore double-forks and `exec`s `/bin/sh`. The shell waits until the original PID is gone (`kill -0`), then `dd`s `/dev/urandom` over the path, truncates, and unlinks. Path, PID, and size travel in `P_WIPE_*` environment variables so the `-c` script does not embed those strings. The wipe is best-effort. It is not a secure erase on SSD or NVMe. Dump mode does not wipe. A failed `-y` does not wipe.

## Lockstep constants

Changing one of these without the others breaks boot or install.

| Fact | Where it is written |
|------|---------------------|
| UKI install path `/var/lib/systemd/boot/uki.efi` | `deploy.c` `DEPLOY_UKI*`; `mk-bootx64-efi.sh` `UKI_PATH` (embedded `search.file`) |
| ESP PE name `.BOOTX64.EFI` / `\EFI\BOOT\.BOOTX64.EFI` | `deploy.c` `ESP_LOADER_NAME`; `efi-nvram.c` `NEW_LOADER_PATH` |
| `BOOTKIT_MARKER=1` | `mk-uki.sh` `LINUX_CMDLINE`; `mk-bootx64-efi.sh` `UKI_CMDLINE_EXTRA`; `99-kexec-stock.sh` (gate + strip) |
| Trailer magic domain `grub2-bootkit-deploy-v1` | `gen-deploy-magic.sh` `DOMAIN`; must match the bytes compiled into `deploy` |
| `SOURCE_DATE_EPOCH` | `Makefile` export; `gen-deploy-magic.sh`; `initrd-packer.sh` mtimes |
| udhcpc / wget initrd paths | `inject-udhcpc.sh` / `inject-wget.sh` destinations; `98-payload.sh` lookups |
| Hook directory `var/lib/dracut/hooks/pre-pivot` | `Makefile` `HOOK_DIR_REL`; hook filenames `98-` then `99-` |
| PE machine `0x8664` | `deploy.c` `IMAGE_FILE_MACHINE_AMD64` (both trailer blobs) |
| Busybox pin 1.35.0 musl + SHA-256 | `install-dependencies.sh`; host filenames `busybox_UDHCPC` / `busybox_WGET` |

Dracut hook contract: `return`, never `exit`. Do not replace stock `\EFI\BOOT\BOOTX64.EFI`. Do not write a userspace service for persistence.

## Limits

The tree gates on Amazon Linux 2023 and an EC2-shaped Boot0001. Embedded PE checks require AMD64. ARM64 / Graviton is not supported. The same chain can be adapted to bare metal or other distros (firmware and ESP paths, initrd tooling, NIC driver, package manager and bootloader policy, and dropping the EC2-only NVRAM checks). That work is not in this tree.

Secure Boot is out of scope. Images are unsigned.

The shipped payload is the chain check in `98-payload.sh` only.

Stage-1 kernel and initrd are frozen inside the UKI. After `dnf update kernel` they go stale until you rebuild and redeploy. Stage 2 follows stock GRUB/BLS without a UKI rebuild.

The UKI and ESP PE remain visible to a full disk walk. Filtering directory listings or `open` from a loadable kernel module is out of scope.

Developed and exercised on `c5a.xlarge` and `t3.nano`.

Not in this tree:

- ARM64: `IMAGE_FILE_MACHINE_ARM64` (`0xAA64`) PE checks; AL2023 aarch64 GRUB PE and UKI; ESP paths and EC2 Boot0001 on ARM; build-host architecture matrix. Trailer layout can stay.
- Bind `deploy` (or its trailer) to the target EC2 instance ID via IMDSv2 so it only unpacks on that host. KDF and cipher are not chosen yet.
- Ship a `.so` loadable with Python `ctypes.CDLL` (or equivalent), so install can run from an in-process loader without writing `./deploy` to disk.

## See also

- README.md: operator surface
- AGENTS.md: build host versus target
