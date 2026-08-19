const limine = @import("limine");

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

const Info = struct {
    bootloader_info: *limine.BootloaderInfoResponse,
    framebuffers: *limine.FramebufferResponse,
    higher_half: *limine.HhdmResponse,
    kernel: *limine.ExecutableAddressResponse,
    memory_map: *limine.MemoryMapResponse,
    rsdp: *limine.RsdpResponse,
};

const State = enum { uninit, live, dropped };

var info_value: Info = undefined;
var state: State = .uninit;

pub fn info() *const Info {
    return switch (state) {
        .live => &info_value,
        .uninit => panic("boot used before init"),
        .dropped => panic("boot info used after drop"),
    };
}

pub fn init() !void {
    if (state != .uninit) panic("boot already initialized");

    if (!base_revision.isSupported()) {
        panic("Limine base revision not supported!");
    }

    info_value = .{
        .bootloader_info = bootloader_req.response orelse return error.NoBootloaderInfo,
        .framebuffers = fb_req.response orelse return error.NoFramebuffer,
        .higher_half = hhdm_req.response orelse return error.NoHhdm,
        .kernel = kaddr_req.response orelse return error.NoKernelAddress,
        .memory_map = mm_req.response orelse return error.NoMemoryMap,
        .rsdp = rsdp_req.response orelse return error.NoRsdp,
    };
    virt.init(info_value.higher_half.offset);
    state = .live;
}

/// Limine responses (and the boot stack) live in bootloader-reclaimable
/// memory. After this, `info()` panics; callers must have copied what
/// they still need.
pub fn drop() void {
    if (state != .live) panic("boot drop without init");
    info_value = undefined;
    state = .dropped;
}
