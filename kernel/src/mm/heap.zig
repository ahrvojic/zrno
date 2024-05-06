const logger = std.log.scoped(.heap);

const std = @import("std");

const pmm = @import("pmm");
const vmm = @import("vmm");

pub const HeapAllocator = struct {
    heap_vmm: *vmm.VMM = undefined,
    heap_start_addr: u64 = undefined,
    heap_end_addr: u64 = undefined,
    zeros_phys_addr: u64 = undefined,

    pub fn init(self: *@This(), heap_vmm: *vmm.VMM, start_addr: u64, size: usize) !void {
        self.heap_vmm = heap_vmm;
        self.heap_start_addr = std.mem.alignBackward(u64, start_addr, pmm.page_size);
        self.heap_end_addr = std.mem.alignForward(u64, start_addr + size, pmm.page_size);
        self.zeros_phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
    }

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

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
