//! Load the kernel ELF. Segments stay at
//! `kernel_phys + (vaddr - kernel_virt)`, which is what `vmm` assumes.
//! The image is linked at a fixed address, so there is nothing to relocate.

const std = @import("std");

const bootinfo = @import("bootinfo");

const elf = std.elf;
const Ehdr = elf.Elf64.Ehdr;
const Phdr = elf.Elf64.Phdr;

pub const Image = struct {
    entry: u64,
    /// Bytes from `kernel_virt` through the last segment, rounded up to a page.
    bytes: u64,
};

pub fn parse(file: []const u8) error{BadElf}!Image {
    const hdr = try header(file);
    var high = bootinfo.kernel_virt;
    var loads: usize = 0;
    for (0..hdr.phnum) |i| {
        const ph = try phdr(file, hdr, i);
        if (ph.type != .LOAD) continue;
        loads += 1;
        if (ph.vaddr < bootinfo.kernel_virt) return error.BadElf;
        if (ph.memsz < ph.filesz) return error.BadElf;
        const vend = std.math.add(u64, ph.vaddr, ph.memsz) catch return error.BadElf;
        const fend = std.math.add(u64, ph.offset, ph.filesz) catch return error.BadElf;
        if (fend > file.len) return error.BadElf;
        if (vend > high) high = vend;
    }
    if (loads == 0) return error.BadElf;
    if (hdr.entry < bootinfo.kernel_virt or hdr.entry >= high) return error.BadElf;
    const span = high - bootinfo.kernel_virt;
    return .{
        .entry = hdr.entry,
        .bytes = std.mem.alignForward(u64, span, bootinfo.page_size),
    };
}

/// `dest` is the physical image, already zeroed, of length `parse().bytes`.
pub fn copy(file: []const u8, dest: []u8) error{BadElf}!void {
    const hdr = try header(file);
    for (0..hdr.phnum) |i| {
        const ph = try phdr(file, hdr, i);
        if (ph.type != .LOAD) continue;
        if (ph.filesz == 0) continue;
        const off = std.math.sub(u64, ph.vaddr, bootinfo.kernel_virt) catch return error.BadElf;
        const end = std.math.add(u64, off, ph.filesz) catch return error.BadElf;
        const off_n: usize = std.math.cast(usize, off) orelse return error.BadElf;
        const end_n: usize = std.math.cast(usize, end) orelse return error.BadElf;
        const file_off: usize = std.math.cast(usize, ph.offset) orelse return error.BadElf;
        const filesz: usize = std.math.cast(usize, ph.filesz) orelse return error.BadElf;
        if (end_n > dest.len) return error.BadElf;
        const file_end = std.math.add(usize, file_off, filesz) catch return error.BadElf;
        if (file_end > file.len) return error.BadElf;
        @memcpy(dest[off_n..][0..filesz], file[file_off..][0..filesz]);
    }
}

fn header(file: []const u8) error{BadElf}!Ehdr {
    if (file.len < @sizeOf(Ehdr)) return error.BadElf;
    const hdr = try peek(Ehdr, file, 0);
    if (!std.mem.eql(u8, &hdr.ident.magic, elf.MAGIC)) return error.BadElf;
    if (hdr.ident.class != .@"64") return error.BadElf;
    if (hdr.ident.data != .@"2LSB") return error.BadElf;
    if (hdr.type != .EXEC) return error.BadElf;
    if (hdr.machine != .X86_64) return error.BadElf;
    if (hdr.phentsize != @sizeOf(Phdr)) return error.BadElf;
    if (hdr.phnum == 0 or hdr.phnum == 0xffff) return error.BadElf;
    const bytes = std.math.mul(u64, hdr.phnum, hdr.phentsize) catch return error.BadElf;
    const end = std.math.add(u64, hdr.phoff, bytes) catch return error.BadElf;
    if (end > file.len) return error.BadElf;
    return hdr;
}

fn phdr(file: []const u8, hdr: Ehdr, index: usize) error{BadElf}!Phdr {
    const step = std.math.mul(u64, index, hdr.phentsize) catch return error.BadElf;
    const off = std.math.add(u64, hdr.phoff, step) catch return error.BadElf;
    const at: usize = std.math.cast(usize, off) orelse return error.BadElf;
    return peek(Phdr, file, at);
}

fn peek(comptime T: type, file: []const u8, offset: usize) error{BadElf}!T {
    const size = @sizeOf(T);
    if (offset > file.len or file.len - offset < size) return error.BadElf;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), file[offset..][0..size]);
    return value;
}
