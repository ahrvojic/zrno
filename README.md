# zrno

A simple kernel that relies on the [Limine](https://limine-bootloader.org) bootloader.

Let's learn kernel dev, x86_64, and Zig all at the same time, shall we? 😅

## Kernel features

- Single-CPU for now
- GDT, IDT, exceptions, and local APIC
- ACPI tables (FADT and MADT)
- I/O APIC, PIT, PS/2 keyboard, and framebuffer TTY
- 16550 serial console (COM1)
- Bitmap physical allocator, virtual memory, and a power-of-two slab heap
- Processes, threads, and a preemptive round-robin scheduler
- Userspace with demand paging and a handful of int 0x80 syscalls
- A tiny shell

## Requirements

Host tools that need to be installed locally. Limine (and OVMF, for UEFI QEMU targets) are fetched by the makefile.

To build the ISO and run it (`make run`):

- [GNU make](https://www.gnu.org/software/make/)
- [Zig](https://ziglang.org) 0.16.0
- [QEMU](https://www.qemu.org) (`qemu-system-x86_64`)
- [xorriso](https://www.gnu.org/software/xorriso/)
- A C compiler (`cc`), used to build Limine's `bios-install` helper
- `curl` and `tar`, used to fetch Limine if it is not already present

HDD images (`make all-hdd` / `make run-hdd`) also need:

- `sgdisk` (package `gdisk` or `gptfdisk`)
- [mtools](https://www.gnu.org/software/mtools/) (`mformat`, `mmd`, `mcopy`)

`make run` attaches COM1 to the terminal (`-serial stdio`). Kernel logs and panics go there (115200 8N1).

## References

- [OSDev.org](https://wiki.osdev.org)
- [Osdev Notes](https://github.com/dreamportdev/Osdev-Notes)
- [48cf/limine-zig-template](https://github.com/48cf/limine-zig-template)
- [48cf/Lyre](https://github.com/48cf/Lyre)
- [48cf/zigux](https://github.com/48cf/zigux)
- [AndreaOrru/zen](https://github.com/AndreaOrru/zen)
- [mintsuki/flanterm](https://github.com/mintsuki/flanterm)
- [dreamos82/Dreamos64](https://github.com/dreamos82/Dreamos64)
- [ZystemOS/pluto](https://github.com/ZystemOS/pluto)
