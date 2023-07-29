const std = @import("std");
const limine = @import("limine");

const cpu = @import("arch/x86_64/cpu.zig");
const debug = @import("arch/x86_64/debug.zig");

// TODO: Hook up os.heap.page_allocator to kernel allocator once implemented

const gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub export var framebuffer_request: limine.FramebufferRequest = .{};

inline fn done() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

// The following will be our kernel's entry point.
export fn _start() callconv(.C) noreturn {
    debug.print("Init CPU\n");
    try cpu.init();

    debug.print("Init framebuffer\n");
    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count < 1) {
            done();
        }

        // Get the first framebuffer's information.
        const framebuffer = framebuffer_response.framebuffers()[0];

        for (0..100) |i| {
            // Calculate the pixel offset using the framebuffer information we obtained above.
            // We skip `i` scanlines (pitch is provided in bytes) and add `i * 4` to skip `i` pixels forward.
            const pixel_offset = i * framebuffer.pitch + i * 4;

            // Write 0xFFFFFFFF to the provided pixel offset to fill it white.
            @as(*u32, @ptrCast(@alignCast(framebuffer.address + pixel_offset))).* = 0xFFFFFFFF;
        }
    }

    debug.print("Done.\n");
    done();
}
