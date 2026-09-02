const logger = std.log.scoped(.sched);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const elf = @import("../sys/elf.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const vmm = @import("../mm/vmm.zig");

pub const tick_hz: u64 = 1000;

// Kernel threads and TSS.rsp[0] (syscall/IRQ). 16 KiB covers a 1 KiB
// print buffer plus a nested IRQ frame (int 0x80 → 0x90, or timer during print).
const stack_size: usize = 16 * pmm.page_size;
const stack_pages: usize = stack_size / pmm.page_size;
const kernel_pid: u64 = 0;
// Exclusive top of the first user stack. Later threads grow down one
// stack_size at a time. Canonical low half (2 GiB).
const user_stack_top: usize = elf.user_stack_top;

// Kernel stacks live in the cloned higher half (not HHDM) so an unmapped
// guard page under each stack is possible. PML4 510: below the kernel
// image, above HHDM.
const kstack_region_base: usize = 0xffff_ff00_0000_0000;
const kstack_region_end: usize = kstack_region_base + (1024 * 1024 * 1024);
const kstack_slot: usize = stack_size + pmm.page_size;

comptime {
    std.debug.assert(stack_size == elf.user_stack_window);
    std.debug.assert(user_stack_top % pmm.page_size == 0);
    std.debug.assert(user_stack_top < 0x0000_8000_0000_0000);
    std.debug.assert(kstack_region_base % pmm.page_size == 0);
    std.debug.assert(kstack_slot % pmm.page_size == 0);
    std.debug.assert(kstack_region_base >= 0xffff_8000_0000_0000);
    std.debug.assert(kstack_region_end <= 0xffff_ffff_8000_0000);
}

// Live processes; not a runqueue. `schedule` walks `threads`.
var processes: std.DoublyLinkedList = .{};
var threads: std.DoublyLinkedList = .{};

var idle_thread: *proc.Thread = undefined;

var pid_next: u64 = 0;
var tid_next: u64 = 0;

var lock: Lock.SpinLock = .{};
var initialized = false;

// Kernel stack of a thread that died while running on it. Unmapped and
// freed on the next `switchLocked` that is no longer executing on that stack.
const DoomedStack = struct { phys: usize, base: usize };
var doomed_stack: ?DoomedStack = null;
var kstack_next: usize = kstack_region_base;

// Unique PML4 of a process that died while CR3 still pointed at it.
// Freed on the next `switchLocked` that is no longer using that root.
var doomed_pt_phys: ?usize = null;

// Local APIC timer ticks. 1 kHz so 1 tick = 1 ms (`tick_hz`).
var ticks: u64 = 0;

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
    logger.info("kernel pid={d} idle tid={d}", .{ kernel_process.pid, idle_thread.tid });
}

pub fn spawnKernelThread(pc: usize, arg: usize) !*proc.Thread {
    expectInit();
    const parent = findProcess(kernel_pid) orelse @panic("kernel process missing");
    return startKernelThread(parent, pc, arg, true);
}

pub fn spawnUserThread(pc: usize, arg: usize) !*proc.Thread {
    expectInit();
    const process = try startProcess(heap.kernel_heap.allocator(), true);
    errdefer exitProcess(process, 1);
    return startUserThread(process, pc, arg, true);
}

pub fn startProcess(allocator: std.mem.Allocator, enqueue: bool) !*proc.Process {
    const process = try allocator.create(proc.Process);
    errdefer allocator.destroy(process);

    process.* = .{
        .pid = 0,
        .parent = 0,
        .status = .ready,
        .heap = allocator,
        .vmm = try vmm.VMM.cloneKernel(),
        .threads = .{},
        .node = .{},
        .on_proctable = false,
        .exit_code = 0,
        .user_stack_next = user_stack_top,
        .fds = [_]proc.Fd{.empty} ** proc.max_fds,
    };
    process.fds[0] = .tty;
    process.fds[1] = .tty;
    process.fds[2] = .tty;

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

// Park until `pid` is gone. Pid 0 is the kernel process and never exits.
pub fn waitProcess(pid: u64) void {
    expectInit();
    if (pid == kernel_pid) @panic("waitProcess kernel process");
    while (findProcess(pid) != null) {
        yield();
    }
}

pub const ThreadInfo = struct {
    tid: u64,
    pid: u64,
    status: proc.ThreadStatus,
};

pub fn copyThreads(out: []ThreadInfo) usize {
    expectInit();
    lock.lock();
    defer lock.unlock();

    var n: usize = 0;
    var node = threads.first;
    while (node) |nd| : (node = nd.next) {
        if (n == out.len) break;
        const thread: *proc.Thread = @fieldParentPtr("sched_node", nd);
        out[n] = .{
            .tid = thread.tid,
            .pid = thread.parent.pid,
            .status = thread.status,
        };
        n += 1;
    }
    return n;
}

pub fn startKernelThread(parent: *proc.Process, pc: usize, arg: usize, enqueue: bool) !*proc.Thread {
    const thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const kstack = try allocKernelStack();
    errdefer freeKernelStack(kstack.phys, kstack.base);

    thread.* = .{
        .tid = 0,
        .status = .ready,
        .parent = parent,
        .stack_phys = kstack.phys,
        .stack_base = kstack.base,
        .proc_node = .{},
        .sched_node = .{},
        .on_runqueue = false,
    };

    // Fake a `call` so a `ret` panics instead of running off the stack, and so
    // SysV entry alignment is rsp ≡ 8 (mod 16).
    const stack: [*]u64 = @ptrFromInt(kstack.base);
    const slots = stack_size / @sizeOf(u64);
    stack[slots - 1] = @intFromPtr(&kernelThreadReturned);

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.kernel_data_sel;
    thread.ctx.rip = @intCast(pc);
    thread.ctx.rdi = @intCast(arg);
    thread.ctx.rsp = @intCast(kstack.base + stack_size - @sizeOf(u64));

    lock.lock();
    defer lock.unlock();
    thread.tid = tid_next;
    tid_next += 1;
    parent.threads.append(&thread.proc_node);
    if (enqueue) enqueueThread(thread);
    return thread;
}

pub fn startUserThread(parent: *proc.Process, pc: usize, arg: usize, enqueue: bool) !*proc.Thread {
    const thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const kstack = try allocKernelStack();
    errdefer freeKernelStack(kstack.phys, kstack.base);

    const user_stack_phys = pmm.alloc(stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(user_stack_phys, stack_pages);
    const user_stack_base = try takeUserStack(parent);
    try parent.vmm.map(
        user_stack_base,
        user_stack_phys,
        stack_size,
        .{ .present = true, .writable = true, .user = true, .noexec = true },
    );

    thread.* = .{
        .tid = 0,
        .status = .ready,
        .parent = parent,
        .stack_phys = kstack.phys,
        .stack_base = kstack.base,
        .proc_node = .{},
        .sched_node = .{},
        .on_runqueue = false,
    };

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.user_code_sel | 3;
    thread.ctx.ss = gdt.user_data_sel | 3;
    thread.ctx.rip = @intCast(pc);
    thread.ctx.rdi = @intCast(arg);
    thread.ctx.rsp = @intCast(user_stack_base + stack_size);

    lock.lock();
    defer lock.unlock();
    thread.tid = tid_next;
    tid_next += 1;
    parent.threads.append(&thread.proc_node);
    if (enqueue) enqueueThread(thread);
    return thread;
}

fn takeUserStack(parent: *proc.Process) error{OutOfMemory}!usize {
    lock.lock();
    defer lock.unlock();
    if (parent.user_stack_next < stack_size) return error.OutOfMemory;
    const base = parent.user_stack_next - stack_size;
    parent.user_stack_next = base;
    return base;
}

pub fn schedule(ctx: *cpu.Context) void {
    expectInit();
    lock.lock();
    defer lock.unlock();
    switchLocked(ctx);
}

pub fn tick(ctx: *cpu.Context) void {
    expectInit();
    lock.lock();
    defer lock.unlock();
    ticks +%= 1;
    wakeSleepers();
    switchLocked(ctx);
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

    dropAddressSpace(&process.vmm);
    process.heap.destroy(process);
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
    unreachable;
}

pub fn yield() void {
    expectInit();
    ivt.interrupt(ivt.vec_yield);
}

// Park the current thread for `ms` milliseconds. 1 kHz tick, so 1 ms = 1 tick.
pub fn sleep(ms: u64) void {
    expectInit();
    if (ms == 0) return;
    const thread = cpu.current().thread orelse @panic("sleep with no thread");

    lock.lock();
    thread.status = .sleeping;
    thread.wake_tick = ticks +| ms;
    lock.unlock();
    yield();
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

fn switchLocked(ctx: *cpu.Context) void {
    reapDoomedStack();
    reapDoomedPt();
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
    thread.parent.vmm.switchTo();
    reapDoomedPt();
    // CPL 3 → 0 loads RSP from here. Absolute top; ctx.rsp is the thread's SP.
    this_cpu.tss.rsp[0] = @intCast(thread.stack_base + stack_size);
    ctx.* = thread.ctx;
}

fn wakeSleepers() void {
    var node = threads.first;
    while (node) |n| {
        const thread: *proc.Thread = @fieldParentPtr("sched_node", n);
        if (thread.status == .sleeping and ticks >= thread.wake_tick) {
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
    thread.parent.threads.remove(&thread.proc_node);

    const stack_phys = thread.stack_phys;
    const stack_base = thread.stack_base;
    const parent_heap = thread.parent.heap;
    const this_cpu = cpu.current();
    const is_current = this_cpu.thread == thread;
    if (is_current) this_cpu.thread = null;

    parent_heap.destroy(thread);

    if (is_current) {
        deferStackFree(stack_phys, stack_base);
    } else {
        freeKernelStack(stack_phys, stack_base);
    }
}

fn dropAddressSpace(space: *vmm.VMM) void {
    if (space.isCurrent()) {
        deferPtFree(space.pt_addr_phys);
    } else {
        space.destroy();
    }
}

fn deferStackFree(stack_phys: usize, stack_base: usize) void {
    if (doomed_stack) |old| {
        freeKernelStack(old.phys, old.base);
    }
    doomed_stack = .{ .phys = stack_phys, .base = stack_base };
}

fn reapDoomedStack() void {
    const doomed = doomed_stack orelse return;
    if (rspInStack(doomed.base)) return;
    doomed_stack = null;
    freeKernelStack(doomed.phys, doomed.base);
}

fn deferPtFree(pt_phys: usize) void {
    if (doomed_pt_phys) |old| {
        vmm.destroyPhys(old);
    }
    doomed_pt_phys = pt_phys;
}

fn reapDoomedPt() void {
    const phys = doomed_pt_phys orelse return;
    if (vmm.readCR3() == phys) return;
    doomed_pt_phys = null;
    vmm.destroyPhys(phys);
}

fn rspInStack(stack_base: usize) bool {
    const rsp = asm volatile (
        \\movq %%rsp, %[rsp]
        : [rsp] "=r" (-> usize),
    );
    return rsp >= stack_base and rsp < stack_base + stack_size;
}

const KernelStack = struct { phys: usize, base: usize };

fn allocKernelStack() !KernelStack {
    const phys = pmm.alloc(stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(phys, stack_pages);
    const base = try takeKernelStackSlot();
    try vmm.kernel_vmm.map(base, phys, stack_size, .{
        .present = true,
        .writable = true,
        .noexec = true,
    });
    return .{ .phys = phys, .base = base };
}

fn freeKernelStack(phys: usize, base: usize) void {
    vmm.kernel_vmm.unmap(base, stack_size) catch @panic("unmap kernel stack");
    pmm.free(phys, stack_pages);
}

fn takeKernelStackSlot() error{OutOfMemory}!usize {
    lock.lock();
    defer lock.unlock();
    if (kstack_next >= kstack_region_end or kstack_region_end - kstack_next < kstack_slot) {
        return error.OutOfMemory;
    }
    const slot = kstack_next;
    kstack_next += kstack_slot;
    return slot + pmm.page_size;
}

/// True when `addr` is the unmapped page under a kernel stack.
pub fn isKernelStackGuard(addr: usize) bool {
    if (addr < kstack_region_base or addr >= kstack_next) return false;
    const off = addr - kstack_region_base;
    return off % kstack_slot < pmm.page_size;
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
