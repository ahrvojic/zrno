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
                .alloc = self.alloc,
                .resize = std.mem.Allocator.noResize,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    pub fn alloc(self: *@This(), len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ptr_align;
        _ = ret_addr;

        if (self.heap_curr_addr + len > self.heap_end_addr) {
            return null;
        }

        const base_addr = self.heap_curr_addr;

        // Advance the next available virtual address
        self.heap_curr_addr += len;

        return @as([*]u8, base_addr);
    }
};

pub fn init() !void {
    logger.info("Init kernel heap", .{});

    // Map all virtual PTEs to the same read-only physical page with the
    // expectation that the page fault handler will allocate real memory
    // on demand. For that reason, also do not set as present.
    const zeros_phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
    try vmm.kernel_vmm.map(kernel_heap_base_addr, zeros_phys_addr, kernel_heap_size, 0);

    try kernel_heap.init(kernel_heap_base_addr, kernel_heap_size);
}
