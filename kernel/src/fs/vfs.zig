//! One name tree. `/` is the initramfs: static nodes, bytes borrowed from the
//! ustar image, mounted before the heap exists. `/tmp` is a ramfs whose
//! directories, files, and file bytes come from the heap.

const std = @import("std");

const heap = @import("../mm/heap.zig");
const ustar = @import("ustar.zig");

pub const max_files: usize = 32;
pub const max_name: usize = ustar.max_name;
pub const max_file_bytes: usize = 256 * 1024;

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
};

pub const Open = struct {
    node: *Node,
    can_write: bool,
};

pub const Node = struct {
    refs: usize = 1,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    parent: ?*Node = null,
    next: ?*Node = null,
    child: ?*Node = null,
    kind: Kind,

    const Owned = struct {
        data: []u8,
        heap: std.mem.Allocator,
    };

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

    pub fn bytes(self: *const Node) ?[]const u8 {
        return switch (self.kind) {
            .borrowed => |b| b,
            .owned => |o| o.data,
            .dir => null,
        };
    }

    pub fn size(self: *const Node) usize {
        return if (self.bytes()) |b| b.len else 0;
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

    pub fn writeAt(self: *Node, off: usize, src: []const u8) error{ ReadOnly, IsDir, TooBig, OutOfMemory }!usize {
        switch (self.kind) {
            .owned => |*o| {
                const end = std.math.add(usize, off, src.len) catch return error.TooBig;
                if (end > max_file_bytes or off > o.data.len) return error.TooBig;
                if (end > o.data.len) {
                    const grown = try o.heap.alloc(u8, end);
                    @memcpy(grown[0..o.data.len], o.data);
                    if (o.data.len != 0) o.heap.free(o.data);
                    o.data = grown;
                }
                @memcpy(o.data[off..][0..src.len], src);
                return src.len;
            },
            .borrowed => return error.ReadOnly,
            .dir => return error.IsDir,
        }
    }

    fn truncate(self: *Node) void {
        switch (self.kind) {
            .owned => |*o| {
                if (o.data.len != 0) o.heap.free(o.data);
                o.data = &.{};
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
                if (o.data.len != 0) o.heap.free(o.data);
                o.heap.destroy(self);
            },
            .dir => |alloc| {
                const owner = alloc orelse @panic("static vnode freed");
                if (self.child != null) @panic("freeing directory with children");
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

    pub fn mountTmp(self: *Tree, allocator: std.mem.Allocator) error{ NoEnt, Exists, OutOfMemory }!void {
        const base = self.root orelse return error.NoEnt;
        if (lookupChild(base, tmp_name) != null) return error.Exists;
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .dir = allocator },
        };
        node.setName(tmp_name);
        addChild(base, node);
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
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (node.parent) |p| node = p;
                continue;
            }
            if (!node.isDir()) return error.NotDir;
            node = lookupChild(node, part) orelse return error.NoEnt;
        }
        return node;
    }

    /// `write_access` truncates an existing ramfs file. `create` makes a
    /// missing file. Create without write is rejected.
    pub fn openPath(self: *Tree, path: []const u8, write_access: bool, create: bool) Error!Open {
        const start = self.root orelse return error.NoEnt;
        return self.openPathFrom(start, path, write_access, create);
    }

    pub fn openPathFrom(self: *Tree, start: *Node, path: []const u8, write_access: bool, create: bool) Error!Open {
        if (create and !write_access) return error.BadName;
        if (self.walkFrom(start, path)) |node| {
            if (node.isDir()) {
                if (write_access) return error.IsDir;
                return .{ .node = node, .can_write = false };
            }
            if (write_access) {
                if (!node.isWritableFile()) return error.ReadOnly;
                node.truncate();
                return .{ .node = node, .can_write = true };
            }
            return .{ .node = node, .can_write = false };
        } else |err| switch (err) {
            error.NotDir => return error.NotDir,
            error.NoEnt => {
                if (!create) return error.NoEnt;
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
        if (child.isDir()) return error.IsDir;
        if (!child.isWritableFile() or !at.parent.isWritableDir()) return error.ReadOnly;
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
        if (from.parent == to.parent and std.mem.eql(u8, from.name, to.name)) return;
        if (node.isDir() and isInside(node, to.parent)) return error.Invalid;
        if (!from.parent.isWritableDir() or !to.parent.isWritableDir()) return error.ReadOnly;
        if (!node.isWritableDir() and !node.isWritableFile()) return error.ReadOnly;
        if (lookupChild(to.parent, to.name)) |dest| {
            if (dest.isDir() != node.isDir()) {
                if (dest.isDir()) return error.IsDir;
                return error.NotDir;
            }
            if (dest.isDir()) {
                if (dest.child != null) return error.NotEmpty;
                if (!dest.isWritableDir()) return error.ReadOnly;
            } else if (!dest.isWritableFile()) return error.ReadOnly;
            detach(to.parent, dest);
            dest.release();
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

pub fn mountTmp() error{ NoEnt, Exists, OutOfMemory }!void {
    try tree.mountTmp(heap.kernel_heap.allocator());
}

pub fn root() *Node {
    return tree.root orelse @panic("vfs used before mount");
}

pub fn walkFrom(start: *Node, path: []const u8) error{ NoEnt, NotDir }!*Node {
    return tree.walkFrom(start, path);
}

pub fn openPathFrom(start: *Node, path: []const u8, write_access: bool, create: bool) Error!Open {
    return tree.openPathFrom(start, path, write_access, create);
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
    const node = try alloc.create(Node);
    node.* = .{
        .kind = switch (kind) {
            .file => .{ .owned = .{ .data = &.{}, .heap = alloc } },
            .dir => .{ .dir = alloc },
        },
    };
    node.setName(nam);
    addChild(parent, node);
    return node;
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

test "tmp ramfs creates, writes, and unlinks" {
    var tar: ustar.Fixture = .{};
    tar.addFile("init", "elf");
    var t: Tree = .{};
    defer t.deinit();
    try t.mount(tar.finish());
    try t.mountTmp(std.testing.allocator);

    try std.testing.expectEqualStrings("tmp", (try t.walk("/")).childAt(1).?.name());
    try std.testing.expectError(error.ReadOnly, t.openPath("/init", true, true));
    try std.testing.expectError(error.ReadOnly, t.openPath("/new", true, true));
    try std.testing.expectError(error.ReadOnly, t.unlinkPath("/init"));
    try std.testing.expectError(error.IsDir, t.unlinkPath("/tmp"));
    try std.testing.expectError(error.IsDir, t.unlinkPath("/"));
    try std.testing.expectError(error.NoEnt, t.openPath("/tmp/missing", true, false));

    const created = try t.openPath("/tmp/a", true, true);
    _ = try created.node.writeAt(0, "hello");
    try std.testing.expectEqualStrings("hello", (try t.walk("/tmp/a")).bytes().?);

    const again = try t.openPath("/tmp/a", true, false);
    try std.testing.expectEqual(@as(usize, 0), again.node.bytes().?.len);
    _ = try again.node.writeAt(0, "hi");
    try std.testing.expectEqualStrings("hi", again.node.bytes().?);
    try std.testing.expectError(error.TooBig, again.node.writeAt(3, "z"));
    try std.testing.expectError(error.TooBig, again.node.writeAt(max_file_bytes, "x"));

    again.node.retain();
    try t.unlinkPath("/tmp/a");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/a"));
    try std.testing.expectEqualStrings("hi", again.node.bytes().?);
    again.node.release();

    try std.testing.expectError(error.NotDir, t.walk("/init/x"));
    try std.testing.expectEqualStrings("elf", (try t.walk("/tmp/../init")).bytes().?);
}

test "tmp directories nest, and rmdir refuses a non-empty dir" {
    var tar: ustar.Fixture = .{};
    tar.addFile("init", "elf");
    var t: Tree = .{};
    defer t.deinit();
    try t.mount(tar.finish());
    try t.mountTmp(std.testing.allocator);

    try t.mkdirPath("/tmp/a");
    try t.mkdirPath("/tmp/a/b");
    const created = try t.openPath("/tmp/a/b/c", true, true);
    _ = try created.node.writeAt(0, "x");
    try std.testing.expectEqualStrings("x", (try t.walk("/tmp/a/b/c")).bytes().?);

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
    tar.addFile("init", "elf");
    var t: Tree = .{};
    defer t.deinit();
    try t.mount(tar.finish());
    try t.mountTmp(std.testing.allocator);

    const file = try t.openPath("/tmp/a", true, true);
    _ = try file.node.writeAt(0, "hello");
    try t.renamePath("/tmp/a", "/tmp/b");
    try t.renamePath("/tmp/b", "/tmp/./b");
    try std.testing.expectError(error.NoEnt, t.walk("/tmp/a"));
    try std.testing.expect(file.node == try t.walk("/tmp/b"));
    try std.testing.expectEqualStrings("hello", file.node.bytes().?);

    const replaced = try t.openPath("/tmp/c", true, true);
    _ = try replaced.node.writeAt(0, "gone");
    replaced.node.retain();
    try t.renamePath("/tmp/b", "/tmp/c");
    try std.testing.expectEqualStrings("hello", (try t.walk("/tmp/c")).bytes().?);
    try std.testing.expectEqualStrings("gone", replaced.node.bytes().?);
    replaced.node.release();

    try t.mkdirPath("/tmp/dir");
    try t.mkdirPath("/tmp/dir/sub");
    const nested = try t.openPath("/tmp/dir/sub/f", true, true);
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
    try std.testing.expectEqualStrings("x", (try t.walk("/tmp/empty/sub/f")).bytes().?);
    try std.testing.expectEqualStrings("empty", (try t.walk("/tmp/empty/sub/..")).name());

    try t.renamePath("/tmp/c", "/tmp/empty/c");
    try std.testing.expectEqualStrings("hello", (try t.walk("/tmp/empty/c")).bytes().?);

    try std.testing.expectError(error.ReadOnly, t.renamePath("/init", "/tmp/init"));
    try std.testing.expectError(error.ReadOnly, t.renamePath("/tmp", "/other"));
    try std.testing.expectError(error.NoEnt, t.renamePath("/tmp/missing", "/tmp/x"));
    try std.testing.expectError(error.NotDir, t.renamePath("/init/x", "/tmp/x"));
}

test "relative paths start at the given directory" {
    var tar: ustar.Fixture = .{};
    tar.addFile("init", "elf");
    var t: Tree = .{};
    defer t.deinit();
    try t.mount(tar.finish());
    try t.mountTmp(std.testing.allocator);

    try t.mkdirPath("/tmp/a");
    const dir = try t.walk("/tmp/a");
    const file = try t.openPathFrom(dir, "f", true, true);
    _ = try file.node.writeAt(0, "hi");
    try std.testing.expectError(error.NoEnt, t.walk("f"));
    try std.testing.expect(file.node == try t.walkFrom(dir, "f"));
    try std.testing.expectEqualStrings("elf", (try t.walkFrom(dir, "/init")).bytes().?);
    try std.testing.expect(try t.walkFrom(dir, "..") == try t.walk("/tmp"));

    try t.mkdirPath("/tmp/a/sub");
    try t.renamePathFrom(dir, "f", "sub/g");
    try std.testing.expectEqualStrings("hi", (try t.walk("/tmp/a/sub/g")).bytes().?);
    try t.unlinkPath("/tmp/a/sub/g");
    try t.rmdirPath("/tmp/a/sub");

    dir.retain();
    try t.rmdirPath("/tmp/a");
    try std.testing.expect(try t.walkFrom(dir, "..") == dir);

    try t.mkdirPathFrom(dir, "b");
    const child = try t.openPathFrom(dir, "b/f", true, true);
    _ = try child.node.writeAt(0, "x");
    child.node.retain();
    dir.release();
    try std.testing.expect(child.node.parent == null);
    try std.testing.expectEqualStrings("x", child.node.bytes().?);
    child.node.release();
}
