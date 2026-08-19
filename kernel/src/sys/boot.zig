const limine = @import("limine");

const panic = @import("../lib/panic.zig").panic;

const RequestsStartMarker = extern struct {
    marker: [4]u64 = .{
        0xf6b8f4b39de7d1ae,
        0xfab91a6940fcb9cf,
        0x785c6ed015d3e316,
        0x181e920a7852b9d9,
    },
};

const RequestsEndMarker = extern struct {
    marker: [2]u64 = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

export var start_marker: RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .{ .revision = 1 };

export var bootloader_req: limine.BootloaderInfoRequest linksection(".limine_requests") = .{};
export var fb_req: limine.FramebufferRequest linksection(".limine_requests") = .{};
export var hhdm_req: limine.HhdmRequest linksection(".limine_requests") = .{};
export var kaddr_req: limine.KernelAddressRequest linksection(".limine_requests") = .{};
export var mm_req: limine.MemoryMapRequest linksection(".limine_requests") = .{};
export var rsdp_req: limine.RsdpRequest linksection(".limine_requests") = .{};

const Info = struct {
    bootloader_info: *limine.BootloaderInfoResponse,
    framebuffers: *limine.FramebufferResponse,
    higher_half: *limine.HhdmResponse,
    kernel: *limine.KernelAddressResponse,
    memory_map: *limine.MemoryMapResponse,
    rsdp: *limine.RsdpResponse,
};

pub var info: Info = undefined;

pub fn init() !void {
    if (!base_revision.is_supported()) {
        panic("Limine base revision not supported!");
    }

    info = .{
        .bootloader_info = bootloader_req.response orelse return error.NoBootloaderInfo,
        .framebuffers = fb_req.response orelse return error.NoFramebuffer,
        .higher_half = hhdm_req.response orelse return error.NoHhdm,
        .kernel = kaddr_req.response orelse return error.NoKernelAddress,
        .memory_map = mm_req.response orelse return error.NoMemoryMap,
        .rsdp = rsdp_req.response orelse return error.NoRsdp,
    };
}
