var hhdm_offset: u64 = 0;
var initialized = false;

pub fn init(offset: u64) void {
    if (initialized) @panic("virt already initialized");
    hhdm_offset = offset;
    initialized = true;
}

pub fn toHH(comptime T: type, address: u64) T {
    if (!initialized) @panic("virt used before init");
    const res = address + hhdm_offset;
    return switch (@typeInfo(T)) {
        .pointer => @as(T, @ptrFromInt(res)),
        else => @as(T, res),
    };
}
