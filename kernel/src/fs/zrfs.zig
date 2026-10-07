//! Directory format on a block disk.
//!
//! Little-endian, 4096-byte blocks. This layout is the part that has to
//! stay put: a disk written by this file is read back by it, including
//! after the RAM image is copied and after virtio-blk replaces that image.
//!
//! Block 0 is the superblock: magic `zrs1` (`0x3173727a`) and the block
//! count. Block 1 is a bitmap, one bit per block, set when the block is
//! used. One bitmap block is the whole map, so a disk is at most 32768
//! blocks (128 MiB). Block 2 is the root directory inode.
//!
//! An inode is one block. `kind` is 1 for a file and 2 for a directory,
//! then a pad `u32`, then the byte size, then up to 1020 direct block
//! numbers. A zero number ends the list. Block 0 is the superblock, so it
//! is never a data block.
//!
//! A directory's bytes are 128-byte records: inode, kind, name length, and
//! 100 name bytes. Inode 0 is a free slot. Records do not cross a block.

const std = @import("std");

const blk = @import("blk.zig");

pub const root_ino: u32 = 2;
pub const magic: u32 = 0x3173727a;

const name_cap: usize = 100;

pub const Kind = enum(u32) { file = 1, dir = 2 };

pub const Error = error{ Io, OutOfMemory, Exists, BadName, TooBig, NoEnt };

const IoMem = error{ Io, OutOfMemory };

const bitmap_block: u32 = 1;
const inode_head: usize = 16;
const max_ptrs: usize = (blk.block_size - inode_head) / @sizeOf(u32);
const max_bytes: usize = max_ptrs * blk.block_size;
const rec_size: usize = 128;

comptime {
    std.debug.assert(max_ptrs == 1020);
    std.debug.assert(blk.block_size % rec_size == 0);
}

pub const Ent = struct {
    ino: u32,
    kind: Kind,
    name_len: usize,
};

pub fn format(disk: *blk.Disk) Error!void {
    disk.live = @min(disk.block_count, blk.max_blocks);

    const super = try disk.get(0);
    defer disk.put(super);
    @memset(super.data, 0);
    writeU32(super.data, 0, magic);
    writeU32(super.data, 4, disk.live);
    try disk.commit(super);

    const map = try disk.get(bitmap_block);
    defer disk.put(map);
    @memset(map.data, 0);
    setBit(map.data, 0, true);
    setBit(map.data, bitmap_block, true);
    setBit(map.data, root_ino, true);
    try disk.commit(map);

    const root = try disk.get(root_ino);
    defer disk.put(root);
    @memset(root.data, 0);
    writeU32(root.data, 0, @intFromEnum(Kind.dir));
    try disk.commit(root);
}

/// True when block 0 has this format. Sets `disk.live` from the superblock.
pub fn probe(disk: *blk.Disk) IoMem!bool {
    const super = try disk.get(0);
    defer disk.put(super);
    if (readU32(super.data, 0) != magic) return false;
    const total = readU32(super.data, 4);
    if (total < 3 or total > disk.block_count or total > blk.max_blocks) return false;
    disk.live = total;
    return true;
}

pub fn create(disk: *blk.Disk, parent: u32, name: []const u8, kind: Kind) Error!u32 {
    try checkName(name);
    if (try lookup(disk, parent, name) != null) return error.Exists;
    const ino = try allocBlock(disk);
    {
        const slot = try disk.get(ino);
        writeU32(slot.data, 0, @intFromEnum(kind));
        disk.commit(slot) catch |err| {
            disk.put(slot);
            freeBlock(disk, ino) catch {};
            return err;
        };
        disk.put(slot);
    }
    link(disk, parent, name, ino, kind) catch |err| {
        freeBlock(disk, ino) catch {};
        return err;
    };
    return ino;
}

pub fn lookup(disk: *blk.Disk, dir: u32, name: []const u8) IoMem!?u32 {
    const hit = try findName(disk, dir, name) orelse return null;
    return hit.ino;
}

pub fn link(disk: *blk.Disk, parent: u32, name: []const u8, ino: u32, kind: Kind) Error!void {
    try checkName(name);
    if (try lookup(disk, parent, name) != null) return error.Exists;
    var i: usize = 0;
    while (true) : (i += 1) {
        var ignore: [name_cap]u8 = undefined;
        const ent = try readEntry(disk, parent, i, &ignore) orelse break;
        if (ent.ino == 0) {
            try writeRec(disk, parent, i, ino, kind, name);
            return;
        }
    }
    try writeRec(disk, parent, i, ino, kind, name);
}

pub fn unlinkName(disk: *blk.Disk, dir: u32, name: []const u8) error{ Io, OutOfMemory, TooBig, NoEnt }!void {
    const hit = try findName(disk, dir, name) orelse return error.NoEnt;
    var rec: [rec_size]u8 = @splat(0);
    _ = try write(disk, dir, hit.index * rec_size, &rec);
}

/// Free the inode and every block it points at.
pub fn destroy(disk: *blk.Disk, ino: u32) IoMem!void {
    if (ino <= bitmap_block) return error.Io;
    {
        const slot = try disk.get(ino);
        defer disk.put(slot);
        const n = ptrCount(slot.data);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const b = ptrAt(slot.data, i);
            setPtr(slot.data, i, 0);
            try disk.commit(slot);
            try freeBlock(disk, b);
        }
    }
    try freeBlock(disk, ino);
}

pub fn byteSize(disk: *blk.Disk, ino: u32) IoMem!usize {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    return readSize(slot.data);
}

pub fn dataBlock(disk: *blk.Disk, ino: u32, off: usize) IoMem!?u32 {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    const index = off / blk.block_size;
    if (index >= max_ptrs) return null;
    const b = ptrAt(slot.data, index);
    if (b == 0) return null;
    return b;
}

pub fn readEntry(disk: *blk.Disk, dir: u32, index: usize, name_out: []u8) IoMem!?Ent {
    var rec: [rec_size]u8 = undefined;
    const n = try read(disk, dir, index * rec_size, &rec);
    if (n == 0) return null;
    if (n < rec_size) return error.Io;
    const ino = readU32(&rec, 0);
    if (ino == 0) return .{ .ino = 0, .kind = .file, .name_len = 0 };
    const kind: Kind = switch (readU32(&rec, 4)) {
        @intFromEnum(Kind.file) => .file,
        @intFromEnum(Kind.dir) => .dir,
        else => return error.Io,
    };
    const name_len = readU32(&rec, 8);
    if (name_len > name_cap or name_len > name_out.len) return error.Io;
    @memcpy(name_out[0..name_len], rec[12..][0..name_len]);
    return .{ .ino = ino, .kind = kind, .name_len = name_len };
}

pub fn read(disk: *blk.Disk, ino: u32, off: usize, dest: []u8) IoMem!usize {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    const sz = readSize(slot.data);
    if (off >= sz or dest.len == 0) return 0;
    const n = @min(dest.len, sz - off);
    var done: usize = 0;
    while (done < n) {
        const at = off + done;
        const b = ptrAt(slot.data, at / blk.block_size);
        if (b == 0) return error.Io;
        const data = try disk.get(b);
        const page_off = at % blk.block_size;
        const m = @min(n - done, blk.block_size - page_off);
        @memcpy(dest[done..][0..m], data.data[page_off..][0..m]);
        disk.put(data);
        done += m;
    }
    return n;
}

pub fn write(disk: *blk.Disk, ino: u32, off: usize, src: []const u8) error{ Io, TooBig, OutOfMemory }!usize {
    if (src.len == 0) return 0;
    const end = std.math.add(usize, off, src.len) catch return error.TooBig;
    if (end > max_bytes) return error.TooBig;

    const slot = try disk.get(ino);
    defer disk.put(slot);
    const sz = readSize(slot.data);
    if (off > sz) return error.TooBig;

    const need = blocksFor(end);
    const have = ptrCount(slot.data);
    var i: usize = have;
    while (i < need) : (i += 1) {
        const b = allocBlock(disk) catch |err| {
            var j: usize = have;
            while (j < i) : (j += 1) {
                const old = ptrAt(slot.data, j);
                setPtr(slot.data, j, 0);
                freeBlock(disk, old) catch {};
            }
            disk.commit(slot) catch {};
            return err;
        };
        setPtr(slot.data, i, b);
    }
    try disk.commit(slot);

    var done: usize = 0;
    while (done < src.len) {
        const at = off + done;
        const b = ptrAt(slot.data, at / blk.block_size);
        if (b == 0) return error.Io;
        const data = try disk.get(b);
        const page_off = at % blk.block_size;
        const m = @min(src.len - done, blk.block_size - page_off);
        @memcpy(data.data[page_off..][0..m], src[done..][0..m]);
        disk.commit(data) catch |err| {
            disk.put(data);
            return err;
        };
        disk.put(data);
        done += m;
    }

    if (end > sz) {
        writeU64(slot.data, 8, end);
        disk.commit(slot) catch |err| {
            writeU64(slot.data, 8, sz);
            return err;
        };
    }
    return src.len;
}

/// Size becomes 0. A frame a mapping still holds is zeroed and kept so the
/// mapping does not change which page it has. Otherwise the blocks are freed.
pub fn truncate(disk: *blk.Disk, ino: u32) IoMem!void {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    const n = ptrCount(slot.data);
    var shared = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (disk.shared(ptrAt(slot.data, i))) {
            shared = true;
            break;
        }
    }
    if (shared) {
        i = 0;
        while (i < n) : (i += 1) {
            const data = try disk.get(ptrAt(slot.data, i));
            @memset(data.data, 0);
            disk.commit(data) catch |err| {
                disk.put(data);
                return err;
            };
            disk.put(data);
        }
        writeU64(slot.data, 8, 0);
        try disk.commit(slot);
        return;
    }
    i = 0;
    while (i < n) : (i += 1) {
        const b = ptrAt(slot.data, i);
        setPtr(slot.data, i, 0);
        try disk.commit(slot);
        try freeBlock(disk, b);
    }
    writeU64(slot.data, 8, 0);
    try disk.commit(slot);
}

const Hit = struct { index: usize, ino: u32 };

fn findName(disk: *blk.Disk, dir: u32, name: []const u8) IoMem!?Hit {
    var i: usize = 0;
    while (true) : (i += 1) {
        var buf: [name_cap]u8 = undefined;
        const ent = try readEntry(disk, dir, i, &buf) orelse return null;
        if (ent.ino == 0) continue;
        if (ent.name_len == name.len and std.mem.eql(u8, buf[0..ent.name_len], name)) {
            return .{ .index = i, .ino = ent.ino };
        }
    }
}

fn writeRec(disk: *blk.Disk, dir: u32, index: usize, ino: u32, kind: Kind, name: []const u8) Error!void {
    var rec: [rec_size]u8 = @splat(0);
    writeU32(&rec, 0, ino);
    writeU32(&rec, 4, @intFromEnum(kind));
    writeU32(&rec, 8, @intCast(name.len));
    @memcpy(rec[12..][0..name.len], name);
    _ = try write(disk, dir, index * rec_size, &rec);
}

fn allocBlock(disk: *blk.Disk) error{ Io, OutOfMemory }!u32 {
    const map = try disk.get(bitmap_block);
    defer disk.put(map);
    var i: u32 = 0;
    while (i < disk.live) : (i += 1) {
        if (bitSet(map.data, i)) continue;
        setBit(map.data, i, true);
        try disk.commit(map);
        try zeroBlock(disk, i);
        return i;
    }
    return error.OutOfMemory;
}

fn freeBlock(disk: *blk.Disk, block: u32) IoMem!void {
    if (block <= bitmap_block) return error.Io;
    disk.forget(block);
    const map = try disk.get(bitmap_block);
    defer disk.put(map);
    setBit(map.data, block, false);
    try disk.commit(map);
}

fn zeroBlock(disk: *blk.Disk, block: u32) IoMem!void {
    const slot = try disk.get(block);
    defer disk.put(slot);
    @memset(slot.data, 0);
    try disk.commit(slot);
}

fn checkName(name: []const u8) error{BadName}!void {
    if (name.len == 0 or name.len > name_cap) return error.BadName;
}

fn blocksFor(len: usize) usize {
    if (len == 0) return 0;
    return (len + blk.block_size - 1) / blk.block_size;
}

fn readSize(data: []const u8) usize {
    return @intCast(readU64(data, 8));
}

fn ptrCount(data: []const u8) usize {
    var i: usize = 0;
    while (i < max_ptrs and ptrAt(data, i) != 0) i += 1;
    return i;
}

fn ptrAt(data: []const u8, index: usize) u32 {
    const at = inode_head + index * 4;
    return readU32(data, at);
}

fn setPtr(data: []u8, index: usize, block: u32) void {
    writeU32(data, inode_head + index * 4, block);
}

fn readU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn writeU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

fn readU64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

fn writeU64(buf: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], value, .little);
}

fn bitSet(buf: []const u8, i: u32) bool {
    return buf[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

fn setBit(buf: []u8, i: u32, on: bool) void {
    const mask: u8 = @as(u8, 1) << @intCast(i % 8);
    if (on) buf[i / 8] |= mask else buf[i / 8] &= ~mask;
}

test "a directory written to the disk reads back from a copy of the blocks" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 32);
    defer disk.deinit();
    try format(disk);

    const dir = try create(disk, root_ino, "d", .dir);
    const file = try create(disk, dir, "a", .file);
    try std.testing.expectEqual(@as(usize, 5), try write(disk, file, 0, "hello"));

    const image = try a.dupe(u8, disk.image);
    const copy = try blk.Disk.adopt(a, image);
    defer copy.deinit();
    try std.testing.expect(try probe(copy));

    var name: [name_cap]u8 = undefined;
    const top = (try readEntry(copy, root_ino, 0, &name)).?;
    try std.testing.expectEqual(dir, top.ino);
    try std.testing.expectEqual(Kind.dir, top.kind);
    try std.testing.expectEqualStrings("d", name[0..top.name_len]);

    const child = (try readEntry(copy, dir, 0, &name)).?;
    try std.testing.expectEqual(file, child.ino);
    try std.testing.expectEqualStrings("a", name[0..child.name_len]);

    var buf: [8]u8 = undefined;
    const n = try read(copy, file, 0, &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}
