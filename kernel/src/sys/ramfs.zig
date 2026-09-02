const std = @import("std");

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
    files: [max_files]Entry = undefined,
    nfiles: usize = 0,

    pub fn mount(self: *Table, archive: []const u8) error{BadTar}!void {
        self.nfiles = 0;
        var it = ustar.walk(archive);
        while (try it.next()) |file| {
            if (file.name.len == 0) continue;
            if (self.nfiles >= max_files) return;
            const n = @min(file.name.len, max_name);
            var e: Entry = .{ .data = file.data, .name_len = n };
            @memcpy(e.name_buf[0..n], file.name[0..n]);
            self.files[self.nfiles] = e;
            self.nfiles += 1;
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
        return self.files[0..self.nfiles];
    }
};

var table: Table = .{};

pub fn mount(archive: []const u8) error{BadTar}!void {
    try table.mount(archive);
}

pub fn lookup(path: []const u8) ?[]const u8 {
    return table.lookup(path);
}

pub fn entries() []const Entry {
    return table.entries();
}

fn stripSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    return p;
}

test "mount fixture tar and lookup" {
    var tar: ustar.Fixture = .{};
    tar.addFile("hello.txt", "hello from ramfs\n");
    tar.addFile("hello.elf", "\x7fELF");
    var t: Table = .{};
    try t.mount(tar.finish());

    try std.testing.expectEqualStrings("hello from ramfs\n", t.lookup("hello.txt").?);
    try std.testing.expectEqualStrings("hello from ramfs\n", t.lookup("/hello.txt").?);
    try std.testing.expectEqualStrings("\x7fELF", t.lookup("hello.elf").?);
    try std.testing.expect(t.lookup("missing") == null);
    try std.testing.expect(t.lookup("") == null);
    try std.testing.expect(t.lookup("/") == null);
}

test "mount skips directories" {
    var tar: ustar.Fixture = .{};
    tar.addFile("a", "x");
    tar.addDir("dir");
    var t: Table = .{};
    try t.mount(tar.finish());
    try std.testing.expectEqual(@as(usize, 1), t.entries().len);
    try std.testing.expectEqualStrings("x", t.lookup("a").?);
    try std.testing.expect(t.lookup("dir") == null);
}

test "mount truncated tar" {
    var tar: ustar.Fixture = .{};
    tar.addFile("a", "hello world");
    const archive = tar.finish();
    var t: Table = .{};
    try std.testing.expectError(error.BadTar, t.mount(archive[0..ustar.block_size]));
}

test "empty archive is no files" {
    var tar: ustar.Fixture = .{};
    var t: Table = .{};
    try t.mount(tar.finish());
    try std.testing.expectEqual(@as(usize, 0), t.entries().len);
}
