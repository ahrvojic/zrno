//! One name tree. `/` is the initramfs: static nodes, bytes borrowed from the
//! ustar image, mounted before the heap exists. `/tmp` is an empty ramfs
//! whose nodes and file bytes come from the heap.

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
    ReadOnly,
    Exists,
    BadName,
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
        self.discard();
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
        var node = self.root orelse return error.NoEnt;
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
        if (create and !write_access) return error.BadName;
        if (self.walk(path)) |node| {
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
                const node = try self.createAt(path);
                return .{ .node = node, .can_write = true };
            },
        }
    }

    pub fn unlinkPath(self: *Tree, path: []const u8) Error!void {
        const parts = try splitFinal(path);
        const parent = try self.walk(parts.parent);
        if (!parent.isDir()) return error.NotDir;
        const child = lookupChild(parent, parts.name) orelse return error.NoEnt;
        if (child.isDir()) return error.IsDir;
        if (!child.isWritableFile() or !parent.isWritableDir()) return error.ReadOnly;
        detach(parent, child);
        child.release();
    }

    fn createAt(self: *Tree, path: []const u8) Error!*Node {
        const parts = try splitFinal(path);
        const parent = try self.walk(parts.parent);
        return createFile(parent, parts.name);
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

pub fn walk(path: []const u8) error{ NoEnt, NotDir }!*Node {
    return tree.walk(path);
}

pub fn openPath(path: []const u8, write_access: bool, create: bool) Error!Open {
    return tree.openPath(path, write_access, create);
}

pub fn unlinkPath(path: []const u8) Error!void {
    try tree.unlinkPath(path);
}

fn createFile(parent: *Node, nam: []const u8) Error!*Node {
    const alloc = switch (parent.kind) {
        .dir => |owner| owner orelse return error.ReadOnly,
        else => return error.NotDir,
    };
    if (lookupChild(parent, nam) != null) return error.Exists;
    const node = try alloc.create(Node);
    node.* = .{
        .kind = .{ .owned = .{ .data = &.{}, .heap = alloc } },
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
