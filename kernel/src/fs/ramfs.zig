const std = @import("std");

const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const ustar = @import("ustar.zig");

pub const max_files: usize = 32;
pub const max_name: usize = ustar.max_name;

pub const Entry = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    data: []const u8 = &.{},

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Table = struct {
    files: BoundedArray(Entry, max_files) = .{},

    pub fn mount(self: *Table, archive: []const u8) error{ BadTar, TooManyFiles }!void {
        self.files.len = 0;
        errdefer self.files.len = 0;
        var it = ustar.walk(archive);
        while (try it.next()) |file| {
            if (file.name.len == 0) continue;
            const n = @min(file.name.len, max_name);
            var e: Entry = .{ .data = file.data, .name_len = n };
            @memcpy(e.name_buf[0..n], file.name[0..n]);
            self.files.append(e) catch return error.TooManyFiles;
        }
    }

    pub fn lookup(self: *const Table, path: []const u8) ?[]const u8 {
        const key = stripSlash(path);
        if (key.len == 0) return null;
        for (self.entries()) |e| {
            if (std.mem.eql(u8, e.name(), key)) return e.data;
        }
        return null;
    }

    pub fn entries(self: *const Table) []const Entry {
        return self.files.constSlice();
    }
};

var table: Table = .{};

pub fn mount(archive: []const u8) error{ BadTar, TooManyFiles }!void {
    try table.mount(archive);
}

pub fn lookup(path: []const u8) ?[]const u8 {
    return table.lookup(path);
}

pub fn entries() []const Entry {
    return table.entries();
}

pub fn isRoot(path: []const u8) bool {
    const key = stripSlash(path);
    return key.len == 0 or std.mem.eql(u8, key, ".");
}

fn stripSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    return p;
}

test "mount fixture tar and lookup" {
    var tar: ustar.Fixture = .{};
    tar.addFile("hello.txt", "hello from ramfs\n");
    tar.addFile("hello", "\x7fELF");
    var t: Table = .{};
    try t.mount(tar.finish());

    try std.testing.expectEqualStrings("hello from ramfs\n", t.lookup("hello.txt").?);
    try std.testing.expectEqualStrings("hello from ramfs\n", t.lookup("/hello.txt").?);
    try std.testing.expectEqualStrings("\x7fELF", t.lookup("hello").?);
    try std.testing.expectEqualStrings("\x7fELF", t.lookup("/hello").?);
    try std.testing.expect(t.lookup("missing") == null);
    try std.testing.expect(t.lookup("") == null);
    try std.testing.expect(t.lookup("/") == null);

    try std.testing.expectEqual(@as(usize, 2), t.entries().len);
    try std.testing.expectEqualStrings("hello.txt", t.entries()[0].name());
    try std.testing.expectEqual(@as(usize, "hello from ramfs\n".len), t.entries()[0].data.len);
    try std.testing.expectEqualStrings("hello", t.entries()[1].name());
}

test "isRoot treats / and . as the ramfs root" {
    try std.testing.expect(isRoot("/"));
    try std.testing.expect(isRoot(""));
    try std.testing.expect(isRoot("//"));
    try std.testing.expect(isRoot("."));
    try std.testing.expect(isRoot("/."));
    try std.testing.expect(!isRoot("hello"));
    try std.testing.expect(!isRoot("/hello"));
    try std.testing.expect(!isRoot(".."));
}

test "mount rejects more than max_files" {
    // One header per empty file plus two trailing zero blocks.
    var tar: ustar.Archive(max_files + 3) = .{};
    var names: [max_files + 1][2]u8 = undefined;
    for (&names, 0..) |*name, i| {
        name.* = .{ @intCast('a' + i / 26), @intCast('a' + i % 26) };
        tar.addFile(name, "");
    }
    var t: Table = .{};
    try std.testing.expectError(error.TooManyFiles, t.mount(tar.finish()));
    try std.testing.expectEqual(@as(usize, 0), t.entries().len);
}

test "mount drops a partial table on BadTar" {
    var tar: ustar.Fixture = .{};
    tar.addFile("init", "elf");
    tar.addFile("tail", "x");
    const archive = tar.finish();
    var t: Table = .{};
    try std.testing.expectError(error.BadTar, t.mount(archive[0 .. ustar.block_size * 3]));
    try std.testing.expectEqual(@as(usize, 0), t.entries().len);
    try std.testing.expect(t.lookup("init") == null);
}
