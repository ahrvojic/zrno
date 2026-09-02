# Nuke built-in rules and variables.
override MAKEFLAGS += -rR

override IMAGE_NAME := zrno

# Pin the bootloader release. Limine does not guarantee protocol or config
# compatibility across versions; /releases/latest can break a working kernel.
LIMINE_VERSION := 12.6.1

# Host toolchain for building the Limine install helper.
HOST_CC := cc
HOST_CFLAGS := -g -O2 -pipe
HOST_CPPFLAGS :=
HOST_LDFLAGS :=
HOST_LIBS :=

# Convenience macro to reliably declare user overridable variables.
define DEFAULT_VAR =
    ifeq ($(origin $1),default)
        override $(1) := $(2)
    endif
    ifeq ($(origin $1),undefined)
        override $(1) := $(2)
    endif
endef

override DEFAULT_KZIGFLAGS := -Doptimize=ReleaseSafe
$(eval $(call DEFAULT_VAR,KZIGFLAGS,$(DEFAULT_KZIGFLAGS)))

QEMU := qemu-system-x86_64
QEMUFLAGS := -M q35 -m 2G -serial stdio

.PHONY: all
all: $(IMAGE_NAME).iso

.PHONY: all-hdd
all-hdd: $(IMAGE_NAME).hdd

.PHONY: run
run: $(IMAGE_NAME).iso
	$(QEMU) $(QEMUFLAGS) -cdrom $(IMAGE_NAME).iso -boot d

.PHONY: run-uefi
run-uefi: ovmf $(IMAGE_NAME).iso
	$(QEMU) $(QEMUFLAGS) -bios ovmf/OVMF.fd -cdrom $(IMAGE_NAME).iso -boot d

.PHONY: run-hdd
run-hdd: $(IMAGE_NAME).hdd
	$(QEMU) $(QEMUFLAGS) -hda $(IMAGE_NAME).hdd

.PHONY: run-hdd-uefi
run-hdd-uefi: ovmf $(IMAGE_NAME).hdd
	$(QEMU) $(QEMUFLAGS) -bios ovmf/OVMF.fd -hda $(IMAGE_NAME).hdd

ovmf:
	mkdir -p ovmf
	cd ovmf && curl -Lo OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd

limine/limine:
	rm -rf limine limine-binary
	curl -L https://github.com/Limine-Bootloader/Limine/releases/download/v$(LIMINE_VERSION)/limine-binary.tar.gz | tar -xz
	mv limine-binary limine
	$(MAKE) -C limine \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS)" \
		CPPFLAGS="$(HOST_CPPFLAGS)" \
		LDFLAGS="$(HOST_LDFLAGS)" \
		LIBS="$(HOST_LIBS)"

user/%.elf: user/%.S user/user.ld
	zig build-exe $< \
		-target x86_64-freestanding-none \
		-T user/user.ld \
		-fentry=_start \
		-fno-PIE \
		-fno-compiler-rt \
		-fstrip \
		-fno-stack-protector \
		--name $* \
		-femit-bin=$@

user/initramfs.tar: user/hello.elf user/init.elf user/hello.txt
	rm -rf user/.initramfs
	mkdir user/.initramfs
	cp -f user/hello.elf user/.initramfs/hello
	cp -f user/init.elf user/.initramfs/init
	cp -f user/hello.txt user/.initramfs/hello.txt
	COPYFILE_DISABLE=1 tar --format=ustar -cf $@ -C user/.initramfs hello init hello.txt
	rm -rf user/.initramfs

.PHONY: kernel
kernel:
	cd kernel && zig build $(KZIGFLAGS)

$(IMAGE_NAME).iso: limine/limine kernel user/initramfs.tar
	rm -rf iso_root
	mkdir -p iso_root/boot
	cp -v kernel/zig-out/bin/kernel user/initramfs.tar iso_root/boot/
	mkdir -p iso_root/boot/limine
	cp -v limine.conf limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/boot/limine/
	mkdir -p iso_root/EFI/BOOT
	cp -v limine/BOOTX64.EFI iso_root/EFI/BOOT/
	cp -v limine/BOOTIA32.EFI iso_root/EFI/BOOT/
	xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
		-apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		iso_root -o $(IMAGE_NAME).iso
	./limine/limine bios-install $(IMAGE_NAME).iso
	rm -rf iso_root

$(IMAGE_NAME).hdd: limine/limine kernel user/initramfs.tar
	rm -f $(IMAGE_NAME).hdd
	dd if=/dev/zero bs=1M count=0 seek=64 of=$(IMAGE_NAME).hdd
	PATH=$$PATH:/usr/sbin:/sbin sgdisk $(IMAGE_NAME).hdd -n 1:2048 -t 1:ef00 -m 1
	./limine/limine bios-install $(IMAGE_NAME).hdd
	mformat -i $(IMAGE_NAME).hdd@@1M
	mmd -i $(IMAGE_NAME).hdd@@1M ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine
	mcopy -i $(IMAGE_NAME).hdd@@1M kernel/zig-out/bin/kernel user/initramfs.tar ::/boot
	mcopy -i $(IMAGE_NAME).hdd@@1M limine.conf limine/limine-bios.sys ::/boot/limine
	mcopy -i $(IMAGE_NAME).hdd@@1M limine/BOOTX64.EFI ::/EFI/BOOT
	mcopy -i $(IMAGE_NAME).hdd@@1M limine/BOOTIA32.EFI ::/EFI/BOOT

.PHONY: clean
clean:
	rm -rf iso_root $(IMAGE_NAME).iso $(IMAGE_NAME).hdd
	rm -rf kernel/.zig-cache kernel/zig-cache kernel/zig-out
	rm -rf user/.initramfs
	rm -f user/hello.elf user/init.elf user/initramfs.tar

.PHONY: distclean
distclean: clean
	rm -rf limine limine-binary ovmf
