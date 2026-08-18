const boot = @import("../sys/boot.zig");

pub fn toHH(comptime T: type, address: u64) T {
    const res = address + boot.info.higher_half.offset;
    return switch (@typeInfo(T)) {
        .pointer => @as(T, @ptrFromInt(res)),
        else => @as(T, res),
    };
}
