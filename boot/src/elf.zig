//! Load the kernel ELF. Segments stay at
//! `kernel_phys + (p_vaddr - kernel_virt)`, which is what `vmm` assumes.
//! The image is linked at a fixed address, so there is nothing to relocate.

const std = @import("std");

const bootinfo = @import("bootinfo");

const elf = std.elf;

pub const Image = struct {
    entry: u64,
    /// Bytes from `kernel_virt` through the last segment, rounded up to a page.
    bytes: u64,
};

pub fn parse(file: []const u8) error{BadElf}!Image {
    const hdr = try header(file);
    var high = bootinfo.kernel_virt;
    var loads: usize = 0;
    for (try phdrs(file, hdr)) |ph| {
        if (ph.p_type != @intFromEnum(elf.PT.LOAD)) continue;
        loads += 1;
        if (ph.p_vaddr < bootinfo.kernel_virt) return error.BadElf;
        if (ph.p_memsz < ph.p_filesz) return error.BadElf;
        const vend = std.math.add(u64, ph.p_vaddr, ph.p_memsz) catch return error.BadElf;
        const fend = std.math.add(u64, ph.p_offset, ph.p_filesz) catch return error.BadElf;
        if (fend > file.len) return error.BadElf;
        if (vend > high) high = vend;
    }
    if (loads == 0) return error.BadElf;
    if (hdr.e_entry < bootinfo.kernel_virt or hdr.e_entry >= high) return error.BadElf;
    const span = high - bootinfo.kernel_virt;
    return .{
        .entry = hdr.e_entry,
        .bytes = std.mem.alignForward(u64, span, bootinfo.page_size),
    };
}

/// `dest` is the physical image, already zeroed, of length `parse().bytes`.
pub fn copy(file: []const u8, dest: []u8) error{BadElf}!void {
    const hdr = try header(file);
    for (try phdrs(file, hdr)) |ph| {
        if (ph.p_type != @intFromEnum(elf.PT.LOAD)) continue;
        if (ph.p_filesz == 0) continue;
        const off = ph.p_vaddr - bootinfo.kernel_virt;
        const end = std.math.add(usize, off, ph.p_filesz) catch return error.BadElf;
        if (end > dest.len) return error.BadElf;
        @memcpy(dest[off..][0..ph.p_filesz], file[ph.p_offset..][0..ph.p_filesz]);
    }
}

fn header(file: []const u8) error{BadElf}!*const elf.Elf64_Ehdr {
    if (file.len < @sizeOf(elf.Elf64_Ehdr)) return error.BadElf;
    if (!std.mem.eql(u8, file[0..4], elf.MAGIC)) return error.BadElf;
    if (file[elf.EI.CLASS] != elf.ELFCLASS64) return error.BadElf;
    if (file[elf.EI.DATA] != elf.ELFDATA2LSB) return error.BadElf;
    const hdr: *const elf.Elf64_Ehdr = @ptrCast(@alignCast(file.ptr));
    if (hdr.e_type != .EXEC) return error.BadElf;
    if (hdr.e_machine != .X86_64) return error.BadElf;
    if (hdr.e_phentsize != @sizeOf(elf.Elf64_Phdr)) return error.BadElf;
    if (hdr.e_phnum == 0 or hdr.e_phnum == 0xffff) return error.BadElf;
    return hdr;
}

fn phdrs(file: []const u8, hdr: *const elf.Elf64_Ehdr) error{BadElf}![]const elf.Elf64_Phdr {
    const bytes = @as(u64, hdr.e_phnum) * hdr.e_phentsize;
    const end = std.math.add(u64, hdr.e_phoff, bytes) catch return error.BadElf;
    if (end > file.len) return error.BadElf;
    const ptr: [*]const elf.Elf64_Phdr = @ptrCast(@alignCast(file.ptr + hdr.e_phoff));
    return ptr[0..hdr.e_phnum];
}
