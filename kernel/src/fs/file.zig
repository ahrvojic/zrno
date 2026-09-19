const heap = @import("../mm/heap.zig");
const pipe = @import("pipe.zig");

pub const max_fds: usize = 16;

pub const OpenFile = struct {
    bytes: []const u8,
    pos: usize,
};

pub const OpenDir = struct {
    pos: usize,
};

// Shared open-file description. Fd table slots point here; spawn retains.
pub const File = struct {
    refs: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        tty,
        file: OpenFile,
        dir: OpenDir,
        pipe_read: *pipe.Pipe,
        pipe_write: *pipe.Pipe,
    };

    pub fn create(kind: Kind) error{OutOfMemory}!*File {
        const f = try heap.kernel_heap.allocator().create(File);
        f.* = .{ .refs = 1, .kind = kind };
        switch (kind) {
            .pipe_read => |p| p.readers += 1,
            .pipe_write => |p| p.writers += 1,
            .tty, .file, .dir => {},
        }
        return f;
    }

    fn retain(self: *File) void {
        self.refs += 1;
    }

    pub fn release(self: *File) void {
        if (self.refs == 0) @panic("file refcount underflow");
        self.refs -= 1;
        if (self.refs == 0) {
            switch (self.kind) {
                .pipe_read => |p| p.detachRead(),
                .pipe_write => |p| p.detachWrite(),
                .tty, .file, .dir => {},
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

// Child 0/1/2 are retains of the given parent slots.
pub fn installStdioFrom(dst: *[max_fds]Fd, src: *const [max_fds]Fd, stdio: [3]u64) error{BadFd}!void {
    var files: [3]*File = undefined;
    for (stdio, 0..) |fd, i| {
        if (fd >= max_fds) return error.BadFd;
        files[i] = src[@intCast(fd)] orelse return error.BadFd;
    }
    for (files, 0..) |f, i| {
        f.retain();
        dst[i] = f;
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
