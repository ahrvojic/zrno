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

    pub fn init(self: *@This(), base_addr: u64, size: u64) !void {
        self.heap_base_addr = base_addr;
        self.heap_end_addr = base_addr + size;
        self.heap_curr_addr = base_addr;
    }

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = HeapAllocator.alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;

        const self: *HeapAllocator = @alignCast(@ptrCast(ctx));
        const aligned = std.mem.alignForward(u64, self.heap_curr_addr, alignment.toByteUnits());

        if (aligned + len > self.heap_end_addr) {
            return null;
        }

        self.heap_curr_addr = aligned + len;
        return @ptrFromInt(aligned);
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
