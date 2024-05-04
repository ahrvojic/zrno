const logger = std.log.scoped(.heap);

const std = @import("std");

const vmm = @import("vmm");

pub const HeapAllocator = struct {
    pub fn alloc(self: *@This(), len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = self;
        _ = len;
        _ = ptr_align;
        _ = ret_addr;
    }

    pub fn resize(self: *@This(), buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = self;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
    }

    pub fn free(self: *@This(), buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = self;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
    }
};

pub fn init() !void {
    // Do nothing
}
