const std = @import("std");

pub const state_size = 512;
pub const state_align = 16;
pub const fcw_default: u16 = 0x037F;
pub const mxcsr_default: u32 = 0x1F80;
const mxcsr_off = 24;

// 512-byte FXSAVE image. Must be 16-byte aligned.
pub const State = extern struct {
    bytes: [state_size]u8 align(state_align) = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(State) == state_size);
    std.debug.assert(@alignOf(State) == state_align);
}

pub fn initState(state: *State) void {
    state.* = .{};
    std.mem.writeInt(u16, state.bytes[0..2], fcw_default, .little);
    std.mem.writeInt(u32, state.bytes[mxcsr_off..][0..4], mxcsr_default, .little);
}

test "default FXSAVE image" {
    var state: State = undefined;
    initState(&state);
    try std.testing.expectEqual(fcw_default, std.mem.readInt(u16, state.bytes[0..2], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, state.bytes[2..4], .little));
    try std.testing.expectEqual(mxcsr_default, std.mem.readInt(u32, state.bytes[24..28], .little));
    try std.testing.expectEqual(@as(u8, 0), state.bytes[4]);
    try std.testing.expectEqual(@as(u8, 0), state.bytes[32]);
}
