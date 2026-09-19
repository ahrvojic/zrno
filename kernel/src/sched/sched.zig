const logger = std.log.scoped(.sched);

const std = @import("std");

const aspace = @import("aspace.zig");
const cpu = @import("../sys/cpu.zig");
const file = @import("../fs/file.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const kstack = @import("kstack.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const thread = @import("thread.zig");
const vmm = @import("../mm/vmm.zig");

pub const tick_hz = state.tick_hz;
pub const startUserThread = thread.startUserThread;
pub const execReplace = thread.execReplace;
pub const setBrk = aspace.setBrk;
pub const mapAnon = aspace.mapAnon;
pub const isKernelStackGuard = kstack.isGuard;
pub const isUserStackGuard = aspace.isUserStackGuard;

// First `switchLocked` still runs on the Limine stack (`thread == null`).
var limine_stack = true;

// Local APIC timer ticks. 1 kHz so 1 tick = 1 ms (`tick_hz`).
var ticks: u64 = 0;

pub fn init() !void {
    state.expectUninit();
    const allocator = heap.kernel_heap.allocator();
    const kernel_process = try startProcess(allocator, true);
    // Fallback only; never linked into `threads`.
    state.idle_thread = try thread.startKernelThread(kernel_process, @intFromPtr(&idleThread), 0, false);
    state.initialized = true;
    logger.info("kernel pid={d} idle tid={d}", .{ kernel_process.pid, state.idle_thread.tid });
}

pub fn startProcess(allocator: std.mem.Allocator, enqueue: bool) !*proc.Process {
    const process = try allocator.create(proc.Process);
    errdefer allocator.destroy(process);

    process.* = .{
        .pid = 0,
        .parent = 0,
        .zombie = false,
        .heap = allocator,
        .vmm = try vmm.VMM.cloneKernel(),
        .threads = .{},
        .node = .{},
        .on_proctable = false,
        .exit_code = 0,
        .user_stack_next = state.user_stack_top,
        .mmap_next = state.user_mmap_top,
        .brk_start = 0,
        .brk = 0,
        .fds = [_]file.Fd{null} ** file.max_fds,
    };
    errdefer process.vmm.destroy();
    if (cpu.current().thread) |t| {
        process.parent = t.parent.pid;
    }

    state.lock.lock();
    defer state.lock.unlock();
    process.pid = state.pid_next;
    state.pid_next += 1;
    if (enqueue) state.enqueueProcess(process);
    return process;
}

fn findProcessLocked(pid: u64) ?*proc.Process {
    var node = state.processes.first;
    while (node) |n| {
        const process: *proc.Process = @fieldParentPtr("node", n);
        if (process.pid == pid) return process;
        node = n.next;
    }
    return null;
}

pub const WaitResult = struct { pid: u64, code: u8 };

// Park until a child has exited, then reap it. `pid == 0` waits for any
// child. Unrelated pids are ECHILD, not a hang.
pub fn waitProcess(pid: u64) error{ NoChild, Invalid }!WaitResult {
    state.expectInit();
    const cur = cpu.current().thread orelse @panic("wait with no thread");
    const waiter = cur.parent;
    if (pid == waiter.pid) return error.Invalid;

    state.lock.lock();
    defer state.lock.unlock();

    while (true) {
        if (pid == 0) {
            var live = false;
            var node = state.processes.first;
            while (node) |n| {
                const process: *proc.Process = @fieldParentPtr("node", n);
                node = n.next;
                if (!isWaitableChild(process, waiter.pid)) continue;
                if (process.zombie) return reapZombie(process);
                live = true;
            }
            if (!live) return error.NoChild;
            waitLocked(waiter);
            continue;
        }

        const process = findProcessLocked(pid) orelse return error.NoChild;
        if (!isWaitableChild(process, waiter.pid)) return error.NoChild;
        if (process.zombie) return reapZombie(process);
        waitLocked(process);
    }
}

fn isWaitableChild(process: *const proc.Process, parent_pid: u64) bool {
    return process.parent == parent_pid;
}

pub fn schedule(ctx: *cpu.Context) void {
    state.expectInit();
    state.lock.lock();
    defer state.lock.unlock();
    switchLocked(ctx);
}

pub fn tick(ctx: *cpu.Context) void {
    state.expectInit();
    state.lock.lock();
    defer state.lock.unlock();
    ticks +%= 1;
    wakeSleepers();
    switchLocked(ctx);
}

pub fn exitProcess(process: *proc.Process, exit_code: u8) void {
    state.expectInit();
    // Before the sched lock: last-close may later wakeup pipe waiters, and
    // wakeup takes sched. Heap (File.release) is a lower rank.
    file.closeAll(&process.fds);
    state.lock.lock();
    defer state.lock.unlock();

    if (process.pid == state.init_pid) {
        logger.err("init exited {d}", .{exit_code});
        @panic("init exited");
    }

    dismantleLocked(process, exit_code);

    var reparented = false;
    var pnode = state.processes.first;
    while (pnode) |n| {
        const child: *proc.Process = @fieldParentPtr("node", n);
        pnode = n.next;
        if (child.parent != process.pid or child == process) continue;
        child.parent = state.init_pid;
        reparented = true;
        logger.info("pid {d} reparent to init", .{child.pid});
    }

    wakeupLocked(process);
    if (findProcessLocked(process.parent)) |parent| {
        wakeupLocked(parent);
    }
    // Zombie and live kids now belong to init; wake its wait(0).
    if (reparented) {
        const reaper = findProcessLocked(state.init_pid) orelse @panic("no init");
        wakeupLocked(reaper);
    }
}

// Interrupt-context kill: stop the running user process and overwrite `ctx`
// with the next thread. Kernel pid 0 is fatal.
pub fn killCurrent(ctx: *cpu.Context, exit_code: u8) void {
    state.expectInit();
    const t = cpu.current().thread orelse @panic("kill with no thread");
    const process = t.parent;
    if (process.pid == state.kernel_pid) @panic("kill kernel process");
    exitProcess(process, exit_code);
    schedule(ctx);
}

// Spawn failed before the process ran. Not exitProcess: that panics on pid 1
// ("init exited") and would leave a zombie. Nobody is wait()ing.
pub fn abortProcess(process: *proc.Process, exit_code: u8) void {
    state.expectInit();
    file.closeAll(&process.fds);
    state.lock.lock();
    defer state.lock.unlock();

    dismantleLocked(process, exit_code);
    reapLocked(process);
}

pub fn yield() void {
    state.expectInit();
    ivt.interrupt(ivt.vec_yield);
}

// Park the current thread for `ms` milliseconds. 1 kHz tick, so 1 ms = 1 tick.
pub fn sleep(ms: u64) void {
    state.expectInit();
    if (ms == 0) return;
    const t = cpu.current().thread orelse @panic("sleep with no thread");

    state.lock.lock();
    t.status = .sleeping;
    t.wake_tick = ticks +| ms;
    state.lock.unlock();
    yield();
}

// Drop `held`, park as `.waiting` on `chan`, reacquire `held` on resume.
// Recheck the wait condition after return; wakeup is a broadcast.
pub fn wait(chan: *const anyopaque, held: *Lock.SpinLock) void {
    state.expectInit();
    if (held == &state.lock) @panic("wait with sched lock");
    const t = cpu.current().thread orelse @panic("wait with no thread");

    // Take sched while `held` is already held (see lock.zig). IRQs stay
    // off across the handoff so wakeup cannot miss this waiter.
    state.lock.lock();
    held.unlock();
    t.wait_chan = chan;
    t.status = .waiting;
    state.lock.unlock();
    yield();
    held.lock();
}

pub fn wakeup(chan: *const anyopaque) void {
    state.expectInit();
    state.lock.lock();
    defer state.lock.unlock();
    wakeupLocked(chan);
}

// Caller holds `state.lock`. Parks, then reacquires `state.lock` on resume.
fn waitLocked(chan: *const anyopaque) void {
    const t = cpu.current().thread orelse @panic("wait with no thread");
    t.wait_chan = chan;
    t.status = .waiting;
    state.lock.unlock();
    yield();
    state.lock.lock();
}

fn wakeupLocked(chan: *const anyopaque) void {
    var node = state.threads.first;
    while (node) |n| {
        const t: *proc.Thread = @fieldParentPtr("sched_node", n);
        if (t.status == .waiting and t.wait_chan == chan) {
            t.wait_chan = null;
            t.status = .ready;
        }
        node = n.next;
    }
}

fn switchLocked(ctx: *cpu.Context) void {
    kstack.reapDoomed();
    aspace.reapDoomedPt();
    const this_cpu = cpu.current();
    if (limine_stack and this_cpu.thread != null) {
        limine_stack = false;
        pmm.reclaimBootloader();
    }
    var start: ?*std.DoublyLinkedList.Node = null;

    if (this_cpu.thread) |curr_thread| {
        curr_thread.ctx = ctx.*;
        if (curr_thread.status == .running) {
            curr_thread.status = .ready;
        }
        start = curr_thread.sched_node.next orelse state.threads.first;
    } else {
        start = state.threads.first;
    }

    const next = nextReadyThread(start) orelse state.idle_thread;
    next.status = .running;
    this_cpu.thread = next;
    next.parent.vmm.switchTo();
    aspace.reapDoomedPt();
    // CPL 3 → 0 (IRQ) and SYSCALL both load this as the kernel stack top.
    // Absolute top; ctx.rsp is the thread's SP.
    this_cpu.setIrqStack(@intCast(next.stack_base + state.stack_size));
    ctx.* = next.ctx;
}

fn wakeSleepers() void {
    var node = state.threads.first;
    while (node) |n| {
        const t: *proc.Thread = @fieldParentPtr("sched_node", n);
        if (t.status == .sleeping and ticks >= t.wake_tick) {
            t.status = .ready;
        }
        node = n.next;
    }
}

fn idleThread() callconv(.naked) noreturn {
    asm volatile (
        \\1:
        \\hlt
        \\jmp 1b
    );
}

fn dismantleLocked(process: *proc.Process, exit_code: u8) void {
    process.exit_code = exit_code;
    process.zombie = true;
    var node = process.threads.first;
    while (node) |n| {
        const t: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        thread.stop(t);
    }
    aspace.dropAddressSpace(&process.vmm);
}

fn reapZombie(process: *proc.Process) WaitResult {
    const result: WaitResult = .{ .pid = process.pid, .code = process.exit_code };
    reapLocked(process);
    return result;
}

fn reapLocked(process: *proc.Process) void {
    state.dequeueProcess(process);
    process.heap.destroy(process);
}

fn nextReadyThread(start: ?*std.DoublyLinkedList.Node) ?*proc.Thread {
    const first = start orelse return null;
    var node: *std.DoublyLinkedList.Node = first;
    while (true) {
        const t: *proc.Thread = @fieldParentPtr("sched_node", node);
        if (t.status == .ready) return t;
        node = node.next orelse state.threads.first orelse return null;
        if (node == first) return null;
    }
}
