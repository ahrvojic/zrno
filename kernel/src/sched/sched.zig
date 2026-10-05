const logger = std.log.scoped(.sched);

const std = @import("std");

const aspace = @import("aspace.zig");
const cpu = @import("../sys/cpu.zig");
const file = @import("../fs/file.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const kstack = @import("kstack.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const thread = @import("thread.zig");
const vfs = @import("../fs/vfs.zig");
const vmm = @import("../mm/vmm.zig");

pub const tick_hz = state.tick_hz;
pub const startUserThread = thread.startUserThread;
pub const createUserThread = thread.createUserThread;
pub const setBrk = aspace.setBrk;
pub const mapAnon = aspace.mapAnon;
pub const unmapAnon = aspace.unmapAnon;
pub const isKernelStackGuard = kstack.isGuard;
pub const isUserStackGuard = aspace.isUserStackGuard;

// First `schedule` still runs on the boot stack (`thread == null`).
var boot_stack = true;

// Local APIC timer ticks. 1 kHz so 1 tick = 1 ms (`tick_hz`).
var ticks: u64 = 0;

// Shell prints this as `exit: 130`.
const ctrl_c_status: u8 = 130;

// Child the outer specific-pid wait is parked on. `wait(0)` does not arm it.
var foreground: ?*proc.Process = null;

pub fn ticksSinceBoot() u64 {
    return ticks;
}

pub fn init() !void {
    state.expectUninit();
    const kernel_process = try startProcess(true);
    // Fallback only; never linked into `threads`.
    state.idle_thread = try thread.startKernelThread(kernel_process, @intFromPtr(&idleThread), 0, false);
    state.initialized = true;
    logger.info("kernel pid={d} idle tid={d}", .{ kernel_process.pid, state.idle_thread.tid });
}

pub fn startProcess(enqueue: bool) !*proc.Process {
    const allocator = heap.kernel_heap.allocator();
    const process = try allocator.create(proc.Process);
    errdefer allocator.destroy(process);

    const cwd = if (cpu.current().thread) |t| t.parent.cwd else vfs.root();
    process.* = .{
        .pid = 0,
        .parent = 0,
        .zombie = false,
        .vmm = try vmm.VMM.cloneKernel(),
        .threads = .{},
        .node = .{},
        .on_proctable = false,
        .exit_code = 0,
        .user_stack_next = state.user_stack_top,
        .mmap_next = state.user_mmap_top,
        .brk_start = 0,
        .brk = 0,
        .fds = @splat(null),
        .cwd = cwd,
    };
    cwd.retain();
    errdefer cwd.release();
    errdefer process.vmm.destroy();
    if (cpu.current().thread) |t| {
        process.parent = t.parent.pid;
    }

    process.pid = state.pid_next;
    state.pid_next += 1;
    if (enqueue) state.enqueueProcess(process);
    return process;
}

fn processFromNode(n: *std.DoublyLinkedList.Node) *proc.Process {
    return @fieldParentPtr("node", n);
}

fn threadFromSched(n: *std.DoublyLinkedList.Node) *proc.Thread {
    return @fieldParentPtr("sched_node", n);
}

fn threadFromProc(n: *std.DoublyLinkedList.Node) *proc.Thread {
    return @fieldParentPtr("proc_node", n);
}

fn findProcess(pid: u64) ?*proc.Process {
    var node = state.processes.first;
    while (node) |n| {
        const process = processFromNode(n);
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
    const waiter = cpu.currentProcess();
    if (pid == waiter.pid) return error.Invalid;

    // Nested specific-pid waits leave the outer child armed.
    var armed = false;
    while (true) {
        const target = pickWaitTarget(pid, waiter.pid) orelse {
            if (armed) foreground = null;
            return error.NoChild;
        };
        if (target.zombie) {
            if (armed) foreground = null;
            return reapZombie(target);
        }
        if (pid != 0 and foreground == null) {
            foreground = target;
            armed = true;
        }
        wait(if (pid == 0) waiter else target);
    }
}

/// Exit the foreground child. A second Ctrl-C sees a zombie and returns false.
pub fn stopForeground() bool {
    state.expectInit();
    const victim = foreground orelse return false;
    if (victim.zombie) return false;
    exitProcess(victim, ctrl_c_status);
    return true;
}

fn pickWaitTarget(pid: u64, parent_pid: u64) ?*proc.Process {
    if (pid != 0) {
        const process = findProcess(pid) orelse return null;
        if (process.parent != parent_pid) return null;
        return process;
    }
    var live: ?*proc.Process = null;
    var node = state.processes.first;
    while (node) |n| {
        const process = processFromNode(n);
        node = n.next;
        if (process.parent != parent_pid) continue;
        if (process.zombie) return process;
        live = live orelse process;
    }
    return live;
}

pub fn tick(ctx: *cpu.Context) void {
    state.expectInit();
    ticks +%= 1;
    wakeSleepers();
    schedule(ctx);
}

// End this thread. The last thread exits the process: same zombie, same
// `wait`, fds closed. An earlier thread unmaps its own user stack and
// leaves the process running.
pub fn exitThread(exit_code: u8) noreturn {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("kernel thread exit");

    const self = cpu.currentThread();
    if (hasSibling(process, self)) {
        const base = self.user_stack;
        if (base == 0) @panic("thread exit without user stack");
        aspace.releaseUserStack(process, base);
        aspace.unmapUserStack(&process.vmm, base);
        thread.stop(self);
        yield();
        unreachable;
    }

    logger.info("pid {d} exit {d}", .{ process.pid, exit_code });
    exitProcess(process, exit_code);
    yield();
    unreachable;
}

fn hasSibling(process: *proc.Process, self: *proc.Thread) bool {
    var node = process.threads.first;
    while (node) |n| {
        if (threadFromProc(n) != self) return true;
        node = n.next;
    }
    return false;
}

pub fn exitProcess(process: *proc.Process, exit_code: u8) void {
    state.expectInit();
    // Last close wakes pipe waiters before this process is a zombie.
    file.closeAll(&process.fds);
    process.cwd.release();

    if (process.pid == state.init_pid) {
        logger.err("init exited {d}", .{exit_code});
        @panic("init exited");
    }

    dismantle(process, exit_code);

    var reparented = false;
    var pnode = state.processes.first;
    while (pnode) |n| {
        const child = processFromNode(n);
        pnode = n.next;
        if (child.parent != process.pid or child == process) continue;
        child.parent = state.init_pid;
        reparented = true;
        logger.info("pid {d} reparent to init", .{child.pid});
    }

    wakeup(process);
    if (findProcess(process.parent)) |parent| {
        wakeup(parent);
    }
    // Zombie and live kids now belong to init; wake its wait(0).
    if (reparented) {
        const reaper = findProcess(state.init_pid) orelse @panic("no init");
        wakeup(reaper);
    }
}

// Interrupt-context kill: stop the running user process and overwrite `ctx`
// with the next thread. Kernel pid 0 is fatal.
pub fn killCurrent(ctx: *cpu.Context, exit_code: u8) void {
    state.expectInit();
    const process = cpu.currentProcess();
    if (process.pid == state.kernel_pid) @panic("kill kernel process");
    exitProcess(process, exit_code);
    schedule(ctx);
}

// Spawn failed before the process ran. Not exitProcess: that panics on pid 1
// ("init exited") and would leave a zombie. Nobody is wait()ing.
pub fn abortProcess(process: *proc.Process, exit_code: u8) void {
    state.expectInit();
    file.closeAll(&process.fds);
    process.cwd.release();
    dismantle(process, exit_code);
    reap(process);
}

pub fn yield() void {
    state.expectInit();
    ivt.interrupt(ivt.vec_yield);
}

// Park the current thread for `ms` milliseconds. 1 kHz tick, so 1 ms = 1 tick.
pub fn sleep(ms: u64) void {
    state.expectInit();
    if (ms == 0) return;
    const t = cpu.currentThread();
    t.status = .sleeping;
    t.wake_tick = ticks +| ms;
    yield();
}

// Park as `.waiting` on `chan`. Recheck the condition after return; wakeup
// is a broadcast. The caller's check and this status store both run with
// interrupts off, so a timer or keypress cannot land between them and lose
// the wakeup.
pub fn wait(chan: *const anyopaque) void {
    state.expectInit();
    const t = cpu.currentThread();
    t.wait_chan = chan;
    t.status = .waiting;
    yield();
}

pub fn wakeup(chan: *const anyopaque) void {
    _ = wakeOn(chan, null);
}

/// Wake threads in `process` parked by `wait` on the user address `addr`.
pub fn wakeWord(process: *proc.Process, addr: usize) usize {
    return wakeOn(@ptrFromInt(addr), process);
}

/// `process` null wakes every thread on `chan`. A process wakes only its own.
fn wakeOn(chan: *const anyopaque, process: ?*proc.Process) usize {
    state.expectInit();
    var n: usize = 0;
    var node = state.threads.first;
    while (node) |nd| {
        const t = threadFromSched(nd);
        if (t.status == .waiting and t.wait_chan == chan and (process == null or t.parent == process)) {
            t.wait_chan = null;
            t.status = .ready;
            n += 1;
        }
        node = nd.next;
    }
    return n;
}

pub fn schedule(ctx: *cpu.Context) void {
    state.expectInit();
    kstack.reapDoomed();
    aspace.reapDoomedPt();
    const this_cpu = cpu.current();
    if (boot_stack and this_cpu.thread != null) {
        boot_stack = false;
        pmm.reclaimBootloader();
    }
    var start: ?*std.DoublyLinkedList.Node = null;

    if (this_cpu.thread) |curr_thread| {
        curr_thread.ctx = ctx.*;
        cpu.saveFpu(curr_thread.fpu);
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
    cpu.restoreFpu(next.fpu);
}

fn wakeSleepers() void {
    var node = state.threads.first;
    while (node) |n| {
        const t = threadFromSched(n);
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

fn dismantle(process: *proc.Process, exit_code: u8) void {
    process.exit_code = exit_code;
    process.zombie = true;
    var node = process.threads.first;
    while (node) |n| {
        const t = threadFromProc(n);
        node = n.next;
        thread.stop(t);
    }
    aspace.dropAddressSpace(&process.vmm);
}

fn reapZombie(process: *proc.Process) WaitResult {
    const result: WaitResult = .{ .pid = process.pid, .code = process.exit_code };
    reap(process);
    return result;
}

fn reap(process: *proc.Process) void {
    state.dequeueProcess(process);
    heap.kernel_heap.allocator().destroy(process);
}

fn nextReadyThread(start: ?*std.DoublyLinkedList.Node) ?*proc.Thread {
    const first = start orelse return null;
    var node: *std.DoublyLinkedList.Node = first;
    while (true) {
        const t = threadFromSched(node);
        if (t.status == .ready) return t;
        node = node.next orelse state.threads.first orelse return null;
        if (node == first) return null;
    }
}

pub const PsSnap = struct {
    tid: u64,
    pid: u64,
    ppid: u64,
    // Null on a zombie: `thread.stop` already removed its threads.
    status: ?proc.ThreadStatus,
};

// One row per thread, in process-table order. A zombie is one row with
// no status. The idle thread is not on the run queue, but it is on the
// kernel process, so it is included.
pub fn snapshotPs(out: []PsSnap) usize {
    state.expectInit();
    var n: usize = 0;
    var node = state.processes.first;
    while (node) |nd| {
        const p = processFromNode(nd);
        if (p.zombie) {
            if (n == out.len) break;
            out[n] = .{ .tid = 0, .pid = p.pid, .ppid = p.parent, .status = null };
            n += 1;
        } else {
            var tnode = p.threads.first;
            while (tnode) |tn| {
                if (n == out.len) return n;
                const t = threadFromProc(tn);
                out[n] = .{
                    .tid = t.tid,
                    .pid = p.pid,
                    .ppid = p.parent,
                    .status = t.status,
                };
                n += 1;
                tnode = tn.next;
            }
        }
        node = nd.next;
    }
    return n;
}
