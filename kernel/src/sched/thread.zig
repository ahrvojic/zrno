const std = @import("std");

const aspace = @import("aspace.zig");
const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const kstack = @import("kstack.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const state = @import("state.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const user_stack_flags = vmm.Flags{
    .present = true,
    .writable = true,
    .user = true,
    .noexec = true,
};

pub fn startKernelThread(parent: *proc.Process, pc: usize, arg: usize, enqueue: bool) !*proc.Thread {
    const thread = try allocKthread(parent);
    errdefer abandonKthread(thread);

    // Fake a `call` so a `ret` panics instead of running off the stack, and so
    // SysV entry alignment is rsp ≡ 8 (mod 16).
    const stack_ptr: [*]u64 = @ptrFromInt(thread.stack_base);
    const slots = state.stack_size / @sizeOf(u64);
    stack_ptr[slots - 1] = @intFromPtr(&kernelThreadReturned);

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.kernel_data_sel;
    thread.ctx.rip = @intCast(pc);
    thread.ctx.rdi = @intCast(arg);
    thread.ctx.rsp = @intCast(thread.stack_base + state.stack_size - @sizeOf(u64));

    publishThread(parent, thread, enqueue);
    return thread;
}

pub fn startUserThread(parent: *proc.Process, pc: usize, argv: []const []const u8, enqueue: bool) !*proc.Thread {
    const thread = try allocKthread(parent);
    errdefer abandonKthread(thread);

    const user_stack_phys = pmm.alloc(state.stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(user_stack_phys, state.stack_pages);
    const user_stack_base = try aspace.takeUserStack(parent);
    errdefer aspace.giveUserStack(parent, user_stack_base);

    try setupUserImage(&parent.vmm, user_stack_phys, user_stack_base, pc, argv, &thread.ctx);

    publishThread(parent, thread, enqueue);
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
    state.expectInit();
    const thread = cpu.current().thread orelse @panic("exec with no thread");
    if (thread.parent != process) @panic("exec of other process");
    if (process.pid == state.kernel_pid) @panic("exec kernel process");

    const user_stack_phys = pmm.alloc(state.stack_pages) orelse return error.OutOfMemory;
    errdefer pmm.free(user_stack_phys, state.stack_pages);

    var space = new_vmm;
    const user_stack_base = state.user_stack_top - state.stack_size;
    try setupUserImage(&space, user_stack_phys, user_stack_base, entry, argv, ctx);

    state.lock.lock();
    var node = process.threads.first;
    while (node) |n| {
        const t: *proc.Thread = @fieldParentPtr("proc_node", n);
        node = n.next;
        if (t != thread) stop(t);
    }

    var old = process.vmm;
    process.vmm = space;
    process.user_stack_next = state.user_stack_top - state.user_stack_slot;
    process.mmap_next = state.user_mmap_top;
    process.brk_start = image_brk;
    process.brk = image_brk;
    thread.ctx = ctx.*;
    cpu.initFpuState(thread.fpu);
    state.lock.unlock();

    process.vmm.switchTo();
    cpu.restoreFpu(thread.fpu);
    aspace.dropAddressSpace(&old);
}

fn allocKthread(parent: *proc.Process) !*proc.Thread {
    const allocator = heap.kernel_heap.allocator();
    const thread = try allocator.create(proc.Thread);
    errdefer allocator.destroy(thread);
    const stack = try kstack.alloc();
    errdefer kstack.free(stack.phys, stack.base);
    const fpu_state = try allocator.create(cpu.FpuState);
    errdefer allocator.destroy(fpu_state);
    cpu.initFpuState(fpu_state);
    thread.* = .{
        .tid = 0,
        .status = .ready,
        .parent = parent,
        .fpu = fpu_state,
        .stack_phys = stack.phys,
        .stack_base = stack.base,
        .proc_node = .{},
        .sched_node = .{},
        .on_runqueue = false,
    };
    return thread;
}

fn abandonKthread(thread: *proc.Thread) void {
    heap.kernel_heap.allocator().destroy(thread.fpu);
    kstack.free(thread.stack_phys, thread.stack_base);
    heap.kernel_heap.allocator().destroy(thread);
}

fn publishThread(parent: *proc.Process, thread: *proc.Thread, enqueue: bool) void {
    state.lock.lock();
    defer state.lock.unlock();
    thread.tid = state.tid_next;
    state.tid_next += 1;
    parent.threads.append(&thread.proc_node);
    if (enqueue) state.enqueueThread(thread);
}

fn setupUserImage(
    space: *vmm.VMM,
    stack_phys: usize,
    stack_base: usize,
    pc: usize,
    argv: []const []const u8,
    ctx: *cpu.Context,
) !void {
    // Page below `stack_base` is the slot guard; left unmapped.
    try space.map(stack_base, stack_phys, state.stack_size, user_stack_flags);
    errdefer space.unmap(stack_base, state.stack_size) catch {};
    const frame = try setupUserArgv(stack_phys, stack_base, argv);
    applyUserRegs(ctx, pc, frame);
}

// Caller holds `state.lock`.
pub fn stop(thread: *proc.Thread) void {
    thread.status = .stopped;
    thread.wait_chan = null;
    state.dequeueThread(thread);
    thread.parent.threads.remove(&thread.proc_node);

    const stack_phys = thread.stack_phys;
    const stack_base = thread.stack_base;
    const fpu_state = thread.fpu;
    const this_cpu = cpu.current();
    const is_current = this_cpu.thread == thread;
    if (is_current) this_cpu.thread = null;

    const allocator = heap.kernel_heap.allocator();
    allocator.destroy(fpu_state);
    allocator.destroy(thread);

    if (is_current) {
        kstack.deferFree(stack_phys, stack_base);
    } else {
        kstack.freeLocked(stack_phys, stack_base);
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
    ctx.rdi = frame.argv_va;
    ctx.rsi = frame.argc;
    ctx.rsp = frame.rsp;
}

// argv is `{ptr,len}` slices on the stack; rdi=ptr, rsi=count. No NULs.
fn setupUserArgv(stack_phys: usize, stack_va: usize, argv: []const []const u8) error{OutOfMemory}!ArgvFrame {
    const mem = virt.toHH([*]u8, stack_phys)[0..state.stack_size];
    var off: usize = state.stack_size;

    var strs: [state.max_argv]struct { va: usize, len: usize } = undefined;
    if (argv.len > strs.len) return error.OutOfMemory;
    for (argv, 0..) |arg, i| {
        if (off < arg.len) return error.OutOfMemory;
        off -= arg.len;
        @memcpy(mem[off..][0..arg.len], arg);
        strs[i] = .{ .va = stack_va + off, .len = arg.len };
    }

    off &= ~@as(usize, 15);
    const table_bytes = argv.len * 16;
    if (off < table_bytes) return error.OutOfMemory;
    off -= table_bytes;

    const argv_va = stack_va + off;
    var p = off;
    for (strs[0..argv.len]) |s| {
        writeU64(mem, p, s.va);
        writeU64(mem, p + 8, s.len);
        p += 16;
    }

    return .{
        .rsp = @intCast(stack_va + off),
        .argc = argv.len,
        .argv_va = @intCast(argv_va),
    };
}

fn writeU64(mem: []u8, off: usize, value: usize) void {
    std.mem.writeInt(u64, mem[off..][0..8], @intCast(value), .little);
}

fn kernelThreadReturned() callconv(.c) noreturn {
    @panic("kernel thread returned");
}
