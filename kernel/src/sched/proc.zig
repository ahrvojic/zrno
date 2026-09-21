const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const file = @import("../fs/file.zig");
const vmm = @import("../mm/vmm.zig");

pub const Process = struct {
    pid: u64,
    parent: u64,
    // Exited; stays on the table until wait/reap.
    zombie: bool,
    vmm: vmm.VMM,
    threads: std.DoublyLinkedList,
    node: std.DoublyLinkedList.Node,
    on_proctable: bool,
    exit_code: u8,
    // Exclusive top of the next user-stack slot (mapped pages + guard
    // below). Grows down from `elf.user_stack_top`.
    user_stack_next: usize,
    // Exclusive top of the next anonymous mmap. Grows down from
    // `elf.user_mmap_top`.
    mmap_next: usize,
    // Program break: exclusive end of the data/heap segment. `brk_start` is
    // the page-aligned end of the loaded image; `brk` may grow up to mmap.
    brk_start: usize,
    brk: usize,
    // Spawn installs 0/1/2 from the caller's fds. Kernel pid 0 has none;
    // `/init` (spawned from the kernel) gets a shared TTY.
    fds: [file.max_fds]file.Fd,
};

pub const ThreadStatus = enum {
    ready,
    running,
    sleeping,
    waiting,
};

pub const Thread = struct {
    tid: u64,
    status: ThreadStatus,
    parent: *Process,
    ctx: cpu.Context = .{},
    // Separate 64-byte-aligned XSAVE image. Inline would raise Thread
    // alignment and break `@fieldParentPtr` from the list nodes.
    fpu: *cpu.FpuState,
    wait_chan: ?*const anyopaque = null,
    wake_tick: u64 = 0,
    stack_phys: usize,
    // Mapped VA of the kernel stack (guard page is the page below).
    stack_base: usize,
    proc_node: std.DoublyLinkedList.Node,
    sched_node: std.DoublyLinkedList.Node,
    on_runqueue: bool,
};
