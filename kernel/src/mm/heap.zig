const logger = std.log.scoped(.heap);

const std = @import("std");

const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const HeapAllocator = struct {
    heap_base_addr: u64 = undefined,
    heap_end_addr: u64 = undefined,
    heap_curr_addr: u64 = undefined,

    pub fn init(self: *@This(), heap_vmm: *vmm.VMM, base_addr: u64, size: usize, kernel: bool) !void {
        // Page-align the heap address space
        self.heap_base_addr = std.mem.alignBackward(u64, base_addr, pmm.page_size);
        self.heap_end_addr = std.mem.alignForward(u64, base_addr + size, pmm.page_size);

        // Set current address to the beginning of the heap
        self.heap_curr_addr = self.heap_base_addr;

        // Map all virtual PTEs to the same read-only physical page with the
        // expectation that the page fault handler will allocate real memory
        // on demand. For that reason, also do not set as present.
        const zeros_phys_addr = pmm.alloc(1) orelse return error.OutOfMemory;
        const flags = if (kernel) vmm.Flags.None else vmm.Flags.User;
        heap_vmm.map(base_addr, zeros_phys_addr, size, flags);
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
    // Do nothing
}
