const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const file = @import("../fs/file.zig");
const maplist = @import("maplist.zig");
const vfs = @import("../fs/vfs.zig");
const vmm = @import("../mm/vmm.zig");

// Last component of the spawn path, cut to this. `ps` copies it into the row.
pub const ps_name_max: usize = 24;

pub const Process = struct {
    pid: u64,
    parent: u64,
    // Exited; stays on the table until wait/reap.
    zombie: bool,
    vmm: vmm.VMM,
    node: std.DoublyLinkedList.Node,
    on_proctable: bool,
    exit_code: u8,
    // Exclusive top of the next user-stack slot (mapped pages + guard
    // below). Grows down from `elf.user_stack_top`.
    user_stack_next: usize,
    // Exclusive top of the next anonymous mmap. Grows down from
    // `elf.user_mmap_top`. `maps` are the live ranges; a hole is not reused.
    mmap_next: usize,
    maps: maplist.List = .{},
    // Program break: exclusive end of the data/heap segment. `brk_start` is
    // the page-aligned end of the loaded image; `brk` may grow up to mmap.
    brk_start: usize,
    brk: usize,
    // Spawn installs 0/1/2 from the caller's fds. Kernel pid 0 has none;
    // `/init` (spawned from the kernel) gets a shared TTY.
    fds: [file.max_fds]file.Fd,
    // Retained directory. A path that does not begin with `/` starts here.
    // Spawn copies the parent's node. Exit releases it.
    cwd: *vfs.Node,
    // Last component of the spawn path. The kernel process is `idle`.
    name_len: u8 = 0,
    name: [ps_name_max]u8 = @splat(0),

    pub fn setName(self: *Process, name: []const u8) void {
        const n = @min(name.len, ps_name_max);
        @memset(self.name[0..], 0);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = @intCast(n);
    }
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
    // Set while this thread is inside poll. A broadcast wakeup readies it;
    // poll rechecks the descriptors. Not a stack slice.
    polling: bool = false,
    wake_tick: u64 = 0,
    stack_phys: usize,
    // Mapped VA of the kernel stack (guard page is the page below).
    stack_base: usize,
    // User stack VA. 0 for a kernel thread. Process exit drops it with the
    // address space; `thread_exit` unmaps it while siblings remain.
    user_stack: usize = 0,
    // Extra file ref across a pipe read or write. `stop` releases it: the
    // syscall `defer` does not run when the waiter is killed.
    held_file: ?*file.File = null,
    /// 1 when this thread is still current on another core. That core frees
    /// the object after it has left the address space.
    stopped: std.atomic.Value(u8) = .init(0),
    sched_node: std.DoublyLinkedList.Node,
    on_runqueue: bool,

    pub fn holdFile(self: *Thread, f: *file.File) void {
        if (self.held_file != null) @panic("file already held");
        f.retain();
        self.held_file = f;
    }

    pub fn releaseHeld(self: *Thread) void {
        const held = self.held_file orelse return;
        self.held_file = null;
        held.release();
    }
};
