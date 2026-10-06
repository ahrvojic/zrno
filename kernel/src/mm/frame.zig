//! A physical page with a reference count. A file and a mapping can each
//! hold one. The page is freed when the last owner releases it.

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

pub const Frame = struct {
    phys: usize,
    refs: usize = 1,

    pub fn bytes(self: *const Frame) []u8 {
        return virt.toHH([*]u8, self.phys)[0..pmm.page_size];
    }

    pub fn retain(self: *Frame) void {
        self.refs += 1;
    }

    pub fn release(self: *Frame) void {
        if (self.refs == 0) @panic("frame refcount underflow");
        self.refs -= 1;
        if (self.refs != 0) return;
        const phys = self.phys;
        pmm.free(phys, 1);
        heap.kernel_heap.allocator().destroy(self);
    }
};

pub fn alloc() ?*Frame {
    const phys = pmm.alloc(1) orelse return null;
    const frame = heap.kernel_heap.allocator().create(Frame) catch {
        pmm.free(phys, 1);
        return null;
    };
    frame.* = .{ .phys = phys };
    return frame;
}
