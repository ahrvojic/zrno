//! A physical page owned by one block-cache slot. A second owner, when a
//! shared mapping exists, is a count on the physical page.

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const virt = @import("../lib/virt.zig");

pub const Frame = struct {
    phys: usize,

    pub fn bytes(self: *const Frame) []u8 {
        return virt.toHH([*]u8, self.phys)[0..pmm.page_size];
    }

    pub fn release(self: *Frame) void {
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
