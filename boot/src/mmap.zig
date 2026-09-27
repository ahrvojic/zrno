//! EFI memory descriptors become a flat, non-overlapping map the kernel
//! can consume. Overlay carves kernel, initramfs, framebuffer, and RSDP
//! out of the firmware ranges.

const std = @import("std");

const bootinfo = @import("bootinfo");

const MemEntry = bootinfo.MemEntry;
const MemKind = bootinfo.MemKind;

pub const Map = struct {
    entries: [bootinfo.max_entries]MemEntry = undefined,
    len: usize = 0,

    pub fn push(self: *Map, entry: MemEntry) error{ MapFull, Overflow }!void {
        if (entry.length == 0) return;
        _ = try add(entry.base, entry.length);
        if (self.len == bootinfo.max_entries) return error.MapFull;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    /// Mark `[base, base + length)` as `kind`, splitting whatever is there
    /// and inserting a new entry when the range was absent.
    pub fn overlay(self: *Map, base: u64, length: u64, kind: MemKind) error{ MapFull, Overflow }!void {
        if (length == 0) return;
        const end = try add(base, length);
        try self.splitAndRetag(base, end, kind);
        try self.fillGaps(base, end, kind);
        self.merge();
    }

    fn splitAndRetag(self: *Map, base: u64, end: u64, kind: MemKind) error{ MapFull, Overflow }!void {
        var i: usize = 0;
        while (i < self.len) {
            const entry = self.entries[i];
            const entry_end = try add(entry.base, entry.length);
            if (entry_end <= base or entry.base >= end) {
                i += 1;
                continue;
            }

            if (entry.base < base) {
                try self.insert(i, .{
                    .base = entry.base,
                    .length = base - entry.base,
                    .kind = entry.kind,
                });
                i += 1;
                self.entries[i] = .{
                    .base = base,
                    .length = entry_end - base,
                    .kind = entry.kind,
                };
            }

            const cur_end = try add(self.entries[i].base, self.entries[i].length);
            if (cur_end > end) {
                const right_kind = self.entries[i].kind;
                self.entries[i].length = end - self.entries[i].base;
                self.entries[i].kind = kind;
                try self.insert(i + 1, .{
                    .base = end,
                    .length = cur_end - end,
                    .kind = right_kind,
                });
                i += 2;
            } else {
                self.entries[i].kind = kind;
                i += 1;
            }
        }
    }

    fn fillGaps(self: *Map, base: u64, end: u64, kind: MemKind) error{ MapFull, Overflow }!void {
        var cursor = base;
        var i: usize = 0;
        while (cursor < end and i < self.len) {
            const entry = self.entries[i];
            const entry_end = try add(entry.base, entry.length);
            if (entry_end <= cursor) {
                i += 1;
                continue;
            }
            if (entry.base > cursor) {
                const gap_end = @min(entry.base, end);
                try self.insert(i, .{
                    .base = cursor,
                    .length = gap_end - cursor,
                    .kind = kind,
                });
                cursor = gap_end;
                i += 1;
                continue;
            }
            cursor = entry_end;
            i += 1;
        }
        if (cursor < end) {
            try self.push(.{ .base = cursor, .length = end - cursor, .kind = kind });
        }
    }

    pub fn merge(self: *Map) void {
        if (self.len == 0) return;
        var write_at: usize = 0;
        for (self.entries[0..self.len]) |entry| {
            if (entry.length == 0) continue;
            if (write_at > 0) {
                const prev = &self.entries[write_at - 1];
                if (prev.kind == entry.kind and prev.base + prev.length == entry.base) {
                    prev.length += entry.length;
                    continue;
                }
            }
            self.entries[write_at] = entry;
            write_at += 1;
        }
        self.len = write_at;
    }

    fn insert(self: *Map, index: usize, entry: MemEntry) error{MapFull}!void {
        if (self.len == bootinfo.max_entries) return error.MapFull;
        var i = self.len;
        while (i > index) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }
        self.entries[index] = entry;
        self.len += 1;
    }
};

fn add(base: u64, length: u64) error{Overflow}!u64 {
    return std.math.add(u64, base, length);
}

fn expectKind(map: *const Map, index: usize, base: u64, length: u64, kind: MemKind) !void {
    const entry = map.entries[index];
    try std.testing.expectEqual(base, entry.base);
    try std.testing.expectEqual(length, entry.length);
    try std.testing.expectEqual(kind, entry.kind);
}

test "overlay splits a usable range" {
    var map: Map = .{};
    try map.push(.{ .base = 0, .length = 0x100000, .kind = .usable });
    try map.overlay(0x1000, 0x1000, .modules);
    try std.testing.expectEqual(3, map.len);
    try expectKind(&map, 0, 0, 0x1000, .usable);
    try expectKind(&map, 1, 0x1000, 0x1000, .modules);
    try expectKind(&map, 2, 0x2000, 0x100000 - 0x2000, .usable);
}

test "overlay inserts a range the firmware did not list" {
    var map: Map = .{};
    try map.push(.{ .base = 0, .length = 0x1000, .kind = .usable });
    try map.overlay(0x80000000, 0x400000, .framebuffer);
    try std.testing.expectEqual(2, map.len);
    try expectKind(&map, 0, 0, 0x1000, .usable);
    try expectKind(&map, 1, 0x80000000, 0x400000, .framebuffer);
}

test "overlay fills a hole between entries and merges" {
    var map: Map = .{};
    try map.push(.{ .base = 0, .length = 100, .kind = .usable });
    try map.push(.{ .base = 200, .length = 100, .kind = .usable });
    try map.overlay(50, 200, .framebuffer);
    try std.testing.expectEqual(3, map.len);
    try expectKind(&map, 0, 0, 50, .usable);
    try expectKind(&map, 1, 50, 200, .framebuffer);
    try expectKind(&map, 2, 250, 50, .usable);
}

test "adjacent entries of the same kind merge" {
    var map: Map = .{};
    try map.push(.{ .base = 0, .length = 0x1000, .kind = .usable });
    try map.push(.{ .base = 0x1000, .length = 0x1000, .kind = .reclaim });
    try map.overlay(0x1000, 0x1000, .usable);
    try std.testing.expectEqual(1, map.len);
    try expectKind(&map, 0, 0, 0x2000, .usable);
}
