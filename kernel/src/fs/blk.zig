//! A block device and a cache of its blocks.
//!
//! The device is either a RAM image or virtio-blk. Callers see the same
//! read and write of one 4096-byte block. Cached blocks are refcounted
//! frames on the kernel, and plain bytes in host tests.
//!
//! A slot stays until it is reused. A frame a mapping still holds is not
//! reused: that page is the mapping's copy of the block.

const std = @import("std");

const builtin = @import("builtin");
const frame = @import("../mm/frame.zig");
const mem = @import("../lib/mem.zig");

const freestanding = builtin.os.tag == .freestanding;

pub const block_size: usize = mem.page_size;
/// One bitmap block covers this many blocks.
pub const max_blocks: u32 = block_size * 8;
pub const mem_blocks: u32 = 256;
const cache_slots = 32;

pub const ReadFn = *const fn (*anyopaque, u32, []u8) error{Io}!void;
pub const WriteFn = *const fn (*anyopaque, u32, []const u8) error{Io}!void;

pub const Slot = struct {
    block: u32 = 0,
    live: bool = false,
    dirty: bool = false,
    holds: u32 = 0,
    frame: ?*frame.Frame = null,
    data: []u8 = &.{},
};

pub const Disk = struct {
    allocator: std.mem.Allocator,
    /// Blocks the device can serve.
    block_count: u32,
    /// Blocks the filesystem uses. Never above `block_count` or `max_blocks`.
    live: u32,
    dev: *anyopaque,
    read_fn: ReadFn,
    write_fn: WriteFn,
    image: []u8 = &.{},
    scratch: []u8 = &.{},
    slots: [cache_slots]Slot = undefined,

    pub fn memory(allocator: std.mem.Allocator, blocks: u32) error{OutOfMemory}!*Disk {
        if (blocks < 3 or blocks > max_blocks) return error.OutOfMemory;
        const image = try allocator.alloc(u8, @as(usize, blocks) * block_size);
        return adopt(allocator, image);
    }

    /// Takes ownership of `image`, including on failure.
    pub fn adopt(allocator: std.mem.Allocator, image: []u8) error{OutOfMemory}!*Disk {
        if (image.len % block_size != 0 or image.len < 3 * block_size) {
            allocator.free(image);
            return error.OutOfMemory;
        }
        const n = image.len / block_size;
        if (n > std.math.maxInt(u32)) {
            allocator.free(image);
            return error.OutOfMemory;
        }
        const disk = allocator.create(Disk) catch {
            allocator.free(image);
            return error.OutOfMemory;
        };
        const blocks: u32 = @intCast(n);
        const live = @min(blocks, max_blocks);
        disk.* = .{
            .allocator = allocator,
            .block_count = blocks,
            .live = live,
            .dev = disk,
            .read_fn = memRead,
            .write_fn = memWrite,
            .image = image,
        };
        disk.initCache() catch {
            disk.deinit();
            return error.OutOfMemory;
        };
        return disk;
    }

    pub fn wrap(
        allocator: std.mem.Allocator,
        blocks: u32,
        dev: *anyopaque,
        read_fn: ReadFn,
        write_fn: WriteFn,
    ) error{OutOfMemory}!*Disk {
        if (blocks < 3) return error.OutOfMemory;
        const disk = try allocator.create(Disk);
        const live = @min(blocks, max_blocks);
        disk.* = .{
            .allocator = allocator,
            .block_count = live,
            .live = live,
            .dev = dev,
            .read_fn = read_fn,
            .write_fn = write_fn,
        };
        disk.initCache() catch {
            disk.deinit();
            return error.OutOfMemory;
        };
        return disk;
    }

    pub fn deinit(self: *Disk) void {
        if (comptime freestanding) {
            for (&self.slots) |*slot| {
                if (slot.frame) |fr| fr.release();
                slot.frame = null;
            }
        }
        if (self.scratch.len != 0) self.allocator.free(self.scratch);
        if (self.image.len != 0) self.allocator.free(self.image);
        self.allocator.destroy(self);
    }

    pub fn get(self: *Disk, block: u32) error{ Io, OutOfMemory }!*Slot {
        if (block >= self.live) return error.Io;
        for (&self.slots) |*slot| {
            if (slot.live and slot.block == block) {
                slot.holds += 1;
                return slot;
            }
        }
        const slot = self.victim() orelse return error.OutOfMemory;
        if (slot.live and slot.dirty) try self.commit(slot);
        self.read_fn(self.dev, block, slot.data) catch |err| {
            slot.live = false;
            slot.dirty = false;
            return err;
        };
        slot.* = .{
            .block = block,
            .live = true,
            .holds = 1,
            .frame = slot.frame,
            .data = slot.data,
        };
        return slot;
    }

    pub fn put(self: *Disk, slot: *Slot) void {
        _ = self;
        if (slot.holds == 0) @panic("block hold underflow");
        slot.holds -= 1;
    }

    pub fn commit(self: *Disk, slot: *Slot) error{Io}!void {
        try self.write_fn(self.dev, slot.block, slot.data);
        if (!pinned(slot)) slot.dirty = false;
    }

    /// Write back blocks a user mapping may have stored into.
    pub fn sync(self: *Disk) void {
        for (&self.slots) |*slot| {
            if (!slot.live or !slot.dirty) continue;
            self.commit(slot) catch {};
        }
    }

    /// Another owner of the cached frame. The page stays in the cache, and
    /// `sync` writes it back because the mapping can store into it.
    pub fn retainFrame(self: *Disk, block: u32) error{ Io, OutOfMemory }!*frame.Frame {
        if (comptime !freestanding) unreachable;
        const slot = try self.get(block);
        defer self.put(slot);
        slot.dirty = true;
        const fr = slot.frame orelse unreachable;
        fr.retain();
        return fr;
    }

    pub fn shared(self: *const Disk, block: u32) bool {
        if (comptime !freestanding) return false;
        for (&self.slots) |*slot| {
            if (!slot.live or slot.block != block) continue;
            const fr = slot.frame orelse return false;
            return fr.refs > 1;
        }
        return false;
    }

    /// Drop a cached block that is about to be freed. A mapping keeps its
    /// frame; the slot gets a new page so the next block does not overwrite it.
    pub fn forget(self: *Disk, block: u32) void {
        for (&self.slots) |*slot| {
            if (!slot.live or slot.block != block) continue;
            if (slot.holds != 0) @panic("freeing a held block");
            detach(slot);
            slot.live = false;
            slot.dirty = false;
            return;
        }
    }

    fn victim(self: *Disk) ?*Slot {
        var spare: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (slot.holds != 0 or pinned(slot)) continue;
            if (!slot.live) return slot;
            if (spare == null) spare = slot;
        }
        return spare;
    }

    fn initCache(self: *Disk) error{OutOfMemory}!void {
        for (&self.slots) |*slot| slot.* = .{};
        if (comptime freestanding) {
            for (&self.slots) |*slot| {
                const fr = frame.alloc() orelse return error.OutOfMemory;
                slot.frame = fr;
                slot.data = fr.bytes();
            }
            return;
        }
        self.scratch = try self.allocator.alloc(u8, cache_slots * block_size);
        for (&self.slots, 0..) |*slot, i| {
            const at = i * block_size;
            slot.data = self.scratch[at..][0..block_size];
        }
    }
};

fn detach(slot: *Slot) void {
    if (comptime !freestanding) return;
    const fr = slot.frame orelse return;
    if (fr.refs == 1) return;
    fr.release();
    slot.frame = frame.alloc();
    slot.data = if (slot.frame) |fresh| fresh.bytes() else &.{};
}

fn pinned(slot: *const Slot) bool {
    if (comptime !freestanding) return false;
    const fr = slot.frame orelse return true;
    return fr.refs > 1 or slot.data.len != block_size;
}

fn memRead(dev: *anyopaque, block: u32, dest: []u8) error{Io}!void {
    const disk: *Disk = @ptrCast(@alignCast(dev));
    const off = @as(usize, block) * block_size;
    if (dest.len != block_size or off + block_size > disk.image.len) return error.Io;
    @memcpy(dest, disk.image[off..][0..block_size]);
}

fn memWrite(dev: *anyopaque, block: u32, src: []const u8) error{Io}!void {
    const disk: *Disk = @ptrCast(@alignCast(dev));
    const off = @as(usize, block) * block_size;
    if (src.len != block_size or off + block_size > disk.image.len) return error.Io;
    @memcpy(disk.image[off..][0..block_size], src);
}
