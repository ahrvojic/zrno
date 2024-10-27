const std = @import("std");

const cpu = @import("../sys/cpu.zig");

pub const ProcessStatus = enum {
    runnable,
    running,
    sleeping,
    stopped,
};

pub const Process = struct {
    pid: u64,
    status: ProcessStatus,
    heap: std.mem.Allocator,
    threads: std.DoublyLinkedList(void),
    node: std.DoublyLinkedList(void).Node,
};

pub const ThreadStatus = enum {
    runnable,
    running,
    sleeping,
    waiting,
    stopped,
};

pub const Thread = struct {
    tid: u64,
    status: ThreadStatus,
    parent: *Process,
    ctx: cpu.Context = std.mem.zeroes(cpu.Context),
    node: std.DoublyLinkedList(void).Node,
};
