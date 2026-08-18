# Makefile — build products only (no install/deploy).
#
# Targets:
#   make / make all   uki.efi, BOOTX64.EFI, deploy (+ cppcheck)
#   make uki.efi      UKI only (bootkit initrd + mk-uki.sh)
#   make BOOTX64.EFI  GRUB PE only (mk-bootx64-efi.sh)
#   make deploy       self-extracting binary (dump by default; -y installs)
#   make clean        remove products and intermediate initrd
#
# Does not install to the ESP, /var/lib/systemd/boot, or NVRAM
# (see ./deploy / ./deploy -y on the target).
# Run on Amazon Linux 2023 with dependencies from install-dependencies.sh.
#
# Reproducibility (deploy magic + bootkit initrd pack):
#   SOURCE_DATE_EPOCH defaults to latest git commit time, else 0.
#   Override: make SOURCE_DATE_EPOCH=1700000000
#
# Secure Boot is out of scope: stock EC2 boots with Secure Boot off.
# Architecture: x86_64 only for now (see ARCHITECTURE.md for ARM64).

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Fixed PATH like the build scripts (no accidental host-tool leakage).
export PATH := /usr/sbin:/usr/bin:/sbin:/bin

REPO_ROOT := $(abspath .)

UKI        := uki.efi
BOOTX64    := BOOTX64.EFI
DEPLOY     := deploy
DEPLOY_BARE := deploy.bare
PAYLOAD    := 98-payload.sh
KEXEC_HOOK := 99-kexec-stock.sh
INJECT_KEXEC := inject-kexec.sh
INJECT_UDHCPC := inject-udhcpc.sh
INJECT_WGET := inject-wget.sh
PRUNE_INITRD := initrd-prune.sh
UDHCPC_BIN := busybox_UDHCPC
WGET_BIN   := busybox_WGET
PACKER     := initrd-packer.sh
MK_UKI     := mk-uki.sh
MK_BOOTX64 := mk-bootx64-efi.sh
GEN_MAGIC  := gen-deploy-magic.sh
APPEND_TR  := append-deploy-trailer.sh
MAGIC_H    := deploy-magic.h

DEPLOY_SRCS := deploy.c efi-nvram.c

# Stock initrd for the running kernel; pre-pivot hooks + kexec under main/.
KVER          := $(shell uname -r)
SRC_INITRD    := /boot/initramfs-$(KVER).img
BOOTKIT_INITRD := initramfs-$(KVER).insert.img
HOOK_DIR_REL  := var/lib/dracut/hooks/pre-pivot
PAYLOAD_REL   := $(HOOK_DIR_REL)/98-payload.sh
KEXEC_HOOK_REL := $(HOOK_DIR_REL)/99-kexec-stock.sh

# Shared by initrd-packer (cpio mtimes) and deploy compile.
SOURCE_DATE_EPOCH ?= $(shell git -C '$(REPO_ROOT)' log -1 --pretty=%ct 2>/dev/null || echo 0)
export SOURCE_DATE_EPOCH

# efi-nvram (via deploy) link flags (efivar + efiboot).
EFIVAR_FLAGS := $(shell pkg-config --cflags --libs efivar efiboot 2>/dev/null)

# Reproducible-ish C flags:
# -g0: no DWARF absolute paths
# -f*-prefix-map: checkout path rewritten to "."
CC       ?= cc
CFLAGS   := -std=c17 -Wall -Wextra -Werror -pedantic -g0 \
	-ffile-prefix-map=$(REPO_ROOT)=. \
	-fdebug-prefix-map=$(REPO_ROOT)=.
CPPCHECK ?= cppcheck

.PHONY: all clean check lint check-cppcheck

all: $(UKI) $(BOOTX64) $(DEPLOY) check
	@echo "make: done (build only; nothing installed)"
	@echo "make:   $(UKI) ($$(stat -c '%s' -- '$(UKI)') bytes)"
	@echo "make:   $(BOOTX64) ($$(stat -c '%s' -- '$(BOOTX64)') bytes)"
	@echo "make:   $(DEPLOY) ($$(stat -c '%s' -- '$(DEPLOY)') bytes)"
	@echo "make: SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)"
	@echo "make: next: ./deploy       # dump-only (root)"
	@echo "make:       ./deploy -y    # full install (root)"

# ---------------------------------------------------------------------------
# Bootkit initrd: unpack stock image, insert hooks + kexec, re-pack
# ---------------------------------------------------------------------------

$(BOOTKIT_INITRD): $(PACKER) $(PAYLOAD) $(KEXEC_HOOK) $(INJECT_KEXEC) $(INJECT_UDHCPC) $(INJECT_WGET) $(PRUNE_INITRD) $(UDHCPC_BIN) $(WGET_BIN) $(SRC_INITRD)
	@test -x './$(PACKER)' || { echo 'make: missing $(PACKER)' >&2; exit 1; }
	@test -x './$(INJECT_KEXEC)' || { echo 'make: missing $(INJECT_KEXEC)' >&2; exit 1; }
	@test -x './$(INJECT_UDHCPC)' || { echo 'make: missing $(INJECT_UDHCPC)' >&2; exit 1; }
	@test -x './$(INJECT_WGET)' || { echo 'make: missing $(INJECT_WGET)' >&2; exit 1; }
	@test -x './$(PRUNE_INITRD)' || { echo 'make: missing $(PRUNE_INITRD)' >&2; exit 1; }
	@test -f './$(PAYLOAD)' || { echo 'make: missing $(PAYLOAD)' >&2; exit 1; }
	@test -f './$(KEXEC_HOOK)' || { echo 'make: missing $(KEXEC_HOOK)' >&2; exit 1; }
	@test -f './$(UDHCPC_BIN)' || { \
		echo 'make: missing $(UDHCPC_BIN) (run ./install-dependencies.sh)' >&2; \
		exit 1; }
	@test -f './$(WGET_BIN)' || { \
		echo 'make: missing $(WGET_BIN) (run ./install-dependencies.sh)' >&2; \
		exit 1; }
	@test -f '$(SRC_INITRD)' || { echo 'make: missing $(SRC_INITRD)' >&2; exit 1; }
	@command -v kexec >/dev/null 2>&1 || { \
		echo 'make: kexec not found (install kexec-tools / install-dependencies.sh)' >&2; \
		exit 1; }
	@echo "make: SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)"
	@echo "make: preparing initrd with $(PAYLOAD) + $(KEXEC_HOOK) + kexec + udhcpc + wget + prune"
	tmpdir="$$(mktemp -d '/tmp/make-initrd.XXXXXX')" && \
	./$(PACKER) unpack '$(SRC_INITRD)' "$$tmpdir" && \
	mkdir -p -- "$$tmpdir/main/$(HOOK_DIR_REL)" && \
	cp -f -- './$(PAYLOAD)' "$$tmpdir/main/$(PAYLOAD_REL)" && \
	cp -f -- './$(KEXEC_HOOK)' "$$tmpdir/main/$(KEXEC_HOOK_REL)" && \
	chmod 0755 -- "$$tmpdir/main/$(PAYLOAD_REL)" "$$tmpdir/main/$(KEXEC_HOOK_REL)" && \
	echo "make: inserted $(PAYLOAD_REL)" && \
	echo "make: inserted $(KEXEC_HOOK_REL)" && \
	./$(INJECT_KEXEC) "$$tmpdir/main" && \
	./$(INJECT_UDHCPC) "$$tmpdir/main" && \
	./$(INJECT_WGET) "$$tmpdir/main" && \
	./$(PRUNE_INITRD) "$$tmpdir/main" && \
	./$(PACKER) pack '$(BOOTKIT_INITRD)' "$$tmpdir" && \
	rm -rf -- "$$tmpdir" && \
	echo "make: bootkit initrd $$(stat -c '%s' -- '$(BOOTKIT_INITRD)') bytes"

# ---------------------------------------------------------------------------
# UKI: objcopy pack of vmlinuz + bootkit initrd + portable .cmdline
# ---------------------------------------------------------------------------

$(UKI): $(BOOTKIT_INITRD) $(MK_UKI)
	@test -x './$(MK_UKI)' || { echo 'make: missing $(MK_UKI)' >&2; exit 1; }
	@echo "make: building $(UKI)"
	./$(MK_UKI) --output '$(REPO_ROOT)/$(UKI)' --initrd '$(REPO_ROOT)/$(BOOTKIT_INITRD)'
	# UKI embeds the initrd; intermediate pack is no longer needed.
	rm -f -- '$(BOOTKIT_INITRD)'

# ---------------------------------------------------------------------------
# BOOTX64.EFI: grub2-mkimage early config chainloads deployed UKI path
# ---------------------------------------------------------------------------

$(BOOTX64): $(MK_BOOTX64)
	@test -x './$(MK_BOOTX64)' || { echo 'make: missing $(MK_BOOTX64)' >&2; exit 1; }
	@echo "make: building $(BOOTX64)"
	./$(MK_BOOTX64)

# ---------------------------------------------------------------------------
# deploy: bare ELF + appended BOOTX64.EFI + uki.efi
# ---------------------------------------------------------------------------

$(MAGIC_H): $(GEN_MAGIC)
	@test -x './$(GEN_MAGIC)' || { echo 'make: missing $(GEN_MAGIC)' >&2; exit 1; }
	@echo "make: generating $(MAGIC_H) (SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH))"
	SOURCE_DATE_EPOCH='$(SOURCE_DATE_EPOCH)' ./$(GEN_MAGIC) '$(MAGIC_H)'

$(DEPLOY_BARE): $(DEPLOY_SRCS) efi-nvram.h $(MAGIC_H)
	@command -v pkg-config >/dev/null || { echo 'make: pkg-config not found' >&2; exit 1; }
	@pkg-config --exists efivar efiboot || { \
		echo 'make: pkg-config missing efivar/efiboot (install-dependencies.sh)' >&2; \
		exit 1; }
	@test -n '$(EFIVAR_FLAGS)' || { echo 'make: empty EFIVAR_FLAGS' >&2; exit 1; }
	@echo "make: compiling $(DEPLOY_BARE)"
	SOURCE_DATE_EPOCH='$(SOURCE_DATE_EPOCH)' \
		$(CC) $(CFLAGS) -o '$(DEPLOY_BARE)' $(DEPLOY_SRCS) $(EFIVAR_FLAGS)

$(DEPLOY): $(DEPLOY_BARE) $(BOOTX64) $(UKI) $(APPEND_TR) $(MAGIC_H)
	@test -x './$(APPEND_TR)' || { echo 'make: missing $(APPEND_TR)' >&2; exit 1; }
	@echo "make: appending trailer -> $(DEPLOY)"
	./$(APPEND_TR) '$(DEPLOY_BARE)' '$(BOOTX64)' '$(UKI)' '$(DEPLOY)'
	rm -f -- '$(DEPLOY_BARE)'

# ---------------------------------------------------------------------------
# Static analysis
# ---------------------------------------------------------------------------

check-cppcheck:
	@command -v $(CPPCHECK) >/dev/null 2>&1 || { \
		echo 'make: cppcheck not found — install it for static analysis' \
			'(./install-dependencies.sh or dnf install cppcheck)' >&2; \
		exit 1; }
	# --library=bsd: err/errx are noreturn (avoids false doubleFree after free+err)
	$(CPPCHECK) --enable=warning,performance,portability \
		--library=bsd --error-exitcode=1 -I. \
		efi-nvram.c deploy.c

lint: check-cppcheck
check: lint

# ---------------------------------------------------------------------------

clean:
	rm -f -- $(UKI) $(BOOTX64) $(DEPLOY) $(DEPLOY_BARE) efi \
		$(MAGIC_H) initramfs-*.insert.img
	@echo "make: clean"
