var hhdm_offset: usize = 0;
var initialized = false;

pub fn init(offset: u64) void {
    if (initialized) @panic("virt already initialized");
    hhdm_offset = @intCast(offset);
    initialized = true;
}

pub fn toHH(comptime T: type, address: usize) T {
    if (!initialized) @panic("virt used before init");
    const res = address + hhdm_offset;
    return switch (@typeInfo(T)) {
        .pointer => @as(T, @ptrFromInt(res)),
        else => @as(T, res),
    };
}

pub fn fromHH(address: usize) usize {
    if (!initialized) @panic("virt used before init");
    return address - hhdm_offset;
}
