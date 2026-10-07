//! Legacy virtio-blk. One queue, the I/O BAR, and guest-physical addresses
//! for the descriptor ring and the data page. The request is polled: a
//! syscall runs with interrupts off, so the used ring is the completion.

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const mem = @import("../lib/mem.zig");
const pci = @import("pci.zig");
const pmm = @import("../mm/pmm.zig");
const port = @import("../sys/port.zig");
const virt = @import("../lib/virt.zig");

const logger = std.log.scoped(.virtio);

const vendor: u16 = 0x1af4;
const device_id: u16 = 0x1001;

const off_guest: u16 = 0x04;
const off_pfn: u16 = 0x08;
const off_qsz: u16 = 0x0c;
const off_select: u16 = 0x0e;
const off_notify: u16 = 0x10;
const off_status: u16 = 0x12;
const off_config: u16 = 0x14;

const ack: u8 = 1;
const driver: u8 = 2;
const driver_ok: u8 = 4;

const desc_next: u16 = 1;
const desc_write: u16 = 2;
const no_interrupt: u16 = 1;

const type_in: u32 = 0;
const type_out: u32 = 1;
const poll_spins: u32 = 1_000_000;

pub const Dev = struct {
    io: u16,
    blocks: u32,
    qsz: u16,
    queue_phys: usize,
    queue_pages: usize,
    avail_at: usize,
    used_at: usize,
    req_phys: usize,
    avail_idx: u16 = 0,
};

var device: Dev = undefined;
var ready = false;

pub fn init() ?*Dev {
    if (ready) return &device;
    device = open() catch |err| {
        logger.warn("virtio-blk: {s}", .{@errorName(err)});
        return null;
    };
    ready = true;
    return &device;
}

pub fn shutdown(dev: *Dev) void {
    port.outb(dev.io + off_status, 0);
    pmm.free(dev.queue_phys, dev.queue_pages);
    pmm.free(dev.req_phys, 1);
    ready = false;
}

pub fn read(ptr: *anyopaque, block: u32, dest: []u8) error{Io}!void {
    const dev: *Dev = @ptrCast(@alignCast(ptr));
    try transfer(dev, type_in, block, dest);
}

pub fn write(ptr: *anyopaque, block: u32, src: []const u8) error{Io}!void {
    const dev: *Dev = @ptrCast(@alignCast(ptr));
    try transfer(dev, type_out, block, src);
}

const OpenError = error{ NoDevice, NoBar, Queue, Capacity, OutOfMemory };

fn open() OpenError!Dev {
    const addr = pci.find(vendor, device_id) orelse return error.NoDevice;
    const command = (pci.read32(addr, 0x04) & 0xffff) | 1 | 4;
    pci.write32(addr, 0x04, command);

    const bar = pci.read32(addr, 0x10);
    if (bar & 1 == 0) return error.NoBar;
    const raw = bar & 0xfffc;
    if (raw == 0 or raw > 0xffff) return error.NoBar;
    const io: u16 = @intCast(raw);

    port.outb(io + off_status, 0);
    var spun: u32 = 0;
    while (port.inb(io + off_status) != 0) : (spun += 1) {
        if (spun == poll_spins) return error.NoDevice;
        cpu.pause();
    }
    port.outb(io + off_status, ack);
    errdefer port.outb(io + off_status, 0);
    port.outb(io + off_status, ack | driver);
    port.outl(io + off_guest, 0);

    port.outw(io + off_select, 0);
    const qsz = port.inw(io + off_qsz);
    if (qsz < 3) return error.Queue;
    const layout = queueLayout(qsz);
    const pages = (layout.bytes + mem.page_size - 1) / mem.page_size;
    if (pages > 16) return error.Queue;
    const queue_phys = pmm.alloc(pages) orelse return error.OutOfMemory;
    errdefer pmm.free(queue_phys, pages);
    const req_phys = pmm.alloc(1) orelse return error.OutOfMemory;
    errdefer pmm.free(req_phys, 1);

    if (queue_phys >> 12 > std.math.maxInt(u32)) return error.Queue;
    port.outl(io + off_pfn, @intCast(queue_phys >> 12));
    port.outb(io + off_status, ack | driver | driver_ok);
    // Reset before the queue pages are freed if the disk is too small.
    errdefer port.outb(io + off_status, 0);

    const sectors = readSectors(io);
    if (sectors < 24) return error.Capacity;
    const blocks64 = sectors / 8;
    const blocks: u32 = if (blocks64 > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(blocks64);

    return .{
        .io = io,
        .blocks = blocks,
        .qsz = qsz,
        .queue_phys = queue_phys,
        .queue_pages = pages,
        .avail_at = layout.avail,
        .used_at = layout.used,
        .req_phys = req_phys,
    };
}

fn transfer(self: *Dev, kind: u32, block: u32, data: []const u8) error{Io}!void {
    if (data.len != mem.page_size or block >= self.blocks) return error.Io;
    const data_phys = virt.fromHH(@intFromPtr(data.ptr));
    const req = virt.toHH([*]u8, self.req_phys);
    const hdr = req[0..16];
    @memset(hdr, 0);
    std.mem.writeInt(u32, hdr[0..4], kind, .little);
    std.mem.writeInt(u64, hdr[8..16], @as(u64, block) * 8, .little);
    req[16] = 0xff;

    const base = virt.toHH([*]u8, self.queue_phys);
    const write_data = kind == type_in;
    writeDesc(base, 0, self.req_phys, 16, desc_next, 1);
    writeDesc(base, 1, data_phys, mem.page_size, desc_next | if (write_data) desc_write else 0, 2);
    writeDesc(base, 2, self.req_phys + 16, 1, desc_write, 0);

    const avail = base + self.avail_at;
    const slot: usize = self.avail_idx % self.qsz;
    std.mem.writeInt(u16, avail[0..2], no_interrupt, .little);
    std.mem.writeInt(u16, avail[4 + slot * 2 ..][0..2], 0, .little);
    self.avail_idx +%= 1;
    @as(*volatile u16, @ptrCast(@alignCast(avail + 2))).* = self.avail_idx;

    port.outw(self.io + off_notify, 0);

    const used_idx: *volatile u16 = @ptrCast(@alignCast(base + self.used_at + 2));
    var spins: u32 = 0;
    while (used_idx.* != self.avail_idx) : (spins += 1) {
        if (spins == poll_spins) return error.Io;
        cpu.pause();
    }
    if (req[16] != 0) return error.Io;
}

const Layout = struct { bytes: usize, avail: usize, used: usize };

fn queueLayout(qsz: u16) Layout {
    const n: usize = qsz;
    const desc = n * 16;
    const avail = 4 + 2 * n;
    const used_at = std.mem.alignForward(usize, desc + avail, mem.page_size);
    const used = 4 + 8 * n;
    return .{ .bytes = used_at + used, .avail = desc, .used = used_at };
}

fn writeDesc(base: [*]u8, index: u16, addr: usize, len: u32, flags: u16, next: u16) void {
    const at = @as(usize, index) * 16;
    const desc = base[at..][0..16];
    std.mem.writeInt(u64, desc[0..8], addr, .little);
    std.mem.writeInt(u32, desc[8..12], len, .little);
    std.mem.writeInt(u16, desc[12..14], flags, .little);
    std.mem.writeInt(u16, desc[14..16], next, .little);
}

fn readSectors(io: u16) u64 {
    const lo = port.inl(io + off_config);
    const hi = port.inl(io + off_config + 4);
    return (@as(u64, hi) << 32) | lo;
}
