const boot = @import("../sys/boot.zig");

pub fn toHH(comptime T: type, address: u64) T {
    const res = address + boot.info.higher_half.offset;
    return if (@typeInfo(T) == .Pointer) @as(T, @ptrFromInt(res)) else @as(T, res);
}
