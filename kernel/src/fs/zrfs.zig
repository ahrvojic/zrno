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
//! then the number of direct blocks, then the byte size, then up to 1020
//! direct block numbers. A count of zero and a non-zero first pointer is
//! an older list ended by a zero number. New writes store the count.
//! Block 0 is the superblock, so it is never a data block.
//!
//! A directory's bytes are 128-byte records: inode, kind, name length, and
//! 100 name bytes. Inode 0 is a free slot. Records do not cross a block.
//! A rewrite commits each block once: the live records in that block and
//! the zeroed tail share that commit.

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
    writeU32(root.data, 0, @backingInt(Kind.dir));
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

/// Allocate an inode block and publish its kind. No directory record.
pub fn allocInode(disk: *blk.Disk, kind: Kind) Error!u32 {
    const ino = try allocBlock(disk);
    const slot = try disk.get(ino);
    writeU32(slot.data, 0, @backingInt(kind));
    disk.commit(slot) catch |err| {
        disk.put(slot);
        freeBlock(disk, ino) catch {};
        return err;
    };
    disk.put(slot);
    return ino;
}

pub fn create(disk: *blk.Disk, parent: u32, name: []const u8, kind: Kind) Error!u32 {
    try checkName(name);
    if (try lookup(disk, parent, name) != null) return error.Exists;
    const ino = try allocInode(disk, kind);
    link(disk, parent, name, ino, kind) catch |err| {
        freeBlock(disk, ino) catch {};
        return err;
    };
    return ino;
}

/// Rebuild `dir`. `add` each live record, then `finish`. The old tail is
/// zeroed in the same block write as the records that replace it.
pub const DirWriter = struct {
    disk: *blk.Disk,
    dir: u32,
    old: usize,
    block: [blk.block_size]u8,
    filled: usize,
    off: usize,

    pub fn init(self: *DirWriter, disk: *blk.Disk, dir: u32) Error!void {
        self.* = .{
            .disk = disk,
            .dir = dir,
            .old = try byteSize(disk, dir),
            .block = @splat(0),
            .filled = 0,
            .off = 0,
        };
    }

    pub fn add(self: *DirWriter, ino: u32, kind: Kind, name: []const u8) Error!void {
        try checkName(name);
        if (self.off + self.filled + rec_size > max_bytes) return error.TooBig;
        if (self.filled == blk.block_size) try self.flush(self.off + blk.block_size);
        encodeRec(self.block[self.filled..][0..rec_size], ino, kind, name);
        self.filled += rec_size;
    }

    /// One `write` per block still covering the previous directory.
    pub fn finish(self: *DirWriter) Error!void {
        const end = @max(self.off + self.filled, self.old);
        while (self.off < end) try self.flush(end);
    }

    fn flush(self: *DirWriter, end: usize) Error!void {
        const room = @min(blk.block_size, end - self.off);
        _ = try write(self.disk, self.dir, self.off, self.block[0..room]);
        @memset(&self.block, 0);
        self.filled = 0;
        self.off += blk.block_size;
    }
};

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

/// Free the inode and every block it points at.
pub fn destroy(disk: *blk.Disk, ino: u32) IoMem!void {
    if (ino <= bitmap_block) return error.Io;
    {
        const slot = try disk.get(ino);
        defer disk.put(slot);
        try clearBlocks(disk, slot);
    }
    try freeBlock(disk, ino);
}

pub fn byteSize(disk: *blk.Disk, ino: u32) IoMem!usize {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    return readSize(slot.data);
}

pub fn readEntry(disk: *blk.Disk, dir: u32, index: usize, name_out: []u8) IoMem!?Ent {
    var rec: [rec_size]u8 = undefined;
    const n = try read(disk, dir, index * rec_size, &rec);
    if (n == 0) return null;
    if (n < rec_size) return error.Io;
    const ino = readU32(&rec, 0);
    if (ino == 0) return .{ .ino = 0, .kind = .file, .name_len = 0 };
    const kind: Kind = switch (readU32(&rec, 4)) {
        @backingInt(Kind.file) => .file,
        @backingInt(Kind.dir) => .dir,
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
    const have = try blockCount(slot.data);
    const stored = readCount(slot.data);
    var i: usize = have;
    while (i < need) : (i += 1) {
        const b = allocBlock(disk) catch |err| {
            freeNew(disk, slot, have, i);
            return err;
        };
        setPtr(slot.data, i, b);
    }
    // `need` is only this write. The count is the file's block span.
    const live = @max(have, blocksFor(@max(end, sz)));
    if (live != @as(usize, stored)) {
        writeCount(slot.data, @intCast(live));
        disk.commit(slot) catch |err| {
            writeCount(slot.data, stored);
            freeNew(disk, slot, have, i);
            return err;
        };
    }

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

/// Size becomes 0. One commit publishes the empty inode, then the blocks
/// are freed from the high index down. A failed commit leaves the file as
/// it was. A failed free can leak a bitmap bit; the size is already zero.
pub fn truncate(disk: *blk.Disk, ino: u32) IoMem!void {
    const slot = try disk.get(ino);
    defer disk.put(slot);
    try clearBlocks(disk, slot);
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

fn encodeRec(dest: []u8, ino: u32, kind: Kind, name: []const u8) void {
    @memset(dest[0..rec_size], 0);
    writeU32(dest, 0, ino);
    writeU32(dest, 4, @backingInt(kind));
    writeU32(dest, 8, @intCast(name.len));
    @memcpy(dest[12..][0..name.len], name);
}

fn writeRec(disk: *blk.Disk, dir: u32, index: usize, ino: u32, kind: Kind, name: []const u8) Error!void {
    var rec: [rec_size]u8 = @splat(0);
    encodeRec(&rec, ino, kind, name);
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
    // Every block is taken. That is a full disk, not a failed allocation.
    return error.Io;
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

fn readCount(data: []const u8) u32 {
    return readU32(data, 4);
}

fn writeCount(data: []u8, n: u32) void {
    writeU32(data, 4, n);
}

/// Direct blocks. A zero count with a live pointer is the old terminator.
fn blockCount(data: []const u8) error{Io}!usize {
    const n = readCount(data);
    if (n > max_ptrs) return error.Io;
    if (n != 0) return n;
    var i: usize = 0;
    while (i < max_ptrs and ptrAt(data, i) != 0) i += 1;
    return i;
}

fn freeNew(disk: *blk.Disk, slot: *blk.Slot, have: usize, end: usize) void {
    if (end == have) return;
    var j = have;
    while (j < end) : (j += 1) {
        const old = ptrAt(slot.data, j);
        setPtr(slot.data, j, 0);
        freeBlock(disk, old) catch {};
    }
    disk.commit(slot) catch {};
}

/// Publish an empty block list, then free the old blocks high to low.
fn clearBlocks(disk: *blk.Disk, slot: *blk.Slot) IoMem!void {
    const n = try blockCount(slot.data);
    var blocks: [max_ptrs]u32 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        blocks[i] = ptrAt(slot.data, i);
        setPtr(slot.data, i, 0);
    }
    const old_count = readCount(slot.data);
    const old_size = readSize(slot.data);
    writeCount(slot.data, 0);
    writeU64(slot.data, 8, 0);
    disk.commit(slot) catch |err| {
        i = 0;
        while (i < n) : (i += 1) setPtr(slot.data, i, blocks[i]);
        writeCount(slot.data, old_count);
        writeU64(slot.data, 8, old_size);
        return err;
    };
    while (i > 0) {
        i -= 1;
        freeBlock(disk, blocks[i]) catch {};
    }
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

const WriteCount = struct {
    dev: *anyopaque,
    read_fn: blk.ReadFn,
    write_fn: blk.WriteFn,
    writes: usize = 0,

    fn readHook(ptr: *anyopaque, block: u32, dest: []u8) error{Io}!void {
        const self: *WriteCount = @ptrCast(@alignCast(ptr));
        return self.read_fn(self.dev, block, dest);
    }

    fn writeHook(ptr: *anyopaque, block: u32, src: []const u8) error{Io}!void {
        const self: *WriteCount = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        return self.write_fn(self.dev, block, src);
    }

    fn install(self: *WriteCount, disk: *blk.Disk) void {
        self.* = .{
            .dev = disk.dev,
            .read_fn = disk.read_fn,
            .write_fn = disk.write_fn,
        };
        disk.dev = self;
        disk.read_fn = readHook;
        disk.write_fn = writeHook;
    }

    fn restore(self: *WriteCount, disk: *blk.Disk) void {
        disk.dev = self.dev;
        disk.read_fn = self.read_fn;
        disk.write_fn = self.write_fn;
    }
};

test "a directory rewrite commits a block's records and zero tail together" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 32);
    defer disk.deinit();
    try format(disk);

    const dir = try create(disk, root_ino, "d", .dir);
    const file_a = try create(disk, dir, "a", .file);
    const file_b = try create(disk, dir, "b", .file);
    try std.testing.expectEqual(file_a, (try lookup(disk, dir, "a")).?);

    var counted: WriteCount = undefined;
    counted.install(disk);
    defer counted.restore(disk);

    var writer: DirWriter = undefined;
    try writer.init(disk, dir);
    try writer.add(file_b, .file, "b");
    try writer.finish();
    try std.testing.expectEqual(1, counted.writes);

    var name: [name_cap]u8 = undefined;
    const first = (try readEntry(disk, dir, 0, &name)).?;
    try std.testing.expectEqual(file_b, first.ino);
    try std.testing.expectEqualStrings("b", name[0..first.name_len]);
    const hole = (try readEntry(disk, dir, 1, &name)).?;
    try std.testing.expectEqual(@as(u32, 0), hole.ino);
    try std.testing.expect(try readEntry(disk, dir, 2, &name) == null);
    try std.testing.expect(try lookup(disk, dir, "a") == null);
    try std.testing.expectEqual(file_b, (try lookup(disk, dir, "b")).?);
    try std.testing.expectEqual(@as(usize, rec_size * 2), try byteSize(disk, dir));

    counted.writes = 0;
    try writer.init(disk, dir);
    try writer.finish();
    try std.testing.expectEqual(1, counted.writes);
    const cleared = (try readEntry(disk, dir, 0, &name)).?;
    try std.testing.expectEqual(@as(u32, 0), cleared.ino);
    try std.testing.expect(try lookup(disk, dir, "b") == null);
}

test "a two-block directory rewrite clears the tail block" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 64);
    defer disk.deinit();
    try format(disk);

    const dir = try create(disk, root_ino, "d", .dir);
    const count = blk.block_size / rec_size + 1;
    var last: u32 = 0;
    var name_buf: [8]u8 = undefined;
    for (0..count) |i| {
        const name = std.fmt.bufPrint(&name_buf, "f{d}", .{i}) catch unreachable;
        last = try create(disk, dir, name, .file);
    }

    var counted: WriteCount = undefined;
    counted.install(disk);
    defer counted.restore(disk);

    var writer: DirWriter = undefined;
    try writer.init(disk, dir);
    try writer.add(last, .file, "kept");
    try writer.finish();
    try std.testing.expectEqual(2, counted.writes);

    var name: [name_cap]u8 = undefined;
    const kept = (try readEntry(disk, dir, 0, &name)).?;
    try std.testing.expectEqual(last, kept.ino);
    try std.testing.expectEqualStrings("kept", name[0..kept.name_len]);
    var i: usize = 1;
    while (try readEntry(disk, dir, i, &name)) |ent| : (i += 1) {
        try std.testing.expectEqual(@as(u32, 0), ent.ino);
    }
    try std.testing.expect(i > blk.block_size / rec_size);
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

test "an old pointer list with a zero count still reads" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 8);
    defer disk.deinit();
    try format(disk);
    const file = try create(disk, root_ino, "a", .file);
    try std.testing.expectEqual(@as(usize, 5), try write(disk, file, 0, "hello"));
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        writeU32(slot.data, 4, 0);
        try disk.commit(slot);
    }
    var buf: [8]u8 = undefined;
    const n = try read(disk, file, 0, &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 1), try write(disk, file, 5, "!"));
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        try std.testing.expectEqual(@as(u32, 1), readCount(slot.data));
    }
    const n2 = try read(disk, file, 0, &buf);
    try std.testing.expectEqualStrings("hello!", buf[0..n2]);
}

test "a short write keeps the tail blocks" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 8);
    defer disk.deinit();
    try format(disk);
    const file = try create(disk, root_ino, "a", .file);
    var page: [blk.block_size]u8 = @splat('x');
    try std.testing.expectEqual(page.len, try write(disk, file, 0, &page));
    @memset(&page, 'y');
    try std.testing.expectEqual(page.len, try write(disk, file, page.len, &page));
    try std.testing.expectEqual(@as(usize, 1), try write(disk, file, 0, "z"));
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        try std.testing.expectEqual(@as(u32, 2), readCount(slot.data));
        try std.testing.expect(ptrAt(slot.data, 1) != 0);
    }
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try read(disk, file, 0, &buf));
    try std.testing.expectEqual(@as(u8, 'z'), buf[0]);
    try std.testing.expectEqual(@as(usize, 1), try read(disk, file, blk.block_size, &buf));
    try std.testing.expectEqual(@as(u8, 'y'), buf[0]);
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        writeCount(slot.data, 0);
        try disk.commit(slot);
    }
    try std.testing.expectEqual(@as(usize, 1), try write(disk, file, 1, "q"));
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        try std.testing.expectEqual(@as(u32, 2), readCount(slot.data));
    }
    try std.testing.expectEqual(@as(usize, 1), try read(disk, file, blk.block_size, &buf));
    try std.testing.expectEqual(@as(u8, 'y'), buf[0]);
    try truncate(disk, file);
    const again = try create(disk, root_ino, "b", .file);
    try std.testing.expectEqual(page.len, try write(disk, again, 0, &page));
    try std.testing.expectEqual(page.len, try write(disk, again, page.len, &page));
}

test "truncate publishes a zero size and frees the blocks" {
    const a = std.testing.allocator;
    const disk = try blk.Disk.memory(a, 8);
    defer disk.deinit();
    try format(disk);
    const file = try create(disk, root_ino, "a", .file);
    var page: [blk.block_size]u8 = @splat('x');
    try std.testing.expectEqual(page.len, try write(disk, file, 0, &page));
    try std.testing.expectEqual(page.len, try write(disk, file, page.len, &page));
    try truncate(disk, file);
    try std.testing.expectEqual(@as(usize, 0), try byteSize(disk, file));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read(disk, file, 0, &buf));
    {
        const slot = try disk.get(file);
        defer disk.put(slot);
        try std.testing.expectEqual(@as(u32, 0), readCount(slot.data));
        try std.testing.expectEqual(@as(u32, 0), ptrAt(slot.data, 0));
    }
    const again = try create(disk, root_ino, "b", .file);
    try std.testing.expectEqual(page.len, try write(disk, again, 0, &page));
    try std.testing.expectEqual(page.len, try write(disk, again, page.len, &page));
}
