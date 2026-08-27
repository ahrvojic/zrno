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
    threads: std.DoublyLinkedList,
    node: std.DoublyLinkedList.Node,
    on_proctable: bool,
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
    wait_chan: ?*const anyopaque = null,
    wake_tick: u64 = 0,
    proc_node: std.DoublyLinkedList.Node,
    sched_node: std.DoublyLinkedList.Node,
    on_runqueue: bool,
};
