const logger = std.log.scoped(.heap);

const std = @import("std");

const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const Block = struct {
  base_addr: u64,
  size: usize,
};

const HeapList = std.DoublyLinkedList(Block);
const HeapNode = HeapList.Node;

pub const HeapAllocator = struct {
    used_list: HeapList = .{},
    free_list: HeapList = .{},

    heap_vmm: *vmm.VMM = undefined,
    heap_base_addr: u64 = undefined,
    heap_end_addr: u64 = undefined,
    heap_curr_addr: u64 = undefined,
    zeros_phys_addr: u64 = undefined,

    pub fn init(self: *@This(), heap_vmm: *vmm.VMM, base_addr: u64, size: usize) !void {
        self.heap_vmm = heap_vmm;
        self.heap_base_addr = std.mem.alignBackward(u64, base_addr, pmm.page_size);
        self.heap_end_addr = std.mem.alignForward(u64, base_addr + size, pmm.page_size);
        self.heap_curr_addr = self.heap_base_addr;
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
        _ = ptr_align;
        _ = ret_addr;

        const size = std.alignForward(u64, len, pmm.page_size);

        // Look for a suitable free block and move it to the used list
        var it = self.free_list.first();
        while (it) |block| : (it = block.next) {
            if (block.data.size >= size) {
                // TODO: Block split
                self.free_list.remove(block);
                self.used_list.prepend(block);
                return @as([*]u8, @ptrFromInt(block.base_addr));
            }
        }

        // Otherwise create a new block and add it to the used list
        const node: HeapNode = .{.data = .{.base_addr = self.heap_curr_addr, .size = size }};
        self.used_list.prepend(node);

        // Map all virtual PTEs to the same read-only physical page with the
        // expectation that the page fault handler will allocate real memory
        // on demand. For that reason, also do not set as present.
        self.heap_vmm.map(self.heap_curr_addr, self.zeros_phys_addr, size, vmm.Flags.User);

        // Advance the next available virtual address
        self.heap_curr_addr += size;

        return @as([*]u8, @ptrFromInt(node.data.base_addr));
    }

    pub fn resize(self: *@This(), buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = self;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
    }

    pub fn free(self: *@This(), buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;

        const base_addr = @intFromPtr(buf.ptr);

        // Look for the specified node and move it to the free list
        var it = self.used_list.first();
        while (it) |node| : (it = node.next) {
            if (node.data.base_addr == base_addr) {
                self.used_list.remove(node);

                var it_f = self.free_list.first();
                if (it_f == null) {
                    self.free_list.prepend(node);
                } else {
                    // Insert the node in ascending base address order to
                    // facilitate merging
                    while (it_f) |node_f| : (it_f = node_f.next) {
                        if (node.data.base_addr > node_f.data.base_addr) {
                            self.free_list.insertAfter(node_f, node);
                            break;
                        }
                    }

                    // TODO: Try to merge with its neighbors
                }

                return;
            }
        }
    }
};

pub fn init() !void {
    // Do nothing
}
