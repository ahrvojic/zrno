//! Handoff from the UEFI loader to the kernel.
//! The loader passes a higher-half pointer to `BootInfo` in `rdi`.

const std = @import("std");

/// "zrnoBOOT" little-endian. Kernel rejects anything else.
pub const magic: u64 = 0x544f4f426f6e727a;

/// One PML4 slot (index 256) covers the first 512 GiB of physical memory.
pub const hhdm_offset: u64 = 0xffff800000000000;

/// Link address. Matches `code_model = .kernel` and `kernel/linker.ld`.
pub const kernel_virt: u64 = 0xffffffff80000000;

pub const page_size: u64 = 4096;

/// Cap shared by the loader and the kernel BSS copy.
pub const max_entries: usize = 512;

pub const MemKind = enum(u32) {
    usable,
    /// Loader image, stack, page tables, and the info struct. Freed on the
    /// first thread switch, after the kernel has copied what it needs.
    reclaim,
    acpi_reclaimable,
    framebuffer,
    /// Kernel image and initramfs. Reserved for the life of the boot.
    /// Initramfs bytes are aliased by the filesystem, not copied.
    modules,
    reserved,
    bad,

    /// Regions the kernel maps into the higher half before it touches them.
    pub fn inHhdm(self: MemKind) bool {
        return switch (self) {
            .usable, .reclaim, .acpi_reclaimable, .framebuffer, .modules => true,
            .reserved, .bad => false,
        };
    }
};

pub const MemEntry = extern struct {
    base: u64,
    length: u64,
    kind: MemKind,
};

pub const BootInfo = extern struct {
    magic: u64,
    /// Higher-half pointer. Entries are not required to outlive `boot.init`.
    mmap: [*]const MemEntry,
    mmap_count: u64,
    /// Physical address corresponding to `kernel_virt`.
    kernel_phys: u64,
    rsdp_phys: u64,
    initramfs_phys: u64,
    initramfs_len: u64,
    /// Zero when firmware did not expose a linear framebuffer.
    fb_phys: u64,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u16,
    _pad: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(MemEntry) == 24);
    std.debug.assert(@alignOf(BootInfo) == 8);
    std.debug.assert(hhdm_offset & 0xfff == 0);
    std.debug.assert(kernel_virt == 0xffffffff80000000);
}
