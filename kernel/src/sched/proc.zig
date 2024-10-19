const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const vmm = @import("../mm/vmm.zig");

pub const Process = struct {
    pid: u64,
    threads: std.DoublyLinkedList(*Thread),
    vmm: *vmm.VMM,
};

pub const Thread = struct {
    tid: u64,
    parent: *Process,
    ctx: cpu.Context = std.mem.zeroes(cpu.Context),
};
