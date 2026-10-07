# Nuke built-in rules and variables.
override MAKEFLAGS += -rR

ifeq ($(firstword $(subst ., ,$(MAKE_VERSION))),3)
$(error GNU Make 4+ required (found $(MAKE_VERSION)))
endif

override IMAGE_NAME := zrno

KZIGFLAGS ?= -Doptimize=safe
UZIGFLAGS ?= -Doptimize=small
BZIGFLAGS ?= -Doptimize=safe

QEMU := qemu-system-x86_64
# qemu64 does not implement XSAVE/AVX (even with +avx). Broadwell has
# SMEP, SMAP, AVX, and AVX2, which the kernel requires.
QEMUFLAGS := -M q35 -m 2G -serial stdio -cpu Broadwell

# QEMU's fat: drive is the ESP. No mtools or sgdisk: the firmware sees a
# FAT disk whose root is this directory.
ESP := esp
QEMU_DISK := -drive file=fat:rw:$(abspath $(ESP)),format=raw,media=disk
# Writable filesystem. Legacy virtio-blk: one queue, an I/O BAR.
DISK := zrno.dsk
QEMU_VIRTIO := -drive file=$(DISK),if=none,format=raw,id=vd0 -device virtio-blk-pci,drive=vd0,disable-modern=on

.PHONY: all
all: $(ESP)/EFI/BOOT/BOOTX64.EFI

$(DISK):
	truncate -s 8M $(DISK)

.PHONY: run
run: ovmf $(DISK) $(ESP)/EFI/BOOT/BOOTX64.EFI
	$(QEMU) $(QEMUFLAGS) -bios ovmf/OVMF.fd $(QEMU_DISK) $(QEMU_VIRTIO)

.PHONY: test-qemu
test-qemu: ovmf $(DISK) $(ESP)/EFI/BOOT/BOOTX64.EFI
	sh scripts/test-qemu.sh $(QEMU) -bios ovmf/OVMF.fd $(QEMU_DISK) $(QEMUFLAGS) $(QEMU_VIRTIO)

ovmf:
	mkdir -p ovmf
	cd ovmf && curl -Lo OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd

USER_PROGS := $(sort $(patsubst user/src/cmd/%.zig,%,$(wildcard user/src/cmd/*.zig)))
USER_SRCS := $(wildcard user/src/cmd/*.zig) $(wildcard user/src/lib/*.zig) \
	user/build.zig user/build.zig.zon user/user.ld

.PHONY: user
user:
	cd user && zig build $(UZIGFLAGS)

.PHONY: kernel
kernel:
	cd kernel && zig build $(KZIGFLAGS)

.PHONY: boot
boot:
	cd boot && zig build $(BZIGFLAGS)

user/initramfs.tar: $(USER_SRCS)
	cd user && zig build $(UZIGFLAGS)
	rm -rf user/.initramfs
	mkdir user/.initramfs
	for p in $(USER_PROGS); do cp -f user/zig-out/bin/$$p user/.initramfs/$$p; done
	tar --format=ustar -cf $@ -C user/.initramfs $(USER_PROGS)
	rm -rf user/.initramfs

# OVMF boots \EFI\BOOT\BOOTX64.EFI and the loader reads \boot\kernel and
# \boot\initramfs.tar from the same volume.
$(ESP)/EFI/BOOT/BOOTX64.EFI: boot kernel user/initramfs.tar
	rm -rf $(ESP)
	mkdir -p $(ESP)/EFI/BOOT $(ESP)/boot
	cp -f boot/zig-out/bin/BOOTX64.efi $(ESP)/EFI/BOOT/BOOTX64.EFI
	cp -f kernel/zig-out/bin/kernel $(ESP)/boot/kernel
	cp -f user/initramfs.tar $(ESP)/boot/initramfs.tar

.PHONY: clean
clean:
	rm -rf iso_root $(ESP) $(IMAGE_NAME).iso $(IMAGE_NAME).hdd $(DISK)
	rm -rf kernel/.zig-cache kernel/zig-cache kernel/zig-out
	rm -rf user/.zig-cache user/zig-cache user/zig-out
	rm -rf boot/.zig-cache boot/zig-cache boot/zig-out
	rm -rf user/.initramfs
	rm -f user/initramfs.tar

.PHONY: distclean
distclean: clean
	rm -rf ovmf
