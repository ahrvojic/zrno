const logger = std.log.scoped(.heap);

const std = @import("std");

const core = @import("heap_core.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

comptime {
    std.debug.assert(pmm.page_size == core.page_size);
}

pub var kernel_heap: HeapAllocator = .{};

var page_ctx: u8 = 0;

pub const HeapAllocator = struct {
    inner: core.Heap = undefined,
    lock: Lock.SpinLock = .{},
    initialized: bool = false,

    pub fn init(self: *@This()) void {
        self.expectUninit();
        self.inner = .init(.{
            .ctx = @ptrCast(&page_ctx),
            .alloc = allocKernelPages,
            .free = freeKernelPages,
        });
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

fn allocKernelPages(_: *anyopaque, pages: usize) ?[*]u8 {
    const phys = pmm.alloc(@intCast(pages)) orelse return null;
    return virt.toHH([*]u8, phys);
}

fn freeKernelPages(_: *anyopaque, ptr: [*]u8, pages: usize) void {
    pmm.free(virt.fromHH(@intFromPtr(ptr)), @intCast(pages));
}

pub fn init() void {
    logger.info("Init kernel heap", .{});
    kernel_heap.init();
}
