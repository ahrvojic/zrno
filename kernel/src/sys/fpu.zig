const std = @import("std");

// Cap for x87+SSE+YMM (CPUID.0xD.0 EBX is 832 on typical AVX CPUs).
pub const state_size = 1024;
pub const state_align = 64;
pub const xcr0_x87: u64 = 1 << 0;
pub const xcr0_sse: u64 = 1 << 1;
pub const xcr0_avx: u64 = 1 << 2;
pub const xcr0_mask: u64 = xcr0_x87 | xcr0_sse | xcr0_avx;
pub const mxcsr_default: u32 = 0x1F80;

// XSAVE image. Must be 64-byte aligned. A zeroed header (xstate_bv = 0)
// makes XRSTOR load architectural defaults for every XCR0 component.
pub const State = extern struct {
    bytes: [state_size]u8 align(state_align) = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(State) == state_size);
    std.debug.assert(@alignOf(State) == state_align);
    std.debug.assert(xcr0_mask == 0b111);
}

pub fn initState(state: *State) void {
    state.* = .{};
}

test "default XSAVE image is zero" {
    var state: State = undefined;
    @memset(&state.bytes, 0xff);
    initState(&state);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** state_size, &state.bytes);
}
