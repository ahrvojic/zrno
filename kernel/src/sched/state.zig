const std = @import("std");

const elf = @import("../sys/elf.zig");
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("proc.zig");
const vmm = @import("../mm/vmm.zig");

pub const tick_hz: u64 = 1000;

// Kernel threads and TSS.rsp[0] (SYSCALL/IRQ). 64 KiB covers a 1 KiB
// print buffer plus a nested IRQ frame (SYSCALL → int 0x90, or timer during print).
pub const stack_size: usize = 16 * pmm.page_size;
pub const stack_pages: usize = stack_size / pmm.page_size;
pub const kernel_pid: u64 = 0;
pub const init_pid: u64 = 1;
// Exclusive top of the first user-stack slot. Later threads grow down
// one slot (mapped stack + guard) at a time, from the top of the user half.
pub const user_stack_top: usize = elf.user_stack_top;
pub const user_stack_slot: usize = elf.user_stack_slot;
pub const user_mmap_top: usize = elf.user_mmap_top;

comptime {
    std.debug.assert(stack_size == elf.user_stack_window);
    std.debug.assert(user_stack_slot == stack_size + pmm.page_size);
    std.debug.assert(user_stack_top % pmm.page_size == 0);
    std.debug.assert(user_stack_top <= vmm.user_space_end);
    std.debug.assert(user_mmap_top % pmm.page_size == 0);
    std.debug.assert(user_mmap_top < user_stack_top);
}

// Processes including zombies until `waitProcess`; not a runqueue.
// `schedule` walks `threads`.
pub var processes: std.DoublyLinkedList = .{};
pub var threads: std.DoublyLinkedList = .{};

pub var idle_thread: *proc.Thread = undefined;

pub var pid_next: u64 = 0;
pub var tid_next: u64 = 0;

pub var lock: Lock.SpinLock = .{};
pub var initialized = false;

pub fn expectInit() void {
    if (!initialized) @panic("sched used before init");
}

pub fn expectUninit() void {
    if (initialized) @panic("sched already initialized");
}

pub fn enqueueProcess(process: *proc.Process) void {
    if (process.on_proctable) return;
    processes.append(&process.node);
    process.on_proctable = true;
}

pub fn dequeueProcess(process: *proc.Process) void {
    if (!process.on_proctable) return;
    processes.remove(&process.node);
    process.on_proctable = false;
}

pub fn enqueueThread(thread: *proc.Thread) void {
    threads.append(&thread.sched_node);
    thread.on_runqueue = true;
}

pub fn dequeueThread(thread: *proc.Thread) void {
    if (!thread.on_runqueue) return;
    threads.remove(&thread.sched_node);
    thread.on_runqueue = false;
}
