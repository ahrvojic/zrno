const logger = std.log.scoped(.sched);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const virt = @import("../lib/virt.zig");

const stack_size: u64 = 4096;

var processes: std.DoublyLinkedList(void) = .{};
var threads: std.DoublyLinkedList(void) = .{};

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
        .heap = allocator,
        .threads = .{},
        .node = .{ .data = {} }
    };

    if (enqueue) {
        processes.append(&process.node);
    }

    return process;
}

pub fn startKernelThread(parent: *proc.Process, pc: u64, arg: u64, enqueue: bool) !*proc.Thread {
    var thread = try parent.heap.create(proc.Thread);
    errdefer parent.heap.destroy(thread);

    const stack_phys = pmm.alloc(stack_size / pmm.page_size) orelse return error.OutOfMemory;
    const stack_virt = virt.toHH(u64, stack_phys);

    thread.* = .{
        .tid = @atomicRmw(u64, &tid_next, .Add, 1, .acq_rel),
        .parent = parent,
        .node = .{ .data = {} },
    };

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.tss_sel;
    thread.ctx.rip = pc;
    thread.ctx.rdi = arg;
    thread.ctx.rsp = stack_virt + stack_size;

    parent.threads.append(&thread.node);

    if (enqueue) {
        threads.append(&thread.node);
    }

    return thread;
}

pub fn schedule(ctx: *cpu.Context) void {
    _ = ctx;
    // TODO
}

fn idleThread() callconv(.Naked) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
