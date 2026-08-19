const limine = @import("limine");

const panic = @import("../lib/panic.zig").panic;

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

var info_value: Info = undefined;
var initialized = false;

pub fn info() *const Info {
    if (!initialized) panic("boot used before init");
    return &info_value;
}

pub fn init() !void {
    if (initialized) panic("boot already initialized");

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
    initialized = true;
}
