const logger = std.log.scoped(.boot);

const std = @import("std");

const bootinfo = @import("bootinfo");

const vfs = @import("../fs/vfs.zig");
const panic = @import("../lib/panic.zig").panic;
const virt = @import("../lib/virt.zig");

const MemEntry = bootinfo.MemEntry;

const Framebuffer = struct {
    phys: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u16,
};

const Info = struct {
    mmap: []const MemEntry,
    kernel_phys: u64,
    rsdp_phys: u64,
    fb: ?Framebuffer,
};

const State = enum { uninit, live, dropped };

var mmap_store: [bootinfo.max_entries]MemEntry = undefined;
var info_value: Info = undefined;
var state: State = .uninit;

pub fn info() *const Info {
    return switch (state) {
        .live => &info_value,
        .uninit => panic("boot used before init"),
        .dropped => panic("boot info used after drop"),
    };
}

pub fn init(raw: *const bootinfo.BootInfo) !void {
    if (state != .uninit) panic("boot already initialized");
    if (raw.magic != bootinfo.magic) return error.BadBootInfo;
    if (raw.kernel_phys == 0 or raw.rsdp_phys == 0) return error.BadBootInfo;
    if (raw.mmap_count == 0 or raw.mmap_count > bootinfo.max_entries) return error.BadBootInfo;

    const n: usize = @intCast(raw.mmap_count);
    @memcpy(mmap_store[0..n], raw.mmap[0..n]);

    virt.init(bootinfo.hhdm_offset);
    info_value = .{
        .mmap = mmap_store[0..n],
        .kernel_phys = raw.kernel_phys,
        .rsdp_phys = raw.rsdp_phys,
        .fb = if (raw.fb_phys == 0) null else .{
            .phys = raw.fb_phys,
            .width = raw.fb_width,
            .height = raw.fb_height,
            .pitch = raw.fb_pitch,
            .bpp = raw.fb_bpp,
        },
    };
    state = .live;

    logger.info("hhdm=0x{x} kernel phys=0x{x} virt=0x{x} rsdp=0x{x} mmap={d}", .{
        bootinfo.hhdm_offset,
        raw.kernel_phys,
        bootinfo.kernel_virt,
        raw.rsdp_phys,
        n,
    });

    if (raw.initramfs_len == 0) return error.NoInitramfs;
    const archive = virt.toHH([*]const u8, @intCast(raw.initramfs_phys))[0..@intCast(raw.initramfs_len)];
    logger.info("initramfs {d} bytes at 0x{x}", .{ archive.len, @intFromPtr(archive.ptr) });
    vfs.mount(archive) catch |err| {
        logger.err("initramfs: {s}", .{@errorName(err)});
        return err;
    };
    var i: usize = 0;
    while (vfs.root().childAt(i)) |entry| : (i += 1) {
        logger.info("initramfs {s} {d} bytes", .{ entry.name(), entry.size() });
    }
}

/// Boot info lives in reclaimable memory and in this BSS copy. After this,
/// `info()` panics. The filesystem aliases the initramfs bytes, which stay mapped.
pub fn drop() void {
    if (state != .live) panic("boot drop without init");
    info_value = undefined;
    state = .dropped;
}
