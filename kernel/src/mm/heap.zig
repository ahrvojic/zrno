const logger = std.log.scoped(.heap);

const std = @import("std");

const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub var kernel_heap: HeapAllocator = .{};

const kernel_heap_base_addr = 0xffff_ffff_9000_0000;
const kernel_heap_size = 1024 * 1024 * 1024;

pub const HeapAllocator = struct {
    heap_base_addr: u64 = undefined,
    heap_end_addr: u64 = undefined,
    heap_curr_addr: u64 = undefined,

    pub fn init(self: *@This(), base_addr: u64, size: usize) !void {
        self.heap_base_addr = base_addr;
        self.heap_end_addr = base_addr + size;
        self.heap_curr_addr = base_addr;
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
        _ = ptr_align;
        _ = ret_addr;

        const base_addr = self.heap_curr_addr;

        // TODO

        // Advance the next available virtual address
        self.heap_curr_addr += len;

        return @as([*]u8, base_addr);
    }

    pub fn resize(self: *@This(), buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        if (new_len == 0) {
            self.free(buf, buf_align, ret_addr);
            return true;
        }

        if (new_len == buf.len) {
            return true;
        }

        const base_addr = @intFromPtr(buf.ptr);
        _ = base_addr;

        // TODO

        return false;
    }

    pub fn free(self: *@This(), buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = self;
        _ = buf_align;
        _ = ret_addr;

        const base_addr = @intFromPtr(buf.ptr);
        _ = base_addr;

        // TODO
    }
};

pub fn init() !void {
    logger.info("Init kernel heap", .{});

    // Map all virtual PTEs to the same read-only physical page with the
    // expectation that the page fault handler will allocate real memory
    // on demand. For that reason, also do not set as present.
    const zeros_phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
    try vmm.kernel_vmm.map(kernel_heap_base_addr, zeros_phys_addr, kernel_heap_size, vmm.Flags.None);

    try kernel_heap.init(kernel_heap_base_addr, kernel_heap_size);
}
