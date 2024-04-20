const logger = std.log.scoped(.heap);

const std = @import("std");

const vmm = @import("vmm");

const kheap_start: u64 = 0xffff_ffff_9000_0000;

pub fn init() !void {
    // TODO: Create kernel heap
}
