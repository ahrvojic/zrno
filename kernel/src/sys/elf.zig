const std = @import("std");

pub const page_size: usize = 4096;
pub const user_space_end: usize = 0x0000_8000_0000_0000;
/// Exclusive top of user stacks; stacks grow down from here.
pub const user_stack_top: usize = 0x0000_0000_8000_0000;
/// Reserved for `startUserThread` stacks; PT_LOAD must not overlap it.
pub const user_stack_window: usize = 16 * page_size;

pub const max_loads: usize = 8;

pub const MapFlags = struct {
    writable: bool,
    executable: bool,
};

pub const Load = struct {
    vaddr: usize,
    map_vaddr: usize,
    map_size: usize,
    offset: usize,
    filesz: usize,
    memsz: usize,
    flags: MapFlags,
};

pub const Image = struct {
    entry: usize,
    loads: [max_loads]Load = undefined,
    nloads: usize = 0,

    fn constSlice(self: *const Image) []const Load {
        return self.loads[0..self.nloads];
    }

    fn append(self: *Image, item: Load) error{BadElf}!void {
        if (self.nloads >= max_loads) return error.BadElf;
        self.loads[self.nloads] = item;
        self.nloads += 1;
    }
};

pub fn parse(image: []const u8) error{ BadElf, WritableExecutable, OutOfRange, AlreadyMapped }!Image {
    const ehdr = try peek(std.elf.Elf64_Ehdr, image, 0);
    try checkIdent(&ehdr.e_ident);
    if (ehdr.e_type == .DYN) return error.BadElf;
    if (ehdr.e_type != .EXEC) return error.BadElf;
    if (ehdr.e_machine != .X86_64) return error.BadElf;
    if (ehdr.e_version != 1) return error.BadElf;
    if (ehdr.e_ehsize != @sizeOf(std.elf.Elf64_Ehdr)) return error.BadElf;
    if (ehdr.e_phentsize != @sizeOf(std.elf.Elf64_Phdr)) return error.BadElf;
    if (ehdr.e_phnum == 0 or ehdr.e_phnum > 16) return error.BadElf;

    const phoff: usize = std.math.cast(usize, ehdr.e_phoff) orelse return error.BadElf;
    const phnum: usize = ehdr.e_phnum;
    const ph_bytes = std.math.mul(usize, phnum, @sizeOf(std.elf.Elf64_Phdr)) catch return error.BadElf;
    _ = std.math.add(usize, phoff, ph_bytes) catch return error.BadElf;
    if (phoff > image.len or image.len - phoff < ph_bytes) return error.BadElf;

    var result: Image = .{ .entry = std.math.cast(usize, ehdr.e_entry) orelse return error.BadElf };
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const phdr = try peek(std.elf.Elf64_Phdr, image, phoff + i * @sizeOf(std.elf.Elf64_Phdr));
        if (phdr.p_type == std.elf.PT_INTERP) return error.BadElf;
        if (phdr.p_type != std.elf.PT_LOAD) continue;
        try result.append(try parseLoad(image, phdr));
    }
    if (result.nloads == 0) return error.BadElf;
    try checkOverlaps(result.constSlice());
    try checkEntry(result);
    return result;
}

/// Map each `PT_LOAD` into `space`. `space` must provide:
///   alloc(self, pages: usize) error{OutOfMemory}!Alloc  // Alloc.bytes: []u8
///   free(self, alloc: Alloc) void
///   map(self, vaddr: usize, alloc: Alloc, flags: MapFlags) !void
///   unmap(self, vaddr: usize, size: usize) void
pub fn load(space: anytype, image: []const u8) !usize {
    const parsed = try parse(image);
    const segs = parsed.constSlice();
    const Alloc = @typeInfo(@TypeOf(space.alloc(@as(usize, 1)))).error_union.payload;

    var mapped: usize = 0;
    var done: [max_loads]Mapped(Alloc) = undefined;
    errdefer {
        var j: usize = mapped;
        while (j > 0) {
            j -= 1;
            space.unmap(done[j].vaddr, done[j].size);
            space.free(done[j].alloc);
        }
    }

    for (segs) |seg| {
        const pages = seg.map_size / page_size;
        const mem = try space.alloc(pages);
        errdefer space.free(mem);
        @memset(mem.bytes, 0);
        const lead = seg.vaddr - seg.map_vaddr;
        if (seg.filesz != 0) {
            @memcpy(mem.bytes[lead..][0..seg.filesz], image[seg.offset..][0..seg.filesz]);
        }
        try space.map(seg.map_vaddr, mem, seg.flags);
        done[mapped] = .{ .vaddr = seg.map_vaddr, .size = seg.map_size, .alloc = mem };
        mapped += 1;
    }
    return parsed.entry;
}

fn Mapped(comptime Alloc: type) type {
    return struct {
        vaddr: usize,
        size: usize,
        alloc: Alloc,
    };
}

fn parseLoad(image: []const u8, phdr: std.elf.Elf64_Phdr) error{ BadElf, WritableExecutable, OutOfRange }!Load {
    if (phdr.p_filesz > phdr.p_memsz) return error.BadElf;
    const vaddr: usize = std.math.cast(usize, phdr.p_vaddr) orelse return error.BadElf;
    const memsz: usize = std.math.cast(usize, phdr.p_memsz) orelse return error.BadElf;
    const filesz: usize = std.math.cast(usize, phdr.p_filesz) orelse return error.BadElf;
    const offset: usize = std.math.cast(usize, phdr.p_offset) orelse return error.BadElf;
    if (memsz == 0) return error.BadElf;

    const align_ = phdr.p_align;
    if (align_ > 1) {
        if (!std.math.isPowerOfTwo(align_)) return error.BadElf;
        if (phdr.p_vaddr % align_ != phdr.p_offset % align_) return error.BadElf;
    }

    const file_end = std.math.add(usize, offset, filesz) catch return error.BadElf;
    if (file_end > image.len) return error.BadElf;

    const vaddr_end = std.math.add(usize, vaddr, memsz) catch return error.BadElf;
    const map_vaddr = std.mem.alignBackward(usize, vaddr, page_size);
    const map_end = alignForward(vaddr_end, page_size) catch return error.BadElf;
    const map_size = map_end - map_vaddr;

    const writable = phdr.p_flags & std.elf.PF_W != 0;
    const executable = phdr.p_flags & std.elf.PF_X != 0;
    if (writable and executable) return error.WritableExecutable;
    try checkUserImageRange(map_vaddr, map_size);

    return .{
        .vaddr = vaddr,
        .map_vaddr = map_vaddr,
        .map_size = map_size,
        .offset = offset,
        .filesz = filesz,
        .memsz = memsz,
        .flags = .{ .writable = writable, .executable = executable },
    };
}

fn checkIdent(ident: *const [std.elf.EI.NIDENT]u8) error{BadElf}!void {
    if (!std.mem.eql(u8, ident[0..4], std.elf.MAGIC)) return error.BadElf;
    if (ident[std.elf.EI.CLASS] != @intFromEnum(std.elf.CLASS.@"64")) return error.BadElf;
    if (ident[std.elf.EI.DATA] != @intFromEnum(std.elf.DATA.@"2LSB")) return error.BadElf;
    if (ident[std.elf.EI.VERSION] != 1) return error.BadElf;
}

fn checkUserImageRange(addr: usize, len: usize) error{OutOfRange}!void {
    if (len == 0) return error.OutOfRange;
    if (addr < page_size) return error.OutOfRange;
    if (addr >= user_space_end) return error.OutOfRange;
    if (len > user_space_end - addr) return error.OutOfRange;

    const stack_lo = user_stack_top - user_stack_window;
    if (addr < user_stack_top and addr + len > stack_lo) return error.OutOfRange;
}

fn checkOverlaps(loads: []const Load) error{AlreadyMapped}!void {
    for (loads, 0..) |a, i| {
        for (loads[i + 1 ..]) |b| {
            if (a.map_vaddr < b.map_vaddr + b.map_size and b.map_vaddr < a.map_vaddr + a.map_size) {
                return error.AlreadyMapped;
            }
        }
    }
}

fn checkEntry(image: Image) error{BadElf}!void {
    for (image.constSlice()) |seg| {
        if (!seg.flags.executable) continue;
        if (image.entry >= seg.vaddr and image.entry - seg.vaddr < seg.memsz) return;
    }
    return error.BadElf;
}

fn alignForward(addr: usize, alignment: usize) error{BadElf}!usize {
    const add = alignment - 1;
    const padded = std.math.add(usize, addr, add) catch return error.BadElf;
    return padded & ~add;
}

fn peek(comptime T: type, image: []const u8, offset: usize) error{BadElf}!T {
    const size = @sizeOf(T);
    if (offset > image.len or image.len - offset < size) return error.BadElf;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), image[offset..][0..size]);
    return value;
}

const MockAlloc = struct { bytes: []u8 };

const MockSpace = struct {
    backing: []u8,
    used: usize = 0,
    maps: [max_loads]MockMap = undefined,
    nmaps: usize = 0,

    const MockMap = struct {
        vaddr: usize,
        bytes: []u8,
        flags: MapFlags,
    };

    fn alloc(self: *MockSpace, pages: usize) error{OutOfMemory}!MockAlloc {
        const n = pages * page_size;
        if (self.used + n > self.backing.len) return error.OutOfMemory;
        const bytes = self.backing[self.used..][0..n];
        @memset(bytes, 0xaa);
        self.used += n;
        return .{ .bytes = bytes };
    }

    fn free(self: *MockSpace, a: MockAlloc) void {
        const end = @intFromPtr(self.backing.ptr) + self.used;
        if (@intFromPtr(a.bytes.ptr) + a.bytes.len == end) {
            self.used -= a.bytes.len;
        }
    }

    fn map(self: *MockSpace, vaddr: usize, a: MockAlloc, flags: MapFlags) error{AlreadyMapped}!void {
        for (self.maps[0..self.nmaps]) |m| {
            if (m.vaddr < vaddr + a.bytes.len and vaddr < m.vaddr + m.bytes.len) {
                return error.AlreadyMapped;
            }
        }
        if (self.nmaps >= max_loads) return error.AlreadyMapped;
        self.maps[self.nmaps] = .{ .vaddr = vaddr, .bytes = a.bytes, .flags = flags };
        self.nmaps += 1;
    }

    fn unmap(self: *MockSpace, vaddr: usize, size: usize) void {
        var i: usize = 0;
        while (i < self.nmaps) : (i += 1) {
            const m = self.maps[i];
            if (m.vaddr == vaddr and m.bytes.len == size) {
                var j = i;
                while (j + 1 < self.nmaps) : (j += 1) self.maps[j] = self.maps[j + 1];
                self.nmaps -= 1;
                return;
            }
        }
    }

    fn at(self: *const MockSpace, vaddr: usize) ?MockMap {
        for (self.maps[0..self.nmaps]) |m| {
            if (m.vaddr == vaddr) return m;
        }
        return null;
    }
};

const Fixture = struct {
    buf: [page_size * 4]u8 = undefined,
    phdrs: [max_loads]std.elf.Elf64_Phdr = undefined,
    nphdr: usize = 0,
    payload_off: usize = @sizeOf(std.elf.Elf64_Ehdr) + max_loads * @sizeOf(std.elf.Elf64_Phdr),
    payload_used: usize = 0,

    fn addLoad(self: *Fixture, vaddr: u64, flags: u32, data: []const u8, bss: u64, palign: u64) void {
        var offset = self.payload_off + self.payload_used;
        if (palign > 1) {
            const want = vaddr % palign;
            const got = offset % palign;
            if (got != want) {
                const pad: usize = @intCast((want + palign - got) % palign);
                offset += pad;
                self.payload_used += pad;
            }
        }
        if (data.len != 0) {
            @memcpy(self.buf[offset..][0..data.len], data);
            self.payload_used += data.len;
        }
        self.phdrs[self.nphdr] = .{
            .p_type = std.elf.PT_LOAD,
            .p_flags = flags,
            .p_offset = offset,
            .p_vaddr = vaddr,
            .p_paddr = vaddr,
            .p_filesz = data.len,
            .p_memsz = data.len + bss,
            .p_align = palign,
        };
        self.nphdr += 1;
    }

    fn addInterp(self: *Fixture) void {
        self.phdrs[self.nphdr] = .{
            .p_type = std.elf.PT_INTERP,
            .p_flags = std.elf.PF_R,
            .p_offset = 0,
            .p_vaddr = 0,
            .p_paddr = 0,
            .p_filesz = 0,
            .p_memsz = 0,
            .p_align = 1,
        };
        self.nphdr += 1;
    }

    fn finish(self: *Fixture, typ: std.elf.ET, machine: std.elf.EM, entry: u64) []const u8 {
        var ehdr = std.mem.zeroes(std.elf.Elf64_Ehdr);
        @memcpy(ehdr.e_ident[0..4], std.elf.MAGIC);
        ehdr.e_ident[std.elf.EI.CLASS] = @intFromEnum(std.elf.CLASS.@"64");
        ehdr.e_ident[std.elf.EI.DATA] = @intFromEnum(std.elf.DATA.@"2LSB");
        ehdr.e_ident[std.elf.EI.VERSION] = 1;
        ehdr.e_type = typ;
        ehdr.e_machine = machine;
        ehdr.e_version = 1;
        ehdr.e_entry = entry;
        ehdr.e_phoff = @sizeOf(std.elf.Elf64_Ehdr);
        ehdr.e_ehsize = @sizeOf(std.elf.Elf64_Ehdr);
        ehdr.e_phentsize = @sizeOf(std.elf.Elf64_Phdr);
        ehdr.e_phnum = @intCast(self.nphdr);
        @memcpy(self.buf[0..@sizeOf(std.elf.Elf64_Ehdr)], std.mem.asBytes(&ehdr));
        var i: usize = 0;
        while (i < self.nphdr) : (i += 1) {
            const off = @sizeOf(std.elf.Elf64_Ehdr) + i * @sizeOf(std.elf.Elf64_Phdr);
            @memcpy(self.buf[off..][0..@sizeOf(std.elf.Elf64_Phdr)], std.mem.asBytes(&self.phdrs[i]));
        }
        return self.buf[0 .. self.payload_off + self.payload_used];
    }
};

fn rx() u32 {
    return std.elf.PF_R | std.elf.PF_X;
}

fn rw() u32 {
    return std.elf.PF_R | std.elf.PF_W;
}

fn wx() u32 {
    return std.elf.PF_W | std.elf.PF_X;
}

test "parse ET_EXEC x86-64 little-endian" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    const image = f.finish(.EXEC, .X86_64, 0x400000);
    const parsed = try parse(image);
    try std.testing.expectEqual(@as(usize, 0x400000), parsed.entry);
    try std.testing.expectEqual(@as(usize, 1), parsed.nloads);
    try std.testing.expectEqual(@as(usize, 0x400000), parsed.loads[0].map_vaddr);
    try std.testing.expectEqual(page_size, parsed.loads[0].map_size);
    try std.testing.expect(parsed.loads[0].flags.executable);
    try std.testing.expect(!parsed.loads[0].flags.writable);
}

test "reject ET_DYN" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    try std.testing.expectError(error.BadElf, parse(f.finish(.DYN, .X86_64, 0x400000)));
}

test "reject PT_INTERP" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    f.addInterp();
    try std.testing.expectError(error.BadElf, parse(f.finish(.EXEC, .X86_64, 0x400000)));
}

test "reject writable+executable" {
    var f: Fixture = .{};
    f.addLoad(0x400000, wx(), "code", 0, page_size);
    try std.testing.expectError(error.WritableExecutable, parse(f.finish(.EXEC, .X86_64, 0x400000)));
}

test "reject stack window under 0x80000000" {
    var f: Fixture = .{};
    f.addLoad(user_stack_top - page_size, rx(), "code", 0, page_size);
    try std.testing.expectError(error.OutOfRange, parse(f.finish(.EXEC, .X86_64, user_stack_top - page_size)));
}

test "reject kernel half" {
    var f: Fixture = .{};
    f.addLoad(user_space_end, rx(), "code", 0, page_size);
    try std.testing.expectError(error.OutOfRange, parse(f.finish(.EXEC, .X86_64, user_space_end)));
}

test "reject overlapping page-aligned PT_LOAD" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    f.addLoad(0x400800, rw(), "data", 0, page_size);
    try std.testing.expectError(error.AlreadyMapped, parse(f.finish(.EXEC, .X86_64, 0x400000)));
}

test "reject truncated image" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    const image = f.finish(.EXEC, .X86_64, 0x400000);
    try std.testing.expectError(error.BadElf, parse(image[0 .. image.len - 1]));
}

test "reject wrong class endian machine" {
    var f: Fixture = .{};
    f.addLoad(0x400000, rx(), "code", 0, page_size);
    try std.testing.expectError(error.BadElf, parse(f.finish(.EXEC, .@"386", 0x400000)));

    var g: Fixture = .{};
    g.addLoad(0x400000, rx(), "code", 0, page_size);
    const slice = g.finish(.EXEC, .X86_64, 0x400000);
    g.buf[std.elf.EI.DATA] = @intFromEnum(std.elf.DATA.@"2MSB");
    try std.testing.expectError(error.BadElf, parse(g.buf[0..slice.len]));
}

test "load copies filesz, zeros BSS, maps R/W/X" {
    var f: Fixture = .{};
    const text = [_]u8{ 0x90, 0x90, 0x90, 0x90 };
    const data = [_]u8{ 1, 2, 3, 4 };
    f.addLoad(0x400000, rx(), &text, 0, page_size);
    f.addLoad(0x401000, rw(), &data, 12, page_size);
    const image = f.finish(.EXEC, .X86_64, 0x400000);

    var backing: [page_size * 4]u8 = undefined;
    var space: MockSpace = .{ .backing = &backing };
    const entry = try load(&space, image);
    try std.testing.expectEqual(@as(usize, 0x400000), entry);
    try std.testing.expectEqual(@as(usize, 2), space.nmaps);

    const t = space.at(0x400000).?;
    try std.testing.expect(t.flags.executable);
    try std.testing.expect(!t.flags.writable);
    try std.testing.expectEqualSlices(u8, &text, t.bytes[0..text.len]);
    try std.testing.expectEqual(@as(u8, 0), t.bytes[text.len]);

    const d = space.at(0x401000).?;
    try std.testing.expect(d.flags.writable);
    try std.testing.expect(!d.flags.executable);
    try std.testing.expectEqualSlices(u8, &data, d.bytes[0..data.len]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 12, d.bytes[data.len..][0..12]);
}

test "load page-aligns unaligned p_vaddr and zeros the lead" {
    var f: Fixture = .{};
    const text = [_]u8{ 0xcc, 0xcc };
    f.addLoad(0x400010, rx(), &text, 6, 1);
    const image = f.finish(.EXEC, .X86_64, 0x400010);

    var backing: [page_size * 2]u8 = undefined;
    var space: MockSpace = .{ .backing = &backing };
    const entry = try load(&space, image);
    try std.testing.expectEqual(@as(usize, 0x400010), entry);
    const t = space.at(0x400000).?;
    try std.testing.expectEqual(page_size, t.bytes.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 0x10, t.bytes[0..0x10]);
    try std.testing.expectEqualSlices(u8, &text, t.bytes[0x10..][0..2]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 6, t.bytes[0x12..][0..6]);
}
