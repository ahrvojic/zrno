//! Host test root. Each `_ = @import` includes that file's tests; unused
//! kernel decls (Limine, privileged asm, MMIO) stay unanalyzed.
test {
    _ = @import("lib/bounded_array.zig");
    _ = @import("mm/heap_core.zig");
    _ = @import("mm/vmm.zig");
    _ = @import("sys/gdt.zig");
    _ = @import("sys/idt.zig");
    _ = @import("sys/elf.zig");
    _ = @import("sys/ustar.zig");
    _ = @import("sys/ramfs.zig");
    _ = @import("acpi/acpi.zig");
    _ = @import("acpi/fadt.zig");
    _ = @import("acpi/madt.zig");
    _ = @import("dev/timer.zig");
    _ = @import("dev/hpet.zig");
    _ = @import("dev/pmtimer.zig");
    _ = @import("dev/font.zig");
}
