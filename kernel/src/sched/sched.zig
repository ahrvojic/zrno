const logger = std.log.scoped(.sched);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const stack_size: u64 = 4096;

var processes = std.DoublyLinkedList(proc.Process);

var idle_thread: proc.Thread = undefined;

var pid_next: u64 = 1;
var tid_next: u64 = 0;

var kernel_process: proc.Process = .{
    .pid = 0,
    .threads = .{},
    .vmm = undefined,
};

pub fn init() !void {
    kernel_process.vmm = &vmm.kernel_vmm;
    idle_thread = try newKernelThread(&kernel_process, @intFromPtr(&idleThread), 0);
}

pub fn newKernelThread(parent: *proc.Process, pc: u64, arg: u64) !proc.Thread {
    const stack_phys = pmm.alloc(stack_size / pmm.page_size) orelse return error.OutOfMemory;
    const stack_virt = virt.toHH(u64, stack_phys);

    var thread: proc.Thread = .{
        .tid = @atomicRmw(u64, &tid_next, .Add, 1, .acq_rel),
        .parent = parent,
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
