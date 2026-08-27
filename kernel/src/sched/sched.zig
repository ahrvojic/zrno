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
const kernel_pid: u64 = 0;

// Live processes; not a runqueue. `schedule` walks `threads`.
var processes: std.DoublyLinkedList = .{};
var threads: std.DoublyLinkedList = .{};

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
    const kernel_process = try startProcess(allocator, true);
    // Fallback only; never linked into `threads`.
    idle_thread = try startKernelThread(kernel_process, @intFromPtr(&idleThread), 0, false);
    initialized = true;
}

pub fn spawnKernelThread(pc: u64, arg: u64) !*proc.Thread {
    expectInit();
    const parent = findProcess(kernel_pid) orelse @panic("kernel process missing");
    return startKernelThread(parent, pc, arg, true);
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
        .on_proctable = false,
        .exit_code = 0,
    };

    lock.lock();
    defer lock.unlock();
    process.pid = pid_next;
    pid_next += 1;
    if (enqueue) enqueueProcess(process);
    return process;
}

pub fn findProcess(pid: u64) ?*proc.Process {
    expectInit();
    lock.lock();
    defer lock.unlock();

    var node = processes.first;
    while (node) |n| {
        const process: *proc.Process = @fieldParentPtr("node", n);
        if (process.pid == pid) return process;
        node = n.next;
    }
    return null;
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
    dequeueProcess(process);

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

// Drop `held`, park as `.waiting` on `chan`, reacquire `held` on resume.
// Recheck the wait condition after return; wakeup is a broadcast.
pub fn wait(chan: *const anyopaque, held: *Lock.SpinLock) void {
    expectInit();
    if (held == &lock) @panic("wait with sched lock");
    const thread = cpu.current().thread orelse @panic("wait with no thread");

    // Take sched while `held` is already held (see lock.zig). IRQs stay
    // off across the handoff so wakeup cannot miss this waiter.
    lock.lock();
    held.unlock();
    thread.wait_chan = chan;
    thread.status = .waiting;
    lock.unlock();
    yield();
    held.lock();
}

pub fn wakeup(chan: *const anyopaque) void {
    expectInit();
    lock.lock();
    defer lock.unlock();

    var node = threads.first;
    while (node) |n| {
        const thread: *proc.Thread = @fieldParentPtr("sched_node", n);
        if (thread.status == .waiting and thread.wait_chan == chan) {
            thread.wait_chan = null;
            thread.status = .ready;
        }
        node = n.next;
    }
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
    if (process.on_proctable) return;
    processes.append(&process.node);
    process.on_proctable = true;
}

fn dequeueProcess(process: *proc.Process) void {
    if (!process.on_proctable) return;
    processes.remove(&process.node);
    process.on_proctable = false;
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
    thread.wait_chan = null;
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
