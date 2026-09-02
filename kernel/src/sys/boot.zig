const logger = std.log.scoped(.boot);

const std = @import("std");

const limine = @import("limine");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const ramfs = @import("ramfs.zig");
const panic = @import("../lib/panic.zig").panic;
const virt = @import("../lib/virt.zig");

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .{ .revision = 6 };

export var bootloader_req: limine.BootloaderInfoRequest linksection(".limine_requests") = .{};
export var fb_req: limine.FramebufferRequest linksection(".limine_requests") = .{};
export var hhdm_req: limine.HhdmRequest linksection(".limine_requests") = .{};
export var kaddr_req: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};
export var mm_req: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var rsdp_req: limine.RsdpRequest linksection(".limine_requests") = .{};
export var module_req: limine.ModuleRequest linksection(".limine_requests") = .{};

const Info = struct {
    bootloader_info: *limine.BootloaderInfoResponse,
    framebuffers: ?*limine.FramebufferResponse,
    higher_half: *limine.HhdmResponse,
    kernel: *limine.ExecutableAddressResponse,
    memory_map: *limine.MemoryMapResponse,
    rsdp: *limine.RsdpResponse,
};

const State = enum { uninit, live, dropped };

var info_value: Info = undefined;
var state: State = .uninit;

const max_modules = 8;
const max_cmdline = 128;

/// Survives `drop()`. File bytes live in `executable_and_modules` (HHDM);
/// only the Limine `File` structs themselves are reclaimable.
pub const Module = struct {
    cmdline: [max_cmdline]u8 = undefined,
    cmdline_len: usize = 0,
    /// HHDM address of the file bytes.
    address: usize,
    length: usize,

    pub fn cmdlineSlice(self: *const Module) []const u8 {
        return self.cmdline[0..self.cmdline_len];
    }

    pub fn bytes(self: *const Module) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.address);
        return ptr[0..self.length];
    }
};

var modules_value: BoundedArray(Module, max_modules) = .{};

pub fn info() *const Info {
    return switch (state) {
        .live => &info_value,
        .uninit => panic("boot used before init"),
        .dropped => panic("boot info used after drop"),
    };
}

pub fn modules() []const Module {
    return switch (state) {
        .live, .dropped => modules_value.constSlice(),
        .uninit => panic("boot used before init"),
    };
}

pub fn init() !void {
    if (state != .uninit) panic("boot already initialized");

    if (!base_revision.isSupported()) {
        panic("Limine base revision not supported!");
    }

    info_value = .{
        .bootloader_info = bootloader_req.response orelse return error.NoBootloaderInfo,
        .framebuffers = fb_req.response,
        .higher_half = hhdm_req.response orelse return error.NoHhdm,
        .kernel = kaddr_req.response orelse return error.NoKernelAddress,
        .memory_map = mm_req.response orelse return error.NoMemoryMap,
        .rsdp = rsdp_req.response orelse return error.NoRsdp,
    };
    virt.init(info_value.higher_half.offset);
    state = .live;

    const name = std.mem.span(info_value.bootloader_info.name);
    const version = std.mem.span(info_value.bootloader_info.version);
    logger.info("{s} {s} hhdm=0x{x} kernel phys=0x{x} virt=0x{x}", .{
        name,
        version,
        info_value.higher_half.offset,
        info_value.kernel.physical_base,
        info_value.kernel.virtual_base,
    });
    captureModules();
    mountInitramfs();
}

fn captureModules() void {
    const resp = module_req.response orelse {
        logger.info("no modules", .{});
        return;
    };
    for (resp.modules()) |file| {
        const str = std.mem.span(file.string);
        const path = std.mem.span(file.path);
        var m: Module = .{
            .address = @intFromPtr(file.address),
            .length = @intCast(file.size),
        };
        const n = @min(str.len, max_cmdline);
        @memcpy(m.cmdline[0..n], str[0..n]);
        m.cmdline_len = n;
        modules_value.append(m) catch {
            logger.warn("module {s} skipped; cap {d}", .{ path, max_modules });
            break;
        };
        logger.info("module {s} cmdline={s} {d} bytes at 0x{x}", .{
            path,
            m.cmdlineSlice(),
            m.length,
            m.address,
        });
    }
}

fn mountInitramfs() void {
    for (modules()) |m| {
        if (!std.mem.eql(u8, m.cmdlineSlice(), "initramfs")) continue;
        ramfs.mount(m.bytes()) catch |err| {
            logger.warn("initramfs: {s}", .{@errorName(err)});
            return;
        };
        for (ramfs.entries()) |e| {
            logger.info("initramfs {s} {d} bytes", .{ e.name(), e.data.len });
        }
        return;
    }
}

/// Limine responses (and the boot stack) live in bootloader-reclaimable
/// memory. After this, `info()` panics; `modules()` remains valid.
pub fn drop() void {
    if (state != .live) panic("boot drop without init");
    info_value = undefined;
    state = .dropped;
}
