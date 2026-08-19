const logger = std.log.scoped(.heap);

const std = @import("std");

const Lock = @import("../lib/lock.zig");

pub var kernel_heap: HeapAllocator = .{};

pub const kernel_heap_base_addr = 0xffff_ffff_9000_0000;
pub const kernel_heap_size = 1024 * 1024 * 1024;

pub const HeapAllocator = struct {
    heap_base_addr: u64 = undefined,
    heap_end_addr: u64 = undefined,
    heap_curr_addr: u64 = undefined,
    lock: Lock.SpinLock = .{},
    initialized: bool = false,

    pub fn init(self: *@This(), base_addr: u64, size: u64) void {
        self.expectUninit();
        self.heap_base_addr = base_addr;
        self.heap_end_addr = base_addr + size;
        self.heap_curr_addr = base_addr;
        self.initialized = true;
    }

    pub fn allocator(self: *@This()) std.mem.Allocator {
        self.expectInit();
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

        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        const aligned = std.mem.alignForward(u64, self.heap_curr_addr, alignment.toByteUnits());

        if (aligned + len > self.heap_end_addr) {
            return null;
        }

        self.heap_curr_addr = aligned + len;
        return @ptrFromInt(aligned);
    }

    fn expectInit(self: *const @This()) void {
        if (!self.initialized) @panic("heap used before init");
    }

    fn expectUninit(self: *const @This()) void {
        if (self.initialized) @panic("heap already initialized");
    }
};

pub fn init() void {
    logger.info("Init kernel heap", .{});
    // Pages are committed by the #PF handler on first access.
    kernel_heap.init(kernel_heap_base_addr, kernel_heap_size);
}
