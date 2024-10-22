const std = @import("std");

const cpu = @import("../sys/cpu.zig");

pub const Process = struct {
    pid: u64,
    heap: std.mem.Allocator,
    threads: std.DoublyLinkedList(void),
    node: std.DoublyLinkedList(void).Node,
};

pub const Thread = struct {
    tid: u64,
    parent: *Process,
    ctx: cpu.Context = std.mem.zeroes(cpu.Context),
    node: std.DoublyLinkedList(void).Node,
};
