const logger = std.log.scoped(.heap);

const std = @import("std");

const core = @import("heap_core.zig");
const Lock = @import("../lib/lock.zig");

pub var kernel_heap: HeapAllocator = .{};

pub const kernel_heap_base_addr = 0xffff_ffff_9000_0000;
pub const kernel_heap_size = core.max_size;

pub const HeapAllocator = struct {
    inner: core.Heap = undefined,
    lock: Lock.SpinLock = .{},
    initialized: bool = false,

    pub fn init(self: *@This(), base_addr: u64, size: u64) void {
        self.expectUninit();
        self.inner = .init(base_addr, size);
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
                .free = HeapAllocator.free,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;

        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        self.expectInit();
        self.lock.lock();
        defer self.lock.unlock();
        return self.inner.alloc(len, alignment);
    }

    pub fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;

        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        self.expectInit();
        // First store can #PF (vmm then pmm). Must not hold the heap lock:
        // rank is vmm → heap, and the spinlock is not recursive.
        if (buf.len != 0) {
            const node: *volatile core.FreeNode = @ptrCast(@alignCast(buf.ptr));
            node.next = undefined;
        }

        self.lock.lock();
        defer self.lock.unlock();
        self.inner.free(buf, alignment);
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
