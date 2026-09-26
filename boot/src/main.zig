//! UEFI application. Reads `\boot\kernel` and `\boot\initramfs.tar` from the
//! boot volume, then exits boot services and jumps at the kernel's link
//! address with a higher-half `BootInfo` in `rdi`.

const std = @import("std");
const uefi = std.os.uefi;

const bootinfo = @import("bootinfo");
const elf = @import("elf.zig");
const mmap = @import("mmap.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const File = uefi.protocol.File;
const BootServices = uefi.tables.BootServices;
const MemoryType = uefi.tables.MemoryType;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;

const kernel_path = std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\kernel");
const initrd_path = std.unicode.utf8ToUtf16LeStringLiteral("\\boot\\initramfs.tar");

const stack_pages: usize = 16;
const table_pages: usize = 256;

const Framebuffer = struct {
    phys: u64,
    bytes: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u16,
};

var image_map: mmap.Map = .{};

pub fn main() void {
    serial.init();
    run() catch |err| {
        serial.print("boot failed: {s}\r\n", .{@errorName(err)});
        halt();
    };
}

fn run() !void {
    serial.puts("zrno boot\r\n");

    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    bs.setWatchdogTimer(0, 0, null) catch {};

    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse
        return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    const volume = (try bs.handleProtocol(uefi.protocol.SimpleFileSystem, device)) orelse
        return error.NoFileSystem;
    const root = try volume.openVolume();

    const kernel_file = try readFile(bs, root, kernel_path);
    const image = try elf.parse(kernel_file);
    serial.print("kernel {d} bytes entry=0x{x}\r\n", .{ image.bytes, image.entry });

    const kernel_pages: usize = @intCast(image.bytes / bootinfo.page_size);
    const kernel_mem = try bs.allocatePages(.any, .loader_data, kernel_pages);
    const kernel_dest: [*]u8 = @ptrCast(kernel_mem.ptr);
    @memset(kernel_dest[0..image.bytes], 0);
    try elf.copy(kernel_file, kernel_dest[0..image.bytes]);
    const kernel_phys: u64 = @intFromPtr(kernel_dest);

    const initrd = try readFile(bs, root, initrd_path);
    const initrd_phys: u64 = @intFromPtr(initrd.ptr);
    const initrd_span = std.mem.alignForward(u64, initrd.len, bootinfo.page_size);
    serial.print("initramfs {d} bytes\r\n", .{initrd.len});

    const rsdp = findRsdp() orelse return error.NoRsdp;
    serial.print("rsdp 0x{x}\r\n", .{rsdp});

    const fb = try framebuffer(bs);
    if (fb) |frame| {
        serial.print("fb {d}x{d} pitch={d} phys=0x{x}\r\n", .{
            frame.width, frame.height, frame.pitch, frame.phys,
        });
    } else {
        serial.puts("no framebuffer\r\n");
    }

    const stack_mem = try bs.allocatePages(.any, .loader_data, stack_pages);
    const stack_phys: u64 = @intFromPtr(stack_mem.ptr);
    const stack_bytes: u64 = stack_pages * bootinfo.page_size;
    // SysV entry wants rsp == 8 (mod 16). The allocation is page aligned.
    const stack_top = bootinfo.hhdm_offset + stack_phys + stack_bytes - 8;

    const info_bytes = @sizeOf(bootinfo.BootInfo) + bootinfo.max_entries * @sizeOf(bootinfo.MemEntry);
    const info_pages = (info_bytes + bootinfo.page_size - 1) / bootinfo.page_size;
    const info_mem = try bs.allocatePages(.any, .loader_data, info_pages);
    const info_phys: u64 = @intFromPtr(info_mem.ptr);

    const table_mem = try bs.allocatePages(.any, .loader_data, table_pages);
    var tables: paging.Tables = .{ .pool = table_mem };

    const map_storage = try bs.allocatePool(.loader_data, 64 * 1024);
    const map_buf: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @alignCast(map_storage);

    asm volatile ("cli" ::: .{ .memory = true });

    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        const slice = bs.getMemoryMap(map_buf) catch |err| switch (err) {
            error.BufferTooSmall => return error.MapBuffer,
            else => |e| return e,
        };
        try publish(
            slice,
            rsdp,
            fb,
            kernel_phys,
            image.bytes,
            initrd_phys,
            initrd_span,
            initrd.len,
            info_phys,
        );
        // Allocations above are loader data, so the map already covers them.
        // The framebuffer is often MMIO and is not in that set.
        try installTables(&tables, slice, fb);
        try tables.mapKernel(kernel_phys, image.bytes);

        bs.exitBootServices(uefi.handle, slice.info.key) catch |err| switch (err) {
            error.InvalidParameter => {
                serial.puts("exit boot services retry\r\n");
                continue;
            },
            else => |e| return e,
        };
        break;
    } else return error.ExitBootServices;

    serial.print(
        "jump entry=0x{x} info=0x{x} cr3=0x{x} tables={d}\r\n",
        .{ image.entry, bootinfo.hhdm_offset + info_phys, tables.root, tables.used },
    );
    paging.enter(
        tables.root,
        image.entry,
        bootinfo.hhdm_offset + info_phys,
        stack_top,
    );
}

fn publish(
    slice: MemoryMapSlice,
    rsdp: u64,
    fb: ?Framebuffer,
    kernel_phys: u64,
    kernel_bytes: u64,
    initrd_phys: u64,
    initrd_span: u64,
    initrd_len: usize,
    info_phys: u64,
) !void {
    image_map.len = 0;
    var it = slice.iterator();
    while (it.next()) |desc| {
        const length = std.math.mul(u64, desc.number_of_pages, bootinfo.page_size) catch
            return error.Overflow;
        try image_map.push(.{
            .base = desc.physical_start,
            .length = length,
            .kind = kindOf(desc.type),
        });
    }
    image_map.merge();

    const rsdp_base = pageDown(rsdp);
    try image_map.overlay(rsdp_base, pageUp(rsdp + 64) - rsdp_base, .acpi_reclaimable);
    try image_map.overlay(kernel_phys, kernel_bytes, .modules);
    try image_map.overlay(initrd_phys, initrd_span, .modules);
    if (fb) |frame| {
        const base = pageDown(frame.phys);
        const end = pageUp(frame.phys + frame.bytes);
        try image_map.overlay(base, end - base, .framebuffer);
    }

    const info: *bootinfo.BootInfo = @ptrFromInt(info_phys);
    const entries_phys = info_phys + @sizeOf(bootinfo.BootInfo);
    const entries: [*]bootinfo.MemEntry = @ptrFromInt(entries_phys);
    @memcpy(entries[0..image_map.len], image_map.entries[0..image_map.len]);

    const frame = fb orelse Framebuffer{
        .phys = 0,
        .bytes = 0,
        .width = 0,
        .height = 0,
        .pitch = 0,
        .bpp = 0,
    };
    info.* = .{
        .magic = bootinfo.magic,
        .mmap = @ptrFromInt(bootinfo.hhdm_offset + entries_phys),
        .mmap_count = image_map.len,
        .kernel_phys = kernel_phys,
        .rsdp_phys = rsdp,
        .initramfs_phys = initrd_phys,
        .initramfs_len = initrd_len,
        .fb_phys = frame.phys,
        .fb_width = frame.width,
        .fb_height = frame.height,
        .fb_pitch = frame.pitch,
        .fb_bpp = frame.bpp,
    };
}

fn installTables(tables: *paging.Tables, slice: MemoryMapSlice, fb: ?Framebuffer) !void {
    try tables.reset();
    var it = slice.iterator();
    while (it.next()) |desc| {
        if (!isRam(desc.type)) continue;
        const length = std.math.mul(u64, desc.number_of_pages, bootinfo.page_size) catch
            return error.Overflow;
        const end = std.math.add(u64, desc.physical_start, length) catch return error.Overflow;
        try tables.mapRam(desc.physical_start, end);
    }
    if (fb) |frame| try tables.mapRam(frame.phys, frame.phys + frame.bytes);
}

fn readFile(bs: *BootServices, root: *File, path: [*:0]const u16) ![]u8 {
    const fh = try root.open(path, .read, .{});
    defer fh.close() catch {};

    const info_len = try fh.getInfoSize(.file);
    const info_buf = try bs.allocatePool(.loader_data, info_len);
    const info = try fh.getInfo(.file, @alignCast(info_buf));
    const size: usize = @intCast(info.file_size);
    if (size == 0) return error.EmptyFile;

    const pages = (size + bootinfo.page_size - 1) / bootinfo.page_size;
    const mem = try bs.allocatePages(.any, .loader_data, pages);
    const bytes: [*]u8 = @ptrCast(mem.ptr);
    var off: usize = 0;
    while (off < size) {
        const n = try fh.read(bytes[off..size]);
        if (n == 0) return error.ShortRead;
        off += n;
    }
    return bytes[0..size];
}

fn framebuffer(bs: *BootServices) !?Framebuffer {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse return null;
    const mode = gop.mode;
    const info = mode.info;
    switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color,
        .blue_green_red_reserved_8_bit_per_color,
        => {},
        else => return null,
    }
    if (mode.frame_buffer_base == 0) return null;

    const pitch64 = @as(u64, info.pixels_per_scan_line) * 4;
    if (pitch64 == 0 or pitch64 > std.math.maxInt(u32)) return null;
    const height64: u64 = info.vertical_resolution;
    const row_bytes = std.math.mul(u64, pitch64, height64) catch return error.Overflow;
    const bytes = @max(@as(u64, mode.frame_buffer_size), row_bytes);
    if (info.horizontal_resolution == 0 or height64 == 0) return null;

    return .{
        .phys = mode.frame_buffer_base,
        .bytes = bytes,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = @intCast(pitch64),
        .bpp = 32,
    };
}

fn findRsdp() ?u64 {
    const st = uefi.system_table;
    const tables = st.configuration_table[0..st.number_of_table_entries];
    var acpi1: ?u64 = null;
    for (tables) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            return @intFromPtr(entry.vendor_table);
        }
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) {
            acpi1 = @intFromPtr(entry.vendor_table);
        }
    }
    return acpi1;
}

fn kindOf(kind: MemoryType) bootinfo.MemKind {
    return switch (kind) {
        .conventional_memory, .boot_services_code, .boot_services_data => .usable,
        .loader_code, .loader_data => .reclaim,
        .acpi_reclaim_memory => .acpi_reclaimable,
        .unusable_memory => .bad,
        else => .reserved,
    };
}

fn isRam(kind: MemoryType) bool {
    return switch (kindOf(kind)) {
        .usable, .reclaim, .acpi_reclaimable => true,
        else => false,
    };
}

fn pageDown(value: u64) u64 {
    return value & ~@as(u64, bootinfo.page_size - 1);
}

fn pageUp(value: u64) u64 {
    return (value + bootinfo.page_size - 1) & ~@as(u64, bootinfo.page_size - 1);
}

fn halt() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}
