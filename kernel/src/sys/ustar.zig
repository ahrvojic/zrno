const std = @import("std");

pub const block_size: usize = 512;
pub const max_name: usize = 100;

pub const File = struct {
    name: []const u8,
    data: []const u8,
};

pub const Walker = struct {
    archive: []const u8,
    offset: usize = 0,

    pub fn next(self: *Walker) error{BadTar}!?File {
        while (true) {
            const remaining = self.archive.len - self.offset;
            if (remaining == 0) return null;
            if (remaining < block_size) return error.BadTar;

            const hdr = self.archive[self.offset..][0..block_size];
            self.offset += block_size;
            if (isZero(hdr)) return null;

            const size = try parseOctal(hdr[124..136]);
            const padded = try paddedSize(size);
            if (padded > self.archive.len - self.offset) return error.BadTar;

            const data = self.archive[self.offset..][0..size];
            self.offset += padded;

            const typeflag = hdr[156];
            if (typeflag == '5') continue;
            if (typeflag != 0 and typeflag != '0') continue;

            return .{
                .name = nameSlice(hdr[0..max_name]),
                .data = data,
            };
        }
    }
};

pub fn walk(archive: []const u8) Walker {
    return .{ .archive = archive };
}

fn isZero(block: []const u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn nameSlice(field: []const u8) []const u8 {
    for (field, 0..) |c, i| {
        if (c == 0) return field[0..i];
    }
    return field;
}

fn parseOctal(raw: []const u8) error{BadTar}!usize {
    var i: usize = 0;
    while (i < raw.len and raw[i] == ' ') : (i += 1) {}
    var value: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') return error.BadTar;
        const digit: usize = c - '0';
        value = std.math.mul(usize, value, 8) catch return error.BadTar;
        value = std.math.add(usize, value, digit) catch return error.BadTar;
    }
    while (i < raw.len) : (i += 1) {
        if (raw[i] != 0 and raw[i] != ' ') return error.BadTar;
    }
    return value;
}

fn paddedSize(size: usize) error{BadTar}!usize {
    const add = block_size - 1;
    const sum = std.math.add(usize, size, add) catch return error.BadTar;
    return sum & ~add;
}

pub const Fixture = struct {
    buf: [block_size * 16]u8 = @splat(0),
    used: usize = 0,

    pub fn addFile(self: *Fixture, name: []const u8, data: []const u8) void {
        self.addMember(name, data, '0');
    }

    pub fn addDir(self: *Fixture, name: []const u8) void {
        self.addMember(name, "", '5');
    }

    pub fn addMember(self: *Fixture, name: []const u8, data: []const u8, typeflag: u8) void {
        std.debug.assert(name.len <= max_name);
        const padded = paddedSize(data.len) catch unreachable;
        std.debug.assert(self.used + block_size + padded <= self.buf.len);

        const hdr = self.buf[self.used..][0..block_size];
        @memset(hdr, 0);
        @memcpy(hdr[0..name.len], name);
        writeOctal(hdr[124..136], data.len);
        hdr[156] = typeflag;
        @memcpy(hdr[257..263], "ustar\x00");
        @memcpy(hdr[263..265], "00");
        self.used += block_size;

        if (data.len != 0) {
            @memcpy(self.buf[self.used..][0..data.len], data);
        }
        self.used += padded;
    }

    pub fn finish(self: *Fixture) []const u8 {
        std.debug.assert(self.used + block_size * 2 <= self.buf.len);
        self.used += block_size * 2;
        return self.buf[0..self.used];
    }
};

fn writeOctal(dst: []u8, value: usize) void {
    const digits = dst.len - 1;
    dst[digits] = 0;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(v % 8));
        v /= 8;
    }
}

test "walk regular files" {
    var f: Fixture = .{};
    f.addFile("hello.txt", "hi\n");
    f.addFile("hello.elf", "ELF");
    var it = walk(f.finish());

    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("hello.txt", a.name);
    try std.testing.expectEqualStrings("hi\n", a.data);

    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("hello.elf", b.name);
    try std.testing.expectEqualStrings("ELF", b.data);

    try std.testing.expect((try it.next()) == null);
}

test "skip directories and padding" {
    var f: Fixture = .{};
    f.addFile("a", "x");
    f.addDir("dir");
    f.addFile("b", "yz");
    var it = walk(f.finish());

    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expectEqualStrings("x", a.data);

    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("b", b.name);
    try std.testing.expectEqualStrings("yz", b.data);

    try std.testing.expect((try it.next()) == null);
}

test "empty archive is no files" {
    var f: Fixture = .{};
    var it = walk(f.finish());
    try std.testing.expect((try it.next()) == null);
}

test "zero-length file" {
    var f: Fixture = .{};
    f.addFile("empty", "");
    var it = walk(f.finish());
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("empty", a.name);
    try std.testing.expectEqual(@as(usize, 0), a.data.len);
    try std.testing.expect((try it.next()) == null);
}

test "reject truncated header" {
    var f: Fixture = .{};
    f.addFile("a", "x");
    const archive = f.finish();
    var it = walk(archive[0 .. block_size / 2]);
    try std.testing.expectError(error.BadTar, it.next());
}

test "reject truncated payload" {
    var f: Fixture = .{};
    f.addFile("a", "hello world");
    const archive = f.finish();
    var it = walk(archive[0..block_size]);
    try std.testing.expectError(error.BadTar, it.next());
}

test "space-terminated octal size" {
    var f: Fixture = .{};
    f.addFile("n", "ab");
    f.buf[124..136].* = "00000000002 ".*;
    var it = walk(f.finish());
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("ab", a.data);
}

test "skip non-file members" {
    var f: Fixture = .{};
    f.addFile("keep", "k");
    f.addMember("link", "", '1');
    f.addFile("after", "z");
    var it = walk(f.finish());
    try std.testing.expectEqualStrings("keep", (try it.next()).?.name);
    try std.testing.expectEqualStrings("after", (try it.next()).?.name);
    try std.testing.expect((try it.next()) == null);
}
