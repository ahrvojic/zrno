//! One name tree. `/` is the initramfs: static nodes, bytes borrowed from the
//! ustar image, mounted before the heap exists. `/tmp` is a directory on the
//! block disk. The heap nodes are the live index (open files, the current
//! directory); the bytes and the names are the disk format.

const std = @import("std");

const builtin = @import("builtin");
const blk = @import("blk.zig");
const frame = @import("../mm/frame.zig");
const heap = @import("../mm/heap.zig");
const mem = @import("../lib/mem.zig");
const ustar = @import("ustar.zig");
const zrfs = @import("zrfs.zig");

const freestanding = builtin.os.tag == .freestanding;

pub const max_files: usize = 32;
pub const max_name: usize = ustar.max_name;

const block_size = mem.page_size;

const pool_len = max_files + 1;
const tmp_name = "tmp";

pub const Error = error{
    NoEnt,
    NotDir,
    IsDir,
    NotEmpty,
    ReadOnly,
    Exists,
    BadName,
    Invalid,
    TooBig,
    OutOfMemory,
    Io,
};

pub const Open = struct {
    node: *Node,
    can_write: bool,
};

/// `.write` truncates an existing file. `.keep` does not.
pub const Mode = enum { read, write, keep };

pub const Node = struct {
    refs: usize = 1,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    parent: ?*Node = null,
    next: ?*Node = null,
    child: ?*Node = null,
    /// Set for a node stored on the block disk. The root of that disk is `/tmp`.
    disk: ?*blk.Disk = null,
    ino: u32 = 0,
    kind: Kind,

    const Owned = struct {
        heap: std.mem.Allocator,
        len: usize = 0,
    };

    /// Take another reference to the cached frame for the file byte at `off`.
    /// Null when this node has no block there (a directory, an initramfs file,
    /// or a hole past the last block).
    pub fn retainPage(self: *Node, off: usize) ?*frame.Frame {
        if (comptime !freestanding) return null;
        if (self.kind != .owned) return null;
        const disk = self.disk orelse return null;
        const found = zrfs.dataBlock(disk, self.ino, off) catch return null;
        const block = found orelse return null;
        return disk.retainFrame(block) catch null;
    }

    /// `dir` null is the static initramfs. A set allocator owns the node.
    const Kind = union(enum) {
        dir: ?std.mem.Allocator,
        borrowed: []const u8,
        owned: Owned,
    };

    pub fn name(self: *const Node) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn isDir(self: *const Node) bool {
        return self.kind == .dir;
    }

    /// Initramfs bytes. An owned file is stored in pages; use `readAt`.
    pub fn bytes(self: *const Node) ?[]const u8 {
        return switch (self.kind) {
            .borrowed => |b| b,
            .owned, .dir => null,
        };
    }

    pub fn size(self: *const Node) usize {
        return switch (self.kind) {
            .borrowed => |b| b.len,
            .owned => |o| o.len,
            .dir => 0,
        };
    }

    pub fn readAt(self: *const Node, off: usize, dest: []u8) error{ Io, OutOfMemory }!usize {
        const len = self.size();
        if (off >= len) return 0;
        const n = @min(dest.len, len - off);
        if (n == 0) return 0;
        switch (self.kind) {
            .borrowed => |b| @memcpy(dest[0..n], b[off..][0..n]),
            .owned => return zrfs.read(self.disk.?, self.ino, off, dest[0..n]),
            .dir => unreachable,
        }
        return n;
    }

    pub fn childAt(self: *Node, index: usize) ?*Node {
        var i: usize = 0;
        var c = self.child;
        while (c) |n| {
            if (i == index) return n;
            i += 1;
            c = n.next;
        }
        return null;
    }

    pub fn retain(self: *Node) void {
        self.refs += 1;
    }

    pub fn release(self: *Node) void {
        if (self.refs == 0) @panic("vnode refcount underflow");
        self.refs -= 1;
        if (self.refs != 0) return;
        // A cwd can outlive rmdir and still create children. Nothing else
        // can name them, so the last reference frees that subtree. An open
        // file keeps its own node.
        if (self.isWritableDir()) self.dropChildren();
        self.discard();
    }

    fn dropChildren(self: *Node) void {
        while (self.child) |ch| {
            detach(self, ch);
            ch.release();
        }
    }

    pub fn writeAt(self: *Node, off: usize, src: []const u8) error{ ReadOnly, IsDir, TooBig, OutOfMemory, Io }!usize {
        switch (self.kind) {
            .owned => |*o| {
                const n = try zrfs.write(self.disk.?, self.ino, off, src);
                const end = off + n;
                if (end > o.len) o.len = end;
                return n;
            },
            .borrowed => return error.ReadOnly,
            .dir => return error.IsDir,
        }
    }

    fn truncate(self: *Node) void {
        switch (self.kind) {
            .owned => |*o| {
                zrfs.truncate(self.disk.?, self.ino) catch return;
                o.len = 0;
            },
            else => {},
        }
    }

    fn isWritableDir(self: *const Node) bool {
        return switch (self.kind) {
            .dir => |alloc| alloc != null,
            else => false,
        };
    }

    fn isWritableFile(self: *const Node) bool {
        return self.kind == .owned;
    }

    fn onHeap(self: *const Node) bool {
        return self.isWritableDir() or self.isWritableFile();
    }

    fn discard(self: *Node) void {
        switch (self.kind) {
            .owned => |o| {
                if (self.disk) |disk| zrfs.destroy(disk, self.ino) catch {};
                o.heap.destroy(self);
            },
            .dir => |alloc| {
                const owner = alloc orelse @panic("static vnode freed");
                if (self.child != null) @panic("freeing directory with children");
                if (self.disk) |disk| zrfs.destroy(disk, self.ino) catch {};
                owner.destroy(self);
            },
            .borrowed => @panic("static vnode freed"),
        }
    }

    fn setName(self: *Node, nam: []const u8) void {
        std.debug.assert(nam.len <= max_name);
        @memcpy(self.name_buf[0..nam.len], nam);
        self.name_len = nam.len;
    }
};

pub const Tree = struct {
    nodes: [pool_len]Node = undefined,
    len: usize = 0,
    root: ?*Node = null,
    disk: ?*blk.Disk = null,

    pub fn deinit(self: *Tree) void {
        if (self.root) |base| {
            var link: *?*Node = &base.child;
            while (link.*) |n| {
                if (n.onHeap()) {
                    link.* = n.next;
                    n.next = null;
                    freeHeap(n);
                } else {
                    link = &n.next;
                }
            }
        }
        self.root = null;
        self.len = 0;
        if (self.disk) |disk| {
            disk.deinit();
            self.disk = null;
        }
    }

    pub fn mount(self: *Tree, archive: []const u8) error{ BadTar, TooManyFiles }!void {
        self.deinit();
        errdefer self.deinit();

        const base = try self.addStatic("", .{ .dir = null });
        self.root = base;

        var it = ustar.walk(archive);
        while (try it.next()) |file| {
            if (file.name.len == 0) continue;
            if (std.mem.findScalar(u8, file.name, '/') != null) continue;
            const node = try self.addStatic(file.name, .{ .borrowed = file.data });
            addChild(base, node);
        }
    }

    pub fn mountTmp(self: *Tree, allocator: std.mem.Allocator) Error!void {
        const disk = try blk.Disk.memory(allocator, blk.mem_blocks);
        errdefer disk.deinit();
        try zrfs.format(disk);
        try self.attach(allocator, disk);
    }

    /// Takes ownership of `disk`, including on failure. A superblock with
    /// this format is kept; anything else is formatted.
    fn mountDisk(self: *Tree, allocator: std.mem.Allocator, disk: *blk.Disk) Error!void {
        errdefer disk.deinit();
        if (!try zrfs.probe(disk)) try zrfs.format(disk);
        try self.attach(allocator, disk);
    }

    fn attach(self: *Tree, allocator: std.mem.Allocator, disk: *blk.Disk) Error!void {
        const base = self.root orelse return error.NoEnt;
        if (lookupChild(base, tmp_name) != null) return error.Exists;
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .dir = allocator },
            .disk = disk,
            .ino = zrfs.root_ino,
        };
        node.setName(tmp_name);
        addChild(base, node);
        self.disk = disk;
        loadDir(node) catch |err| {
            detach(base, node);
            self.disk = null;
            dropIndex(node);
            allocator.destroy(node);
            return err;
        };
    }

    /// Drop the heap index under `/tmp` and build it again from the disk.
    fn reread(self: *Tree) Error!void {
        const base = self.root orelse return error.NoEnt;
        const tmp = lookupChild(base, tmp_name) orelse return error.NoEnt;
        if (held(tmp)) return error.Invalid;
        dropIndex(tmp);
        try loadDir(tmp);
    }

    pub fn walk(self: *Tree, path: []const u8) error{ NoEnt, NotDir }!*Node {
        const start = self.root orelse return error.NoEnt;
        return self.walkFrom(start, path);
    }

    /// A path that begins with `/` starts at the root. Any other path starts at `start`.
    pub fn walkFrom(self: *Tree, start: *Node, path: []const u8) error{ NoEnt, NotDir }!*Node {
        var node = if (path.len > 0 and path[0] == '/')
            (self.root orelse return error.NoEnt)
        else
            start;
        var rest = path;
        while (nextComponent(&rest)) |part| {
            if (!node.isDir()) return error.NotDir;
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (node.parent) |p| node = p;
                continue;
            }
            node = lookupChild(node, part) orelse return error.NoEnt;
        }
        if (endsSlash(path) and !node.isDir()) return error.NotDir;
        return node;
    }

    /// Absolute path of `node`, with no trailing slash except for `/`.
    /// A node removed while still referenced has no name to walk.
    pub fn pathOf(self: *Tree, node: *Node, out: []u8) error{ NoEnt, NameTooLong }!usize {
        const base = self.root orelse return error.NoEnt;
        if (node == base) {
            if (out.len == 0) return error.NameTooLong;
            out[0] = '/';
            return 1;
        }

        var len: usize = 0;
        var n: *Node = node;
        while (n != base) {
            const parent = n.parent orelse return error.NoEnt;
            len = std.math.add(usize, len, n.name_len + 1) catch return error.NameTooLong;
            n = parent;
        }
        if (len > out.len) return error.NameTooLong;

        var end = len;
        n = node;
        while (n != base) {
            const nam = n.name();
            end -= nam.len;
            @memcpy(out[end..][0..nam.len], nam);
            end -= 1;
            out[end] = '/';
            n = n.parent orelse return error.NoEnt;
        }
        return len;
    }

    /// `create` makes a missing file and requires `.write` or `.keep`.
    pub fn openPath(self: *Tree, path: []const u8, mode: Mode, create: bool) Error!Open {
        const start = self.root orelse return error.NoEnt;
        return self.openPathFrom(start, path, mode, create);
    }

    pub fn openPathFrom(self: *Tree, start: *Node, path: []const u8, mode: Mode, create: bool) Error!Open {
        const write_access = mode != .read;
        if (create and !write_access) return error.BadName;
        if (self.walkFrom(start, path)) |node| {
            if (node.isDir()) {
                if (write_access) return error.IsDir;
                return .{ .node = node, .can_write = false };
            }
            if (write_access) {
                if (!node.isWritableFile()) return error.ReadOnly;
                if (mode == .write) node.truncate();
                return .{ .node = node, .can_write = true };
            }
            return .{ .node = node, .can_write = false };
        } else |err| switch (err) {
            error.NotDir => return error.NotDir,
            error.NoEnt => {
                if (!create) return error.NoEnt;
                if (endsSlash(path)) return error.NotDir;
                const node = try self.createAt(start, path);
                return .{ .node = node, .can_write = true };
            },
        }
    }

    pub fn unlinkPath(self: *Tree, path: []const u8) Error!void {
        const start = self.root orelse return error.NoEnt;
        return self.unlinkPathFrom(start, path);
    }

    pub fn unlinkPathFrom(self: *Tree, start: *Node, path: []const u8) Error!void {
        const at = try self.parentName(start, path);
        const child = lookupChild(at.parent, at.name) orelse return error.NoEnt;
        if (endsSlash(path) and !child.isDir()) return error.NotDir;
        if (child.isDir()) return error.IsDir;
        if (!child.isWritableFile() or !at.parent.isWritableDir()) return error.ReadOnly;
        try zrfs.unlinkName(child.disk.?, at.parent.ino, at.name);
        detach(at.parent, child);
        child.release();
    }

    pub fn mkdirPath(self: *Tree, path: []const u8) Error!void {
        const start = self.root orelse return error.NoEnt;
        return self.mkdirPathFrom(start, path);
    }

    pub fn mkdirPathFrom(self: *Tree, start: *Node, path: []const u8) Error!void {
        const at = try self.parentName(start, path);
        _ = try createChild(at.parent, at.name, .dir);
    }

    pub fn rmdirPath(self: *Tree, path: []const u8) Error!void {
        const start = self.root orelse return error.NoEnt;
        return self.rmdirPathFrom(start, path);
    }

    pub fn rmdirPathFrom(self: *Tree, start: *Node, path: []const u8) Error!void {
        const at = try self.parentName(start, path);
        const child = lookupChild(at.parent, at.name) orelse return error.NoEnt;
        if (!child.isDir()) return error.NotDir;
        if (child.child != null) return error.NotEmpty;
        if (!child.isWritableDir() or !at.parent.isWritableDir()) return error.ReadOnly;
        try zrfs.unlinkName(child.disk.?, at.parent.ino, at.name);
        detach(at.parent, child);
        child.release();
    }

    /// Moves a heap node. The same path is a no-op. An existing file, or an
    /// empty directory of the same kind, is replaced. A directory cannot be
    /// moved under itself.
    pub fn renamePath(self: *Tree, old_path: []const u8, new_path: []const u8) Error!void {
        const start = self.root orelse return error.NoEnt;
        return self.renamePathFrom(start, old_path, new_path);
    }

    pub fn renamePathFrom(self: *Tree, start: *Node, old_path: []const u8, new_path: []const u8) Error!void {
        const from = try self.parentName(start, old_path);
        const to = try self.parentName(start, new_path);
        const node = lookupChild(from.parent, from.name) orelse return error.NoEnt;
        if ((endsSlash(old_path) or endsSlash(new_path)) and !node.isDir()) return error.NotDir;
        if (from.parent == to.parent and std.mem.eql(u8, from.name, to.name)) return;
        if (node.isDir() and isInside(node, to.parent)) return error.Invalid;
        if (!from.parent.isWritableDir() or !to.parent.isWritableDir()) return error.ReadOnly;
        if (!node.isWritableDir() and !node.isWritableFile()) return error.ReadOnly;
        const disk = node.disk orelse return error.ReadOnly;
        if (lookupChild(to.parent, to.name)) |dest| {
            if (dest.isDir() != node.isDir()) {
                if (dest.isDir()) return error.IsDir;
                return error.NotDir;
            }
            if (dest.isDir()) {
                if (dest.child != null) return error.NotEmpty;
                if (!dest.isWritableDir()) return error.ReadOnly;
            } else if (!dest.isWritableFile()) return error.ReadOnly;
            try zrfs.unlinkName(disk, to.parent.ino, to.name);
            linkNode(disk, to.parent, to.name, node) catch |err| {
                relink(disk, to.parent, to.name, dest);
                return err;
            };
            zrfs.unlinkName(disk, from.parent.ino, from.name) catch |err| {
                _ = zrfs.unlinkName(disk, to.parent.ino, to.name) catch {};
                relink(disk, from.parent, from.name, node);
                relink(disk, to.parent, to.name, dest);
                return err;
            };
            detach(to.parent, dest);
            dest.release();
        } else {
            try linkNode(disk, to.parent, to.name, node);
            zrfs.unlinkName(disk, from.parent.ino, from.name) catch |err| {
                _ = zrfs.unlinkName(disk, to.parent.ino, to.name) catch {};
                return err;
            };
        }
        detach(from.parent, node);
        node.setName(to.name);
        addChild(to.parent, node);
    }

    fn parentName(self: *Tree, start: *Node, path: []const u8) Error!struct { parent: *Node, name: []const u8 } {
        const parts = try splitFinal(path);
        const parent = try self.walkFrom(start, parts.parent);
        if (!parent.isDir()) return error.NotDir;
        return .{ .parent = parent, .name = parts.name };
    }

    fn createAt(self: *Tree, start: *Node, path: []const u8) Error!*Node {
        const at = try self.parentName(start, path);
        return createChild(at.parent, at.name, .file);
    }

    fn addStatic(self: *Tree, nam: []const u8, kind: Node.Kind) error{TooManyFiles}!*Node {
        if (self.len >= self.nodes.len) return error.TooManyFiles;
        const node = &self.nodes[self.len];
        node.* = .{ .kind = kind };
        self.len += 1;
        node.setName(nam);
        return node;
    }
};

var tree: Tree = .{};

pub fn mount(archive: []const u8) error{ BadTar, TooManyFiles }!void {
    try tree.mount(archive);
}

pub fn mountTmp() Error!void {
    try tree.mountTmp(heap.kernel_heap.allocator());
}

pub fn mountVirtio(blocks: u32, dev: *anyopaque, read_fn: blk.ReadFn, write_fn: blk.WriteFn) Error!void {
    const disk = try blk.Disk.wrap(heap.kernel_heap.allocator(), blocks, dev, read_fn, write_fn);
    try tree.mountDisk(heap.kernel_heap.allocator(), disk);
}

pub fn sync() void {
    if (tree.disk) |disk| disk.sync();
}

pub fn root() *Node {
    return tree.root orelse @panic("vfs used before mount");
}

pub fn walkFrom(start: *Node, path: []const u8) error{ NoEnt, NotDir }!*Node {
    return tree.walkFrom(start, path);
}

pub fn pathOf(node: *Node, out: []u8) error{ NoEnt, NameTooLong }!usize {
    return tree.pathOf(node, out);
}

pub fn openPathFrom(start: *Node, path: []const u8, mode: Mode, create: bool) Error!Open {
    return tree.openPathFrom(start, path, mode, create);
}

pub fn unlinkPathFrom(start: *Node, path: []const u8) Error!void {
    try tree.unlinkPathFrom(start, path);
}

pub fn mkdirPathFrom(start: *Node, path: []const u8) Error!void {
    try tree.mkdirPathFrom(start, path);
}

pub fn rmdirPathFrom(start: *Node, path: []const u8) Error!void {
    try tree.rmdirPathFrom(start, path);
}

pub fn renamePathFrom(start: *Node, old_path: []const u8, new_path: []const u8) Error!void {
    try tree.renamePathFrom(start, old_path, new_path);
}

fn createChild(parent: *Node, nam: []const u8, kind: enum { file, dir }) Error!*Node {
    // Exists before ReadOnly, so mkdir /tmp is EEXIST.
    if (lookupChild(parent, nam) != null) return error.Exists;
    const alloc = switch (parent.kind) {
        .dir => |owner| owner orelse return error.ReadOnly,
        else => return error.NotDir,
    };
    const disk = parent.disk orelse return error.ReadOnly;
    const zk: zrfs.Kind = if (kind == .file) .file else .dir;
    const ino = try zrfs.create(disk, parent.ino, nam, zk);
    const node = makeNode(alloc, disk, zk, ino, nam, 0) catch {
        zrfs.unlinkName(disk, parent.ino, nam) catch {};
        zrfs.destroy(disk, ino) catch {};
        return error.OutOfMemory;
    };
    addChild(parent, node);
    return node;
}

fn loadDir(dir: *Node) Error!void {
    const disk = dir.disk orelse return;
    var index: usize = 0;
    while (true) : (index += 1) {
        var name_buf: [max_name]u8 = undefined;
        const ent = try zrfs.readEntry(disk, dir.ino, index, &name_buf) orelse break;
        if (ent.ino == 0) continue;
        const node = try spawnNode(dir, ent.kind, ent.ino, name_buf[0..ent.name_len]);
        addChild(dir, node);
        if (ent.kind == .dir) try loadDir(node);
    }
}

fn spawnNode(parent: *Node, kind: zrfs.Kind, ino: u32, name: []const u8) Error!*Node {
    const alloc = switch (parent.kind) {
        .dir => |owner| owner orelse return error.ReadOnly,
        else => return error.NotDir,
    };
    const disk = parent.disk orelse return error.ReadOnly;
    const len = if (kind == .file) try zrfs.byteSize(disk, ino) else 0;
    return makeNode(alloc, disk, kind, ino, name, len);
}

fn makeNode(alloc: std.mem.Allocator, disk: *blk.Disk, kind: zrfs.Kind, ino: u32, name: []const u8, len: usize) error{OutOfMemory}!*Node {
    const node = try alloc.create(Node);
    node.* = .{
        .kind = switch (kind) {
            .file => .{ .owned = .{ .heap = alloc, .len = len } },
            .dir => .{ .dir = alloc },
        },
        .disk = disk,
        .ino = ino,
    };
    node.setName(name);
    return node;
}

fn linkNode(disk: *blk.Disk, parent: *Node, name: []const u8, node: *Node) zrfs.Error!void {
    const kind: zrfs.Kind = if (node.isDir()) .dir else .file;
    try zrfs.link(disk, parent.ino, name, node.ino, kind);
}

fn relink(disk: *blk.Disk, parent: *Node, name: []const u8, node: *Node) void {
    linkNode(disk, parent, name, node) catch {};
}

fn held(dir: *Node) bool {
    var c = dir.child;
    while (c) |n| {
        if (n.refs != 1) return true;
        if (n.isDir() and held(n)) return true;
        c = n.next;
    }
    return false;
}

fn dropIndex(dir: *Node) void {
    while (dir.child) |ch| {
        detach(dir, ch);
        if (ch.isDir()) dropIndex(ch);
        const alloc = switch (ch.kind) {
            .owned => |o| o.heap,
            .dir => |owner| owner orelse unreachable,
            .borrowed => unreachable,
        };
        alloc.destroy(ch);
    }
}

fn lookupChild(node: *Node, nam: []const u8) ?*Node {
    var c = node.child;
    while (c) |n| {
        if (std.mem.eql(u8, n.name(), nam)) return n;
        c = n.next;
    }
    return null;
}

fn addChild(parent: *Node, child: *Node) void {
    std.debug.assert(parent.isDir());
    child.parent = parent;
    child.next = null;
    if (parent.child == null) {
        parent.child = child;
        return;
    }
    var tail = parent.child.?;
    while (tail.next) |n| tail = n;
    tail.next = child;
}

fn isInside(dir: *Node, node: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| {
        if (cur == dir) return true;
        n = cur.parent;
    }
    return false;
}

fn detach(parent: *Node, child: *Node) void {
    std.debug.assert(parent.isDir());
    var link: *?*Node = &parent.child;
    while (link.*) |n| {
        if (n == child) {
            link.* = n.next;
            child.next = null;
            child.parent = null;
            return;
        }
        link = &n.next;
    }
    @panic("vnode not linked");
}

fn freeHeap(node: *Node) void {
    var c = node.child;
    node.child = null;
    while (c) |ch| {
        const next = ch.next;
        freeHeap(ch);
        c = next;
    }
    node.discard();
}

fn endsSlash(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/");
}

fn nextComponent(path: *[]const u8) ?[]const u8 {
    var s = path.*;
    while (s.len > 0 and s[0] == '/') s = s[1..];
    if (s.len == 0) {
        path.* = s;
        return null;
    }
    var i: usize = 0;
    while (i < s.len and s[i] != '/') i += 1;
    const nam = s[0..i];
    path.* = s[i..];
    return nam;
}

fn splitFinal(path: []const u8) error{ IsDir, BadName }!struct { parent: []const u8, name: []const u8 } {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return error.IsDir;
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    const nam = path[start..end];
    if (nam.len == 0 or nam.len > max_name) return error.BadName;
    if (std.mem.eql(u8, nam, ".") or std.mem.eql(u8, nam, "..")) return error.BadName;
    return .{ .parent = path[0..start], .name = nam };
}

test "mount fixture tar and lookup" {
    var tar: ustar.Fixture = .{};
    tar.addFile("hello.txt", "hello from ramfs\n");
    tar.addFile("hello", "\x7fELF");
    var t: Tree = .{};
    defer t.deinit();
    try t.mount(tar.finish());

    try std.testing.expectEqualStrings("hello from ramfs\n", (try t.walk("hello.txt")).bytes().?);
    try std.testing.expectEqualStrings("\x7fELF", (try t.walk("/hello")).bytes().?);
    try std.testing.expectError(error.NoEnt, t.walk("missing"));
    try std.testing.expect((try t.walk("/")).isDir());
    try std.testing.expect((try t.walk(".")).isDir());
    try std.testing.expect((try t.walk("..")).isDir());

    try std.testing.expectEqualStrings("hello.txt", (try t.walk("/")).childAt(0).?.name());
    try std.testing.expectEqualStrings("hello", (try t.walk("/")).childAt(1).?.name());
    try std.testing.expect((try t.walk("/")).childAt(2) == null);
}

test "mount rejects more than max_files" {
    var tar: ustar.Archive(max_files + 3) = .{};
    var names: [max_files + 1][2]u8 = undefined;
    for (&names, 0..) |*nam, i| {
        nam.* = .{ @intCast('a' + i / 26), @intCast('a' + i % 26) };
        tar.addFile(nam, "");
    }
    var t: Tree = .{};
    defer t.deinit();
    try std.testing.expectError(error.TooManyFiles, t.mount(tar.finish()));
    try std.testing.expectError(error.NoEnt, t.walk("aa"));
}

test "mount drops a partial table on BadTar" {
    var tar: ustar.Fixture = .{};
    tar.addFile("init", "elf");
    tar.addFile("tail", "x");
    const archive = tar.finish();
    var t: Tree = .{};
    defer t.deinit();
    try std.testing.expectError(error.BadTar, t.mount(archive[0 .. ustar.block_size * 3]));
    try std.testing.expectError(error.NoEnt, t.walk("init"));
}

fn textOf(node: *Node, buf: []u8) []const u8 {
    const n = node.readAt(0, buf) catch unreachable;
    return buf[0..n];
}

// Borrowed initramfs bytes point into `tar`, so it must outlive `t`.
fn mountFixture(t: *Tree, tar: *ustar.Fixture) !void {
    tar.addFile("init", "elf");
    try t.mount(tar.finish());
    try t.mountTmp(std.testing.allocator);
}

test "tmp bytes survive a reread, including a block boundary" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    try t.mkdirPath("/tmp/d");
    var page: [block_size]u8 = undefined;
    @memset(&page, 'a');
    const created = try t.openPath("/tmp/d/a", .write, true);
    _ = try created.node.writeAt(0, &page);
    _ = try created.node.writeAt(block_size, "bbbb");
    try t.reread();

    var across: [8]u8 = undefined;
    const node = try t.walk("/tmp/d/a");
    const n = node.readAt(block_size - 4, &across) catch unreachable;
    try std.testing.expectEqualStrings("aaaabbbb", across[0..n]);
    try t.unlinkPath("/tmp/d/a");
    try t.reread();
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/d/a"));
    try std.testing.expect((try t.walk("/tmp/d")).isDir());
}

test "tmp creates, writes, and unlinks" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    try std.testing.expectEqualStrings("tmp", (try t.walk("/")).childAt(1).?.name());
    try std.testing.expectError(error.ReadOnly, t.openPath("/init", .write, true));
    try std.testing.expectError(error.ReadOnly, t.openPath("/new", .write, true));
    try std.testing.expectError(error.ReadOnly, t.unlinkPath("/init"));
    try std.testing.expectError(error.IsDir, t.unlinkPath("/tmp"));
    try std.testing.expectError(error.IsDir, t.unlinkPath("/"));
    try std.testing.expectError(error.NoEnt, t.openPath("/tmp/missing", .write, false));

    var buf: [8]u8 = undefined;
    const created = try t.openPath("/tmp/a", .write, true);
    _ = try created.node.writeAt(0, "hello");
    try std.testing.expectEqualStrings("hello", textOf(try t.walk("/tmp/a"), &buf));
    try std.testing.expectError(error.NotDir, t.openPath("/tmp/a/", .write, true));
    try std.testing.expectEqualStrings("hello", textOf(created.node, &buf));
    try std.testing.expectError(error.NotDir, t.openPath("/tmp/new/", .write, true));
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/new"));
    try std.testing.expectError(error.NotDir, t.unlinkPath("/tmp/a/"));
    try std.testing.expectError(error.NotDir, t.renamePath("/tmp/a", "/tmp/b/"));

    const again = try t.openPath("/tmp/a", .write, false);
    try std.testing.expectEqual(@as(usize, 0), again.node.size());
    _ = try again.node.writeAt(0, "hi");
    try std.testing.expectEqualStrings("hi", textOf(again.node, &buf));
    try std.testing.expectError(error.TooBig, again.node.writeAt(3, "z"));

    const kept = try t.openPath("/tmp/a", .keep, false);
    try std.testing.expectEqualStrings("hi", textOf(kept.node, &buf));

    again.node.retain();
    try t.unlinkPath("/tmp/a");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/a"));
    try std.testing.expectEqualStrings("hi", textOf(again.node, &buf));
    again.node.release();

    try std.testing.expectError(error.NotDir, t.walk("/init/x"));
    try std.testing.expectError(error.NotDir, t.walk("/init/.."));
    try std.testing.expectEqualStrings("elf", (try t.walk("/tmp/../init")).bytes().?);
}

test "tmp directories nest, and rmdir refuses a non-empty dir" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    try t.mkdirPath("/tmp/a");
    try t.mkdirPath("/tmp/a/b");
    const created = try t.openPath("/tmp/a/b/c", .write, true);
    _ = try created.node.writeAt(0, "x");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", textOf(try t.walk("/tmp/a/b/c"), &buf));

    try std.testing.expectError(error.NotEmpty, t.rmdirPath("/tmp/a/b"));
    try std.testing.expectError(error.NotDir, t.rmdirPath("/tmp/a/b/c"));
    try t.unlinkPath("/tmp/a/b/c");
    try t.rmdirPath("/tmp/a/b");
    try t.rmdirPath("/tmp/a");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/a"));

    try std.testing.expectError(error.ReadOnly, t.mkdirPath("/nope"));
    try std.testing.expectError(error.NotDir, t.mkdirPath("/init/x"));
    try std.testing.expectError(error.Exists, t.mkdirPath("/tmp"));
    try std.testing.expectError(error.ReadOnly, t.rmdirPath("/tmp"));

    try t.mkdirPath("/tmp/keep");
    try t.mkdirPath("/tmp/keep/child");
}

test "rename moves a heap node and replaces a file or empty directory" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    const file = try t.openPath("/tmp/a", .write, true);
    _ = try file.node.writeAt(0, "hello");
    try t.renamePath("/tmp/a", "/tmp/b");
    try t.renamePath("/tmp/b", "/tmp/./b");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/a"));
    try std.testing.expect(file.node == try t.walk("/tmp/b"));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hello", textOf(file.node, &buf));

    const replaced = try t.openPath("/tmp/c", .write, true);
    _ = try replaced.node.writeAt(0, "gone");
    replaced.node.retain();
    try t.renamePath("/tmp/b", "/tmp/c");
    try std.testing.expectEqualStrings("hello", textOf(try t.walk("/tmp/c"), &buf));
    try std.testing.expectEqualStrings("gone", textOf(replaced.node, &buf));
    replaced.node.release();

    try t.mkdirPath("/tmp/dir");
    try t.mkdirPath("/tmp/dir/sub");
    const nested = try t.openPath("/tmp/dir/sub/f", .write, true);
    _ = try nested.node.writeAt(0, "x");
    try std.testing.expectError(error.Invalid, t.renamePath("/tmp/dir", "/tmp/dir/sub"));
    try std.testing.expectError(error.Invalid, t.renamePath("/tmp/dir", "/tmp/dir/missing"));
    try t.mkdirPath("/tmp/full");
    try t.mkdirPath("/tmp/full/child");
    try std.testing.expectError(error.NotEmpty, t.renamePath("/tmp/dir", "/tmp/full"));
    try t.mkdirPath("/tmp/empty");
    try std.testing.expectError(error.IsDir, t.renamePath("/tmp/c", "/tmp/empty"));
    try std.testing.expectError(error.NotDir, t.renamePath("/tmp/dir", "/tmp/c"));
    try t.renamePath("/tmp/dir", "/tmp/empty");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/dir"));
    try std.testing.expectEqualStrings("x", textOf(try t.walk("/tmp/empty/sub/f"), &buf));
    try std.testing.expectEqualStrings("empty", (try t.walk("/tmp/empty/sub/..")).name());

    try t.renamePath("/tmp/c", "/tmp/empty/c");
    try std.testing.expectEqualStrings("hello", textOf(try t.walk("/tmp/empty/c"), &buf));

    try std.testing.expectError(error.ReadOnly, t.renamePath("/init", "/tmp/init"));
    try std.testing.expectError(error.ReadOnly, t.renamePath("/tmp", "/other"));
    try std.testing.expectError(error.NoEnt, t.renamePath("/tmp/missing", "/tmp/x"));
    try std.testing.expectError(error.NotDir, t.renamePath("/init/x", "/tmp/x"));
}

test "relative paths start at the given directory" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    try t.mkdirPath("/tmp/a");
    const dir = try t.walk("/tmp/a");
    const file = try t.openPathFrom(dir, "f", .write, true);
    _ = try file.node.writeAt(0, "hi");
    try std.testing.expectError(error.NoEnt, t.walk("f"));
    try std.testing.expect(file.node == try t.walkFrom(dir, "f"));
    try std.testing.expectEqualStrings("elf", (try t.walkFrom(dir, "/init")).bytes().?);
    try std.testing.expect(try t.walkFrom(dir, "..") == try t.walk("/tmp"));

    try t.mkdirPath("/tmp/a/sub");
    try t.renamePathFrom(dir, "f", "sub/g");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", textOf(try t.walk("/tmp/a/sub/g"), &buf));
    try t.unlinkPath("/tmp/a/sub/g");
    try t.rmdirPath("/tmp/a/sub");

    dir.retain();
    try t.rmdirPath("/tmp/a");
    try std.testing.expect(try t.walkFrom(dir, "..") == dir);

    try t.mkdirPathFrom(dir, "b");
    const child = try t.openPathFrom(dir, "b/f", .write, true);
    _ = try child.node.writeAt(0, "x");
    child.node.retain();
    dir.release();
    try std.testing.expect(child.node.parent == null);
    try std.testing.expectEqualStrings("x", textOf(child.node, &buf));
    child.node.release();
}

test "pathOf rebuilds a path from parent links" {
    var tar: ustar.Fixture = .{};
    var t: Tree = .{};
    defer t.deinit();
    try mountFixture(&t, &tar);

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("/", buf[0..try t.pathOf(try t.walk("/"), &buf)]);

    try t.mkdirPath("/tmp/a");
    try t.mkdirPath("/tmp/a/b");
    const dir = try t.walk("/tmp/a/b");
    try std.testing.expectEqualStrings("/tmp/a/b", buf[0..try t.pathOf(dir, &buf)]);
    try std.testing.expectError(error.NameTooLong, t.pathOf(dir, buf[0..4]));

    dir.retain();
    try t.rmdirPath("/tmp/a/b");
    try std.testing.expectError(error.NoEnt, t.pathOf(dir, &buf));
    dir.release();
}
