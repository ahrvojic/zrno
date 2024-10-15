const logger = std.log.scoped(.sched);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const gdt = @import("../sys/gdt.zig");
const proc = @import("proc.zig");
const vmm = @import("../mm/vmm.zig");

var processes = std.DoublyLinkedList(proc.Process);

var kernel_thread: proc.Thread = undefined;
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

    idle_thread = .{
        .tid = @atomicRmw(u64, &tid_next, .Add, 1, .acq_rel),
        .parent = &kernel_process,
    };

    idle_thread.ctx.iret_rip = @intFromPtr(&idleThread);
    idle_thread.ctx.iret_flags = 0x202;
    idle_thread.ctx.iret_cs = gdt.kernel_code_sel;
    idle_thread.ctx.iret_ss = gdt.tss_sel;
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
