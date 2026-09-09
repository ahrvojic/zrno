const logger = std.log.scoped(.sched);

const std = @import("std");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const cpu = @import("../sys/cpu.zig");
const elf = @import("../sys/elf.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const ivt = @import("../sys/ivt.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

pub const tick_hz: u64 = 1000;

// Kernel threads and TSS.rsp[0] (syscall/IRQ). 64 KiB covers a 1 KiB
// print buffer plus a nested IRQ frame (int 0x80 → 0x90, or timer during print).
const stack_size: usize = 16 * pmm.page_size;
const stack_pages: usize = stack_size / pmm.page_size;
const kernel_pid: u64 = 0;
const init_pid: u64 = 1;
// Exclusive top of the first user stack. Later threads grow down one
// stack_size at a time. Canonical low half (2 GiB).
const user_stack_top: usize = elf.user_stack_top;

// Kernel stacks live in the cloned higher half (not HHDM) so an unmapped
// guard page under each stack is possible. PML4 510: below the kernel
// image, above HHDM.
const kstack_region_base: usize = 0xffff_ff00_0000_0000;
const kstack_region_end: usize = kstack_region_base + (1024 * 1024 * 1024);
const kstack_slot: usize = stack_size + pmm.page_size;
// Cap on `brk - brk_start`. Prevents a single call from allocating up to the stacks.
const max_heap: usize = 32 * 1024 * 1024;
const heap_flags = vmm.Flags{ .present = true, .writable = true, .user = true, .noexec = true };

comptime {
    std.debug.assert(stack_size == elf.user_stack_window);
    std.debug.assert(user_stack_top % pmm.page_size == 0);
    std.debug.assert(user_stack_top < vmm.user_space_end);
    std.debug.assert(kstack_region_base % pmm.page_size == 0);
    std.debug.assert(kstack_slot % pmm.page_size == 0);
    std.debug.assert(kstack_region_base >= 0xffff_8000_0000_0000);
    std.debug.assert(kstack_region_end <= 0xffff_ffff_8000_0000);
}

// Processes including zombies until `waitProcess`; not a runqueue.
// `schedule` walks `threads`.
var processes: std.DoublyLinkedList = .{};
var threads: std.DoublyLinkedList = .{};

var idle_thread: *proc.Thread = undefined;

var pid_next: u64 = 0;
var tid_next: u64 = 0;

var lock: Lock.SpinLock = .{};
var initialized = false;
// First `switchLocked` still runs on the Limine stack (`thread == null`).
var limine_stack = true;

// Kernel stack of a thread that died while running on it. Unmapped and
// freed on the next `switchLocked` that is no longer executing on that stack.
const DoomedStack = struct { phys: usize, base: usize };
var doomed_stack: ?DoomedStack = null;
var kstack_next: usize = kstack_region_base;
// Recycled stack VAs below `kstack_next` (high-water; guard-page check).
const max_kstack_free = 256;
var kstack_free: BoundedArray(usize, max_kstack_free) = .{};

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
        .orphaned = false,
        .user_stack_next = user_stack_top,
        .brk_start = 0,
        .brk = 0,
        .fds = [_]proc.Fd{.empty} ** proc.max_fds,
    };

    process.fds[0] = .tty;
    process.fds[1] = .tty;
    process.fds[2] = .tty;

    if (cpu.current().thread) |thread| {
        process.parent = thread.parent.pid;
    }

    lock.lock();
    defer lock.unlock();
    process.pid = pid_next;
    pid_next += 1;
    if (enqueue) enqueueProcess(process);
    return process;
}

fn findProcessLocked(pid: u64) ?*proc.Process {
    var node = processes.first;
    while (node) |n| {
        const process: *proc.Process = @fieldParentPtr("node", n);
        if (process.pid == pid) return process;
        node = n.next;
    }
    return null;
}

// Park until a child has exited, then reap it and return its exit code.
// `pid == 0` waits for any child. Unrelated pids are ECHILD, not a hang.
pub fn waitProcess(pid: u64) error{ NoChild, Invalid }!u8 {
    expectInit();
    const thread = cpu.current().thread orelse @panic("wait with no thread");
    const waiter = thread.parent;
    if (pid == waiter.pid) return error.Invalid;

    lock.lock();
    defer lock.unlock();

    while (true) {
        if (pid == 0) {
            var live = false;
            var node = processes.first;
            while (node) |n| {
                const process: *proc.Process = @fieldParentPtr("node", n);
                node = n.next;
                if (!isWaitableChild(process, waiter.pid)) continue;
                if (process.status == .stopped) {
                    const code = process.exit_code;
                    reapLocked(process);
                    return code;
                }
                live = true;
            }
            if (!live) return error.NoChild;
            waitLocked(waiter);
            continue;
        }

        const process = findProcessLocked(pid) orelse return error.NoChild;
        if (!isWaitableChild(process, waiter.pid)) return error.NoChild;
        if (process.status == .stopped) {
            const code = process.exit_code;
            reapLocked(process);
            return code;
        }
        waitLocked(process);
    }
}

fn isWaitableChild(process: *const proc.Process, parent_pid: u64) bool {
    return process.parent == parent_pid and !process.orphaned;
}

fn startKernelThread(parent: *proc.Process, pc: usize, arg: usize, enqueue: bool) !*proc.Thread {
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

pub fn startUserThread(parent: *proc.Process, pc: usize, argv: []const []const u8, enqueue: bool) !*proc.Thread {
    const thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const kstack = try allocKernelStack();
    errdefer freeKernelStack(kstack.phys, kstack.base);

    const user_stack_phys = pmm.alloc(stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(user_stack_phys, stack_pages);
    const user_stack_base = try takeUserStack(parent);
    errdefer giveUserStack(parent, user_stack_base);
    try parent.vmm.map(
        user_stack_base,
        user_stack_phys,
        stack_size,
        .{ .present = true, .writable = true, .user = true, .noexec = true },
    );
    errdefer parent.vmm.unmap(user_stack_base, stack_size) catch {};

    const frame = try setupUserArgv(user_stack_phys, user_stack_base, argv);

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

    applyUserRegs(&thread.ctx, pc, frame);

    lock.lock();
    defer lock.unlock();
    thread.tid = tid_next;
    tid_next += 1;
    parent.threads.append(&thread.proc_node);
    if (enqueue) enqueueThread(thread);
    return thread;
}

// Replace the calling process image. Keeps pid, parent, and fds. `new_vmm`
// is taken on success; the caller must not destroy it.
pub fn execReplace(
    process: *proc.Process,
    ctx: *cpu.Context,
    new_vmm: vmm.VMM,
    entry: usize,
    image_brk: usize,
    argv: []const []const u8,
) !void {
    expectInit();
    const thread = cpu.current().thread orelse @panic("exec with no thread");
    if (thread.parent != process) @panic("exec of other process");
    if (process.pid == kernel_pid) @panic("exec kernel process");

    const user_stack_phys = pmm.alloc(stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(user_stack_phys, stack_pages);

    var space = new_vmm;
    const user_stack_base = user_stack_top - stack_size;
    try space.map(
        user_stack_base,
        user_stack_phys,
        stack_size,
        .{ .present = true, .writable = true, .user = true, .noexec = true },
    );
    errdefer space.unmap(user_stack_base, stack_size) catch {};

    const frame = try setupUserArgv(user_stack_phys, user_stack_base, argv);

    lock.lock();
    var node = process.threads.first;
    while (node) |n| {
        const t: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        if (t != thread) stopThread(t);
    }

    var old = process.vmm;
    process.vmm = space;
    process.user_stack_next = user_stack_base;
    process.brk_start = image_brk;
    process.brk = image_brk;
    applyUserRegs(ctx, entry, frame);
    thread.ctx = ctx.*;
    lock.unlock();

    process.vmm.switchTo();
    dropAddressSpace(&old);
}

fn takeUserStack(parent: *proc.Process) error{OutOfMemory}!usize {
    lock.lock();
    defer lock.unlock();
    if (parent.user_stack_next < stack_size) return error.OutOfMemory;
    const base = parent.user_stack_next - stack_size;
    if (base < parent.brk) return error.OutOfMemory;
    parent.user_stack_next = base;
    return base;
}

fn giveUserStack(parent: *proc.Process, base: usize) void {
    lock.lock();
    defer lock.unlock();
    if (parent.user_stack_next == base) {
        parent.user_stack_next = base + stack_size;
    }
}

const BrkChange = struct {
    old: usize,
    addr: usize,
    page_addr: usize,
    page_size: usize,
    grow: bool,
};

// Linux-style `brk`: rdi=0 returns the current break; otherwise set it.
// The stored break is byte-granular; mapping is page-aligned.
pub fn setBrk(addr: usize) error{ Invalid, OutOfMemory }!usize {
    expectInit();
    const thread = cpu.current().thread orelse @panic("brk with no thread");
    const process = thread.parent;

    lock.lock();
    if (addr == 0) {
        const cur = process.brk;
        lock.unlock();
        return cur;
    }
    const change: ?BrkChange = blk: {
        defer lock.unlock();
        const old = process.brk;
        if (process.brk_start == 0 or addr < process.brk_start) return error.Invalid;
        if (addr > process.user_stack_next or addr - process.brk_start > max_heap) {
            return error.OutOfMemory;
        }
        const old_pg = std.mem.alignForward(usize, old, pmm.page_size);
        const new_pg = std.mem.alignForward(usize, addr, pmm.page_size);
        process.brk = addr;
        if (old_pg == new_pg) break :blk null;
        break :blk .{
            .old = old,
            .addr = addr,
            .page_addr = if (addr > old) old_pg else new_pg,
            .page_size = if (addr > old) new_pg - old_pg else old_pg - new_pg,
            .grow = addr > old,
        };
    };

    const c = change orelse return addr;

    if (c.grow) {
        mapHeapPages(&process.vmm, c.page_addr, c.page_size) catch {
            lock.lock();
            if (process.brk == c.addr) process.brk = c.old;
            lock.unlock();
            return error.OutOfMemory;
        };
    } else {
        unmapHeapPages(&process.vmm, c.page_addr, c.page_size);
    }
    return c.addr;
}

fn mapHeapPages(space: *vmm.VMM, addr: usize, size: usize) error{OutOfMemory}!void {
    var mapped: usize = 0;
    errdefer unmapHeapPages(space, addr, mapped);
    while (mapped < size) : (mapped += pmm.page_size) {
        const phys = pmm.alloc(1) orelse return error.OutOfMemory;
        space.map(addr + mapped, phys, pmm.page_size, heap_flags) catch |err| {
            pmm.free(phys, 1);
            switch (err) {
                error.AlreadyMapped => @panic("brk already mapped"),
                else => return error.OutOfMemory,
            }
        };
    }
}

fn unmapHeapPages(space: *vmm.VMM, addr: usize, size: usize) void {
    var off: usize = 0;
    while (off < size) : (off += pmm.page_size) {
        const phys = space.virtToPhys(addr + off) catch @panic("brk unmap");
        space.unmap(addr + off, pmm.page_size) catch @panic("brk unmap");
        pmm.free(std.mem.alignBackward(usize, phys, pmm.page_size), 1);
    }
}

const ArgvFrame = struct {
    rsp: u64,
    argc: u64,
    argv_va: u64,
};

fn applyUserRegs(ctx: *cpu.Context, pc: usize, frame: ArgvFrame) void {
    ctx.* = .{};
    ctx.rflags = 0x202;
    ctx.cs = gdt.user_code_sel | 3;
    ctx.ss = gdt.user_data_sel | 3;
    ctx.rip = @intCast(pc);
    ctx.rdi = frame.argc;
    ctx.rsi = frame.argv_va;
    ctx.rsp = frame.rsp;
}

// SysV `_start`: rsp % 16 == 8, argc then argv pointers, NULL, envp NULL.
fn setupUserArgv(stack_phys: usize, stack_va: usize, argv: []const []const u8) error{OutOfMemory}!ArgvFrame {
    const mem = virt.toHH([*]u8, stack_phys)[0..stack_size];
    var off: usize = stack_size;

    var str_va: [32]usize = undefined;
    if (argv.len > str_va.len) return error.OutOfMemory;
    for (argv, 0..) |arg, i| {
        const n = arg.len + 1;
        if (off < n) return error.OutOfMemory;
        off -= n;
        @memcpy(mem[off..][0..arg.len], arg);
        mem[off + arg.len] = 0;
        str_va[i] = stack_va + off;
    }

    off &= ~@as(usize, 15);
    const words = argv.len + 3;
    const bytes = words * @sizeOf(u64);
    if (off < bytes) return error.OutOfMemory;
    off -= bytes;
    if ((stack_va + off) % 16 != 8) {
        if (off < @sizeOf(u64)) return error.OutOfMemory;
        off -= @sizeOf(u64);
    }

    writeU64(mem, off, argv.len);
    var p = off + @sizeOf(u64);
    const argv_va = stack_va + p;
    for (0..argv.len) |i| {
        writeU64(mem, p, str_va[i]);
        p += @sizeOf(u64);
    }
    writeU64(mem, p, 0);
    writeU64(mem, p + @sizeOf(u64), 0);

    return .{
        .rsp = @intCast(stack_va + off),
        .argc = argv.len,
        .argv_va = @intCast(argv_va),
    };
}

fn writeU64(mem: []u8, off: usize, value: usize) void {
    std.mem.writeInt(u64, mem[off..][0..8], @intCast(value), .little);
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

    if (process.pid == init_pid) {
        logger.err("init exited {d}", .{exit_code});
        @panic("init exited");
    }

    var node = process.threads.first;
    while (node) |n| {
        const thread: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        stopThread(thread);
    }

    dropAddressSpace(&process.vmm);

    var pnode = processes.first;
    while (pnode) |n| {
        const child: *proc.Process = @fieldParentPtr("node", n);
        pnode = n.next;
        if (child.parent != process.pid or child == process) continue;
        if (child.status == .stopped) {
            reapLocked(child);
        } else {
            child.parent = kernel_pid;
            child.orphaned = true;
        }
    }

    wakeupLocked(process);
    if (findProcessLocked(process.parent)) |parent| {
        wakeupLocked(parent);
    }

    if (process.orphaned) reapLocked(process);
}

// Interrupt-context kill: stop the running user process and overwrite `ctx`
// with the next thread. Kernel pid 0 is fatal.
pub fn killCurrent(ctx: *cpu.Context, exit_code: u8) void {
    expectInit();
    const thread = cpu.current().thread orelse @panic("kill with no thread");
    const process = thread.parent;
    if (process.pid == kernel_pid) @panic("kill kernel process");
    exitProcess(process, exit_code);
    schedule(ctx);
}

// Spawn failed before the process ran. Not exitProcess: that panics on pid 1
// ("init exited") and only reaps if orphaned. Nobody is wait()ing.
pub fn abortProcess(process: *proc.Process, exit_code: u8) void {
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

    dropAddressSpace(&process.vmm);
    reapLocked(process);
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
    wakeupLocked(chan);
}

// Caller holds `lock`. Parks, then reacquires `lock` on resume.
fn waitLocked(chan: *const anyopaque) void {
    const thread = cpu.current().thread orelse @panic("wait with no thread");
    thread.wait_chan = chan;
    thread.status = .waiting;
    lock.unlock();
    yield();
    lock.lock();
}

fn wakeupLocked(chan: *const anyopaque) void {
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

fn reapLocked(process: *proc.Process) void {
    dequeueProcess(process);
    process.heap.destroy(process);
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
        freeKernelStackLocked(stack_phys, stack_base);
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
        freeKernelStackLocked(old.phys, old.base);
    }
    doomed_stack = .{ .phys = stack_phys, .base = stack_base };
}

fn reapDoomedStack() void {
    const doomed = doomed_stack orelse return;
    if (rspInStack(doomed.base)) return;
    doomed_stack = null;
    freeKernelStackLocked(doomed.phys, doomed.base);
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

    lock.lock();
    defer lock.unlock();
    const base = try takeKernelStackSlotLocked();
    errdefer releaseKernelStackSlotLocked(base);
    try vmm.kernel_vmm.map(base, phys, stack_size, .{
        .present = true,
        .writable = true,
        .noexec = true,
    });
    return .{ .phys = phys, .base = base };
}

fn freeKernelStack(phys: usize, base: usize) void {
    unmapKernelStack(phys, base);
    lock.lock();
    defer lock.unlock();
    releaseKernelStackSlotLocked(base);
}

fn freeKernelStackLocked(phys: usize, base: usize) void {
    unmapKernelStack(phys, base);
    releaseKernelStackSlotLocked(base);
}

fn unmapKernelStack(phys: usize, base: usize) void {
    vmm.kernel_vmm.unmap(base, stack_size) catch @panic("unmap kernel stack");
    pmm.free(phys, stack_pages);
}

fn takeKernelStackSlotLocked() error{OutOfMemory}!usize {
    if (kstack_free.pop()) |base| return base;
    if (kstack_next >= kstack_region_end or kstack_region_end - kstack_next < kstack_slot) {
        return error.OutOfMemory;
    }
    const slot = kstack_next;
    kstack_next += kstack_slot;
    return slot + pmm.page_size;
}

fn releaseKernelStackSlotLocked(base: usize) void {
    const slot = base - pmm.page_size;
    if (slot + kstack_slot == kstack_next) {
        kstack_next = slot;
        while (kstack_next > kstack_region_base) {
            const top = kstack_next - kstack_slot + pmm.page_size;
            if (!removeKstackFree(top)) break;
            kstack_next -= kstack_slot;
        }
        return;
    }
    // Holes under a live high-water slot. Dropping the VA would leak the slot.
    kstack_free.append(base) catch @panic("kstack free list full");
}

fn removeKstackFree(base: usize) bool {
    for (kstack_free.constSlice(), 0..) |b, i| {
        if (b == base) {
            _ = kstack_free.swapRemove(i);
            return true;
        }
    }
    return false;
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
