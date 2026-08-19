const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const virt = @import("../lib/virt.zig");

const stack_size: u64 = pmm.page_size;

var processes: std.DoublyLinkedList = .{};
var threads: std.DoublyLinkedList = .{};

var kernel_process: *proc.Process = undefined;
var idle_thread: *proc.Thread = undefined;

var pid_next: u64 = 0;
var tid_next: u64 = 0;

var lock: Lock.SpinLock = .{};
var initialized = false;

fn expectInit() void {
    if (!initialized) @panic("sched used before init");
}

fn expectUninit() void {
    if (initialized) @panic("sched already initialized");
}

pub fn init() !void {
    expectUninit();
    const allocator = heap.kernel_heap.allocator();
    kernel_process = try startProcess(allocator, false);
    // Fallback only; never linked into `threads`.
    idle_thread = try startKernelThread(kernel_process, @intFromPtr(&idleThread), 0, false);
    initialized = true;
}

pub fn spawnKernelThread(pc: u64, arg: u64) !*proc.Thread {
    expectInit();
    return startKernelThread(kernel_process, pc, arg, true);
}

pub fn startProcess(allocator: std.mem.Allocator, enqueue: bool) !*proc.Process {
    const process = try allocator.create(proc.Process);
    errdefer allocator.destroy(process);

    process.* = .{
        .pid = 0,
        .parent = 0,
        .status = .ready,
        .heap = allocator,
        .threads = .{},
        .node = .{},
        .exit_code = 0,
    };

    lock.lock();
    defer lock.unlock();
    process.pid = pid_next;
    pid_next += 1;
    if (enqueue) enqueueProcess(process);
    return process;
}

pub fn startKernelThread(parent: *proc.Process, pc: u64, arg: u64, enqueue: bool) !*proc.Thread {
    const thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const stack_phys = pmm.alloc(stack_size / pmm.page_size) orelse return error.OutOfMemory;
    const stack_virt = virt.toHH(u64, stack_phys);

    thread.* = .{
        .tid = 0,
        .status = .ready,
        .parent = parent,
        .proc_node = .{},
        .sched_node = .{},
        .on_runqueue = false,
    };

    // Fake a `call` so a `ret` panics instead of running off the stack, and so
    // SysV entry alignment is rsp ≡ 8 (mod 16).
    const stack: [*]u64 = @ptrFromInt(stack_virt);
    const slots = stack_size / @sizeOf(u64);
    stack[slots - 1] = @intFromPtr(&kernelThreadReturned);

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.kernel_data_sel;
    thread.ctx.rip = pc;
    thread.ctx.rdi = arg;
    thread.ctx.rsp = stack_virt + stack_size - @sizeOf(u64);

    lock.lock();
    defer lock.unlock();
    thread.tid = tid_next;
    tid_next += 1;
    parent.threads.append(&thread.proc_node);
    if (enqueue) enqueueThread(thread);
    return thread;
}

pub fn schedule(ctx: *cpu.Context) void {
    expectInit();
    lock.lock();
    defer lock.unlock();

    const this_cpu = cpu.current();
    var start: ?*std.DoublyLinkedList.Node = null;

    if (this_cpu.thread) |curr_thread| {
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
    this_cpu.thread = thread;
    ctx.* = thread.ctx;
}

pub fn exitProcess(process: *proc.Process, exit_code: u8) void {
    expectInit();
    lock.lock();
    defer lock.unlock();

    process.exit_code = exit_code;
    process.status = .stopped;

    var node = process.threads.first;
    while (node) |n| {
        const thread: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        stopThread(thread);
    }

    const this_cpu = cpu.current();
    if (this_cpu.thread) |curr| {
        if (curr.parent == process) {
            this_cpu.thread = null;
        }
    }
}

pub fn exitThread() noreturn {
    expectInit();
    const this_cpu = cpu.current();
    lock.lock();
    if (this_cpu.thread) |thread| {
        stopThread(thread);
    }
    this_cpu.thread = null;
    lock.unlock();
    yield();
}

pub fn yield() void {
    expectInit();
    // Timer interrupt to reschedule
    ivt.interrupt(ivt.vec_pit);
}

fn kernelThreadReturned() callconv(.c) noreturn {
    @panic("kernel thread returned");
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
