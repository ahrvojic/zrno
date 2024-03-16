const limine = @import("limine");

const panic = @import("../lib/panic.zig").panic;

export var base_revision: limine.BaseRevision = .{ .revision = 1 };

export var bootloader_req: limine.BootloaderInfoRequest = .{};
export var fb_req: limine.FramebufferRequest = .{};
export var hhdm_req: limine.HhdmRequest = .{};
export var kaddr_req: limine.KernelAddressRequest = .{};
export var mm_req: limine.MemoryMapRequest = .{};
export var rsdp_req: limine.RsdpRequest = .{};

const Bootloader = struct {
    info: *limine.BootloaderInfoResponse,
    framebuffer: *limine.FramebufferResponse,
    higherHalf: *limine.HhdmResponse,
    kernel: *limine.KernelAddressResponse,
    memoryMap: *limine.MemoryMapResponse,
    rsdp: *limine.RsdpResponse,
};

var bootloader: Bootloader = undefined;

pub fn init() !void {
    if (!base_revision.is_supported()) {
        panic("Limine base revision not supported!");
    }

    bootloader = .{
        .info = bootloader_req.response.?,
        .framebuffer = fb_req.response.?,
        .higherHalf = hhdm_req.response.?,
        .kernel = kaddr_req.response.?,
        .memoryMap = mm_req.response.?,
        .rsdp = rsdp_req.response.?,
    };
}

pub fn get() *const Bootloader {
    return &bootloader;
}
