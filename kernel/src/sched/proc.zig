const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const vmm = @import("../mm/vmm.zig");

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
    vmm: vmm.VMM,
    threads: std.DoublyLinkedList,
    node: std.DoublyLinkedList.Node,
    on_proctable: bool,
    exit_code: u8,
    // Exclusive top of the next user stack; grows down.
    user_stack_next: usize,
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
    ctx: cpu.Context = .{},
    wait_chan: ?*const anyopaque = null,
    wake_tick: u64 = 0,
    stack_phys: usize,
    // Mapped VA of the kernel stack (guard page is the page below).
    stack_base: usize,
    proc_node: std.DoublyLinkedList.Node,
    sched_node: std.DoublyLinkedList.Node,
    on_runqueue: bool,
};
