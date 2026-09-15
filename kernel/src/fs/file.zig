const heap = @import("../mm/heap.zig");
const pipe = @import("pipe.zig");

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
        pipe_read: *pipe.Pipe,
        pipe_write: *pipe.Pipe,
    };

    pub fn create(kind: Kind) error{OutOfMemory}!*File {
        const f = try heap.kernel_heap.allocator().create(File);
        f.* = .{ .refs = 1, .kind = kind };
        switch (kind) {
            .pipe_read => |p| p.readers += 1,
            .pipe_write => |p| p.writers += 1,
            .tty, .file => {},
        }
        return f;
    }

    pub fn retain(self: *File) void {
        self.refs += 1;
    }

    pub fn release(self: *File) void {
        if (self.refs == 0) @panic("file refcount underflow");
        self.refs -= 1;
        if (self.refs == 0) {
            switch (self.kind) {
                .pipe_read => |p| p.detachRead(),
                .pipe_write => |p| p.detachWrite(),
                .tty, .file => {},
            }
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
