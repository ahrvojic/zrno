const std = @import("std");

const cpu = @import("../sys/cpu.zig");

pub const ProcessStatus = enum {
    ready,
    running,
    stopped,
};

pub const Process = struct {
    pid: u64,
    parent: u64,
    status: ProcessStatus,
    heap: std.mem.Allocator,
    threads: std.DoublyLinkedList(void),
    node: std.DoublyLinkedList(void).Node,
    exit_code: u8,
};

pub const ThreadStatus = enum {
    ready,
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
