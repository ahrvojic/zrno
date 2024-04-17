const limine = @import("limine");

const panic = @import("../lib/panic.zig").panic;

export var base_revision: limine.BaseRevision = .{ .revision = 1 };

export var bootloader_req: limine.BootloaderInfoRequest = .{};
export var fb_req: limine.FramebufferRequest = .{};
export var hhdm_req: limine.HhdmRequest = .{};
export var kaddr_req: limine.KernelAddressRequest = .{};
export var mm_req: limine.MemoryMapRequest = .{};
export var rsdp_req: limine.RsdpRequest = .{};

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
        .bootloader_info = bootloader_req.response.?,
        .framebuffers = fb_req.response.?,
        .higher_half = hhdm_req.response.?,
        .kernel = kaddr_req.response.?,
        .memory_map = mm_req.response.?,
        .rsdp = rsdp_req.response.?,
    };
}
