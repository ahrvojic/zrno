# Boot

A UEFI application in `boot/` reads the kernel and the initramfs off the boot volume, builds page tables, and jumps to the kernel's link address. The kernel then brings its own subsystems up and spawns `/init`. Later chapters start at a step in that sequence.

## The loader

`boot/src/main.zig` is an ordinary UEFI app. It opens the volume it was loaded from and reads `boot/kernel` and `boot/initramfs.tar` from that volume. It finds the ACPI RSDP in the configuration tables, and the graphics protocol's framebuffer when the firmware has one. Serial output is COM1, so a few firmware lines appear before `zrno boot`.

The kernel ELF is parsed, allocated as loader data, and copied in. Its entry point and physical address are kept. The initramfs stays where the read left it. The loader also allocates a 16-page stack, a `BootInfo` plus a memory-map copy, and a pool of page-table pages.

Firmware has already entered long mode and identity-mapped the loader. The tables in `boot/src/paging.zig` only have to stay valid until the kernel installs its own. RAM is identity-mapped, and mapped a second time in the higher half, both with 2 MiB pages, up to 512 GiB. The kernel image is mapped with 4 KiB pages at its link address, `0xffffffff80000000`, writable for the moment. The kernel replaces that with the real permissions.

With the map and the tables ready, the loader calls `ExitBootServices`. That call can fail because the map key went stale, so the loader rebuilds the map and retries. After it succeeds there is no allocation and no console protocol. A small trampoline loads the new CR3, points `rsp` at the higher-half stack, and jumps to the ELF entry with a higher-half pointer to `BootInfo` in `rdi`.

## What the kernel is given

`common/bootinfo.zig` is the whole contract. The magic is `zrnoBOOT`. The struct carries the memory map, the kernel's physical address, the RSDP, the initramfs, and the framebuffer geometry. A zero framebuffer address means there is no linear frame buffer.

Every physical address the kernel will touch is also mapped at `0xffff800000000000` plus that address. That is one PML4 slot, index 256, and it covers the first 512 GiB. The kernel keeps the physical address of a frame and adds this offset to reach its bytes.

The link address sits at the bottom of the top 2 GiB. The kernel is built with the small code model, which uses signed 32-bit displacements, so the whole image has to stay inside that window. `kernel/linker.ld` places text, read-only data, and writable data in three program headers. Those headers are the permissions the kernel's own page tables install.

The memory map tags each range. Usable RAM can be allocated. Loader pages are reclaimable and are freed once the kernel has copied what it needs. The kernel image and the initramfs are reserved for the life of the boot. The initramfs stays where it was read, and the filesystem uses those bytes directly. ACPI memory and the framebuffer are mapped and kept. Reserved and bad ranges are left alone.

## `main`

`_start` in `kernel/src/main.zig` calls `main` and then yields. The yield never returns. The boot stack is not a thread, and the first real schedule leaves it behind.

`main` runs with interrupts off, in this order:

1. Serial. Port I/O only, so a panic during the rest of boot can print.
2. CPUID, so the log can name the processor. The TSC frequency is recorded here when the leaf exists. [The CPU](cpu.md) covers the fallback measurement.
3. `boot.init` copies the memory map into kernel BSS (at most 512 entries), records the higher-half offset, and mounts the initramfs. Mounting happens before the heap exists. See [Files](files.md).
4. `cpu.init` loads a GDT, an IDT, and the syscall MSRs, and turns on the protections. See [The CPU](cpu.md).
5. The physical allocator, then the kernel page tables. The new tables map RAM into the higher half with 4 KiB pages, and map the kernel image with the linker permissions. Loading CR3 replaces the loader's 2 MiB pages. See [Memory](memory.md).
6. The heap.
7. `/tmp`. A virtio block device is mounted when the PCI scan finds one. Otherwise `/tmp` is a RAM image.
8. ACPI. The RSDP from the loader leads to the tables that name the CPUs, the interrupt controllers, and the timers.
9. The framebuffer fields are saved, and the boot-info copy is discarded. The initramfs bytes stay mapped.
10. The local APIC, the I/O APIC, and the screen.
11. The scheduler, then the timer. The timer unmasks its periodic interrupt, so the scheduler has to exist first.
12. The keyboard, when the firmware reports an 8042.
13. The kernel lock, then the other processors. They spin until told the scheduler is live. See [Several CPUs](smp.md).
14. `/init` is spawned, and it has to be pid 1. If pid 1 exits, the kernel panics.

`smp.live` runs after that spawn. `_start` then yields onto the first ready thread. The first schedule that has a current thread frees the loader's reclaimable pages, including the boot stack.

## Where to read

- `boot/src/main.zig`, `boot/src/paging.zig`, `boot/src/elf.zig`
- `common/bootinfo.zig`
- `kernel/linker.ld`
- `kernel/src/main.zig`, `kernel/src/sys/boot.zig`
