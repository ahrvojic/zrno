const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const heap = @import("../mm/heap.zig");
const vmm = @import("../mm/vmm.zig");

pub const max_fds: usize = 16;

pub const OpenFile = struct {
    bytes: []const u8,
    pos: usize,
};

// Shared open-file description. Fd table slots point here; `dup` retains.
pub const File = struct {
    refs: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        tty,
        file: OpenFile,
    };

    pub fn create(kind: Kind) error{OutOfMemory}!*File {
        const f = try heap.kernel_heap.allocator().create(File);
        f.* = .{ .refs = 1, .kind = kind };
        return f;
    }

    pub fn retain(self: *File) void {
        self.refs += 1;
    }

    pub fn release(self: *File) void {
        if (self.refs == 0) @panic("file refcount underflow");
        self.refs -= 1;
        if (self.refs == 0) {
            heap.kernel_heap.allocator().destroy(self);
        }
    }
};

pub const Fd = ?*File;

pub fn installStdio(fds: *[max_fds]Fd) error{OutOfMemory}!void {
    const tty = try File.create(.tty);
    tty.retain();
    tty.retain();
    fds[0] = tty;
    fds[1] = tty;
    fds[2] = tty;
}

pub fn inherit(dst: *[max_fds]Fd, src: *const [max_fds]Fd) void {
    for (dst, src) |*d, s| {
        if (s) |f| {
            f.retain();
            d.* = f;
        }
    }
}

pub fn closeAll(fds: *[max_fds]Fd) void {
    for (fds) |*slot| {
        if (slot.*) |f| {
            slot.* = null;
            f.release();
        }
    }
}

pub const Process = struct {
    pid: u64,
    parent: u64,
    // Exited; stays on the table until wait/reap.
    zombie: bool,
    heap: std.mem.Allocator,
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
    // Inherited at spawn. Kernel and init: 0/1/2 share one TTY.
    fds: [max_fds]Fd,
};

pub const ThreadStatus = enum {
    ready,
    running,
    sleeping,
    waiting,
    stopped,
};

pub const Thread = struct {
    tid: u64,
    status: ThreadStatus,
    parent: *Process,
    ctx: cpu.Context = .{},
    wait_chan: ?*const anyopaque = null,
    wake_tick: u64 = 0,
    stack_phys: usize,
    // Mapped VA of the kernel stack (guard page is the page below).
    stack_base: usize,
    proc_node: std.DoublyLinkedList.Node,
    sched_node: std.DoublyLinkedList.Node,
    on_runqueue: bool,
};
