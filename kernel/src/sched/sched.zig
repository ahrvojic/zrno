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
var kernel_process: proc.Process = undefined;
var idle_thread: *proc.Thread = undefined;

var pid_next: u64 = 1;
var tid_next: u64 = 0;

pub fn init() !void {
    kernel_process = .{
        .pid = 0,
        .heap = heap.kernel_heap.allocator(),
        .threads = .{},
        .node = .{ .data = {} }
    };

    idle_thread = try newKernelThread(@intFromPtr(&idleThread), 0);
    kernel_process.threads.append(&idle_thread.node);
}

pub fn newKernelThread(pc: u64, arg: u64) !*proc.Thread {
    const stack_phys = pmm.alloc(stack_size / pmm.page_size) orelse return error.OutOfMemory;
    const stack_virt = virt.toHH(u64, stack_phys);

    var thread = try kernel_process.heap.create(proc.Thread);
    errdefer kernel_process.heap.destroy(thread);

    thread.* = .{
        .tid = @atomicRmw(u64, &tid_next, .Add, 1, .acq_rel),
        .parent = &kernel_process,
        .node = .{ .data = {} },
    };

    thread.ctx.rflags = 0x202;
    thread.ctx.cs = gdt.kernel_code_sel;
    thread.ctx.ss = gdt.tss_sel;
    thread.ctx.rip = pc;
    thread.ctx.rdi = arg;
    thread.ctx.rsp = stack_virt + stack_size;

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
