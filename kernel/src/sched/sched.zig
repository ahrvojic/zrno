const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const virt = @import("../lib/virt.zig");

const stack_size: u64 = 4096;

var processes: std.DoublyLinkedList = .{};
var threads: std.DoublyLinkedList = .{};

var kernel_process: *proc.Process = undefined;
var idle_thread: *proc.Thread = undefined;

var pid_next: u64 = 0;
var tid_next: u64 = 0;

pub fn init() !void {
    const allocator = heap.kernel_heap.allocator();
    kernel_process = try startProcess(allocator, false);
    idle_thread = try startKernelThread(kernel_process, @intFromPtr(&idleThread), 0, false);
}

pub fn startProcess(allocator: std.mem.Allocator, enqueue: bool) !*proc.Process {
    const process = try allocator.create(proc.Process);
    errdefer allocator.destroy(process);

    process.* = .{
        .pid = @atomicRmw(u64, &pid_next, .Add, 1, .acq_rel),
        .parent = 0,
        .status = .ready,
        .heap = allocator,
        .threads = .{},
        .node = .{},
        .exit_code = 0,
    };

    if (enqueue) enqueueProcess(process);
    return process;
}

pub fn startKernelThread(parent: *proc.Process, pc: u64, arg: u64, enqueue: bool) !*proc.Thread {
    const thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const stack_phys = pmm.alloc(stack_size / pmm.page_size) orelse return error.OutOfMemory;
    const stack_virt = virt.toHH(u64, stack_phys);

    thread.* = .{
        .tid = @atomicRmw(u64, &tid_next, .Add, 1, .acq_rel),
        .status = .ready,
        .parent = parent,
        .proc_node = .{},
        .sched_node = .{},
        .on_runqueue = false,
    };

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.kernel_data_sel;
    thread.ctx.rip = pc;
    thread.ctx.rdi = arg;
    thread.ctx.rsp = stack_virt + stack_size;

    parent.threads.append(&thread.proc_node);

    if (enqueue) enqueueThread(thread);
    return thread;
}

pub fn schedule(ctx: *cpu.Context) void {
    var start: ?*std.DoublyLinkedList.Node = null;

    if (cpu.bsp.thread) |curr_thread| {
        curr_thread.ctx = ctx.*;
        if (curr_thread.status == .running) {
            curr_thread.status = .ready;
        }
        start = curr_thread.sched_node.next orelse threads.first;
    } else {
        start = threads.first;
    }

    const thread = nextReadyThread(start) orelse idle_thread;
    thread.status = .running;
    cpu.bsp.thread = thread;
    ctx.* = thread.ctx;
}

pub fn exitProcess(process: *proc.Process, exit_code: u8) void {
    process.exit_code = exit_code;
    process.status = .stopped;

    var node = process.threads.first;
    while (node) |n| {
        const thread: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        stopThread(thread);
    }

    if (cpu.bsp.thread) |curr| {
        if (curr.parent == process) {
            cpu.bsp.thread = null;
        }
    }
}

pub fn exitThread() noreturn {
    if (cpu.bsp.thread) |thread| {
        stopThread(thread);
    }
    cpu.bsp.thread = null;
    yield();
}

pub fn yield() void {
    // Timer interrupt to reschedule
    ivt.interrupt(ivt.vec_pit);
}

fn idleThread() callconv(.naked) noreturn {
    asm volatile (
        \\1:
        \\hlt
        \\jmp 1b
    );
}

fn enqueueProcess(process: *proc.Process) void {
    process.status = .running;
    processes.append(&process.node);
}

fn enqueueThread(thread: *proc.Thread) void {
    threads.append(&thread.sched_node);
    thread.on_runqueue = true;
}

fn dequeueThread(thread: *proc.Thread) void {
    if (!thread.on_runqueue) return;
    threads.remove(&thread.sched_node);
    thread.on_runqueue = false;
}

fn stopThread(thread: *proc.Thread) void {
    thread.status = .stopped;
    dequeueThread(thread);
}

fn nextReadyThread(start: ?*std.DoublyLinkedList.Node) ?*proc.Thread {
    const first = start orelse return null;
    var node: *std.DoublyLinkedList.Node = first;
    while (true) {
        const thread: *proc.Thread = @fieldParentPtr("sched_node", node);
        if (thread.status == .ready) return thread;
        node = node.next orelse threads.first orelse return null;
        if (node == first) return null;
    }
}
