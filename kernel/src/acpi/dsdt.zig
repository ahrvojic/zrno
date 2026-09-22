const logger = std.log.scoped(.dsdt);

const std = @import("std");

const acpi = @import("acpi.zig");

const aml_name_op: u8 = 0x08;
const aml_package_op: u8 = 0x12;
const aml_zero_op: u8 = 0x00;
const aml_one_op: u8 = 0x01;
const aml_byte_prefix: u8 = 0x0A;
const aml_word_prefix: u8 = 0x0B;
const aml_dword_prefix: u8 = 0x0C;
const aml_root_prefix: u8 = 0x5C;
const aml_parent_prefix: u8 = 0x5E;

// SLP_TYPx from `\_S5_`. 3-bit field in PM1_CNT.
pub const S5 = struct {
    slp_typa: u3,
    slp_typb: u3,
};

var s5_value: ?S5 = null;
var initialized = false;

pub fn s5() ?S5 {
    expectInit();
    return s5_value;
}

pub fn init(phys: ?usize) void {
    expectUninit();
    defer initialized = true;

    const p = phys orelse {
        logger.warn("no DSDT pointer", .{});
        return;
    };
    const sdt = acpi.mapSdt(p, "DSDT") catch |err| {
        logger.warn("DSDT ignored: {s}", .{@errorName(err)});
        return;
    };
    s5_value = parseS5(sdt.getData());
    if (s5_value) |s| {
        logger.info("s5 slp_typ a={d} b={d}", .{ s.slp_typa, s.slp_typb });
    } else {
        logger.warn("no \\_S5_ in DSDT", .{});
    }
}

fn parseS5(aml: []const u8) ?S5 {
    var i: usize = 0;
    while (i < aml.len) : (i += 1) {
        if (aml[i] != aml_name_op) continue;
        // `\_S5_` is NameOp, an optional '\' or '^', then the four-byte name.
        var n = i + 1;
        if (n < aml.len and (aml[n] == aml_root_prefix or aml[n] == aml_parent_prefix)) n += 1;
        if (n + 4 > aml.len or !std.mem.eql(u8, aml[n..][0..4], "_S5_")) continue;
        return parseS5Package(aml[n + 4 ..]) orelse continue;
    }
    return null;
}

fn parseS5Package(rest: []const u8) ?S5 {
    if (rest.len < 1 or rest[0] != aml_package_op) return null;
    const payload = pkgPayload(rest[1..]) orelse return null;
    if (payload.len < 1 or payload[0] < 2) return null;
    var elems = payload[1..];
    const a = parseAmlInt(&elems) orelse return null;
    const b = parseAmlInt(&elems) orelse return null;
    if (a > 7 or b > 7) return null;
    return .{ .slp_typa = @truncate(a), .slp_typb = @truncate(b) };
}

// PkgLength includes its own bytes and excludes PackageOp. Bits 7-6 are the
// follow-byte count. The one-byte form stores the length in bits 5-0; longer
// forms use bits 3-0 and then the follow bytes.
fn pkgPayload(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const extra: usize = data[0] >> 6;
    const header = 1 + extra;
    if (data.len < header) return null;

    const mask: u8 = if (extra == 0) 0x3f else 0x0f;
    var length: usize = data[0] & mask;
    var shift: u6 = 4;
    for (data[1..header]) |byte| {
        length |= @as(usize, byte) << shift;
        shift += 8;
    }
    if (length < header or length > data.len) return null;
    return data[header..length];
}

fn parseAmlInt(ps: *[]const u8) ?u32 {
    const s = ps.*;
    if (s.len == 0) return null;
    switch (s[0]) {
        aml_zero_op => {
            ps.* = s[1..];
            return 0;
        },
        aml_one_op => {
            ps.* = s[1..];
            return 1;
        },
        aml_byte_prefix => {
            if (s.len < 2) return null;
            ps.* = s[2..];
            return s[1];
        },
        aml_word_prefix => {
            if (s.len < 3) return null;
            ps.* = s[3..];
            return std.mem.readInt(u16, s[1..][0..2], .little);
        },
        aml_dword_prefix => {
            if (s.len < 5) return null;
            ps.* = s[5..];
            return std.mem.readInt(u32, s[1..][0..4], .little);
        },
        else => return null,
    }
}

fn expectInit() void {
    if (!initialized) @panic("dsdt used before init");
}

fn expectUninit() void {
    if (initialized) @panic("dsdt already initialized");
}

test "parseS5" {
    const zeros = [_]u8{ aml_name_op, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x06, 4, aml_zero_op, aml_zero_op, aml_zero_op, aml_zero_op };
    try std.testing.expectEqual(S5{ .slp_typa = 0, .slp_typb = 0 }, parseS5(&zeros).?);

    const bytes = [_]u8{ aml_name_op, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x08, 4, aml_byte_prefix, 5, aml_byte_prefix, 7, aml_zero_op, aml_zero_op };
    try std.testing.expectEqual(S5{ .slp_typa = 5, .slp_typb = 7 }, parseS5(&bytes).?);

    try std.testing.expect(parseS5(&[_]u8{ '_', 'S', '5', '_', aml_package_op, 0x06, 2, aml_zero_op, aml_zero_op }) == null);
    try std.testing.expect(parseS5(&[_]u8{ aml_name_op, '_', 'S', '5', '_', 0x00 }) == null);
    const too_big = [_]u8{ aml_name_op, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x06, 2, aml_byte_prefix, 8, aml_zero_op };
    try std.testing.expect(parseS5(&too_big) == null);
}

test "parseS5 accepts a root or parent prefix" {
    const pkg = [_]u8{ aml_package_op, 0x06, 4, aml_zero_op, aml_zero_op, aml_zero_op, aml_zero_op };
    const root = [_]u8{ aml_name_op, aml_root_prefix, '_', 'S', '5', '_' } ++ pkg;
    try std.testing.expectEqual(S5{ .slp_typa = 0, .slp_typb = 0 }, parseS5(&root).?);

    const parent = [_]u8{ aml_name_op, aml_parent_prefix, '_', 'S', '5', '_' } ++ pkg;
    try std.testing.expectEqual(S5{ .slp_typa = 0, .slp_typb = 0 }, parseS5(&parent).?);

    // Same payload with PkgLength 7 stored in two bytes (lead 0x47, follow 0).
    const wide = [_]u8{ aml_name_op, aml_root_prefix, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x47, 0x00, 4, aml_zero_op, aml_zero_op, aml_zero_op, aml_zero_op };
    try std.testing.expectEqual(S5{ .slp_typa = 0, .slp_typb = 0 }, parseS5(&wide).?);
}

test "parseS5 reads word and dword sleep types" {
    const word = [_]u8{ aml_name_op, aml_root_prefix, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x08, 2, aml_word_prefix, 5, 0, aml_word_prefix, 6, 0 };
    try std.testing.expectEqual(S5{ .slp_typa = 5, .slp_typb = 6 }, parseS5(&word).?);

    const dword = [_]u8{ aml_name_op, '_', 'S', '5', '_' } ++ [_]u8{
        aml_package_op, 0x0c, 2,
        aml_dword_prefix, 3, 0, 0, 0,
        aml_dword_prefix, 4, 0, 0, 0,
    };
    try std.testing.expectEqual(S5{ .slp_typa = 3, .slp_typb = 4 }, parseS5(&dword).?);
}

test "parseS5 keeps scanning when the package length excludes an element" {
    // Length 4 covers the count and the WordPrefix byte only. The 0 that
    // would finish the word sits outside the package.
    const short = [_]u8{ aml_name_op, '_', 'S', '5', '_', aml_package_op, 0x04, 2, aml_word_prefix, 5, 0 };
    try std.testing.expect(parseS5(&short) == null);

    const real = [_]u8{ aml_name_op, aml_root_prefix, '_', 'S', '5', '_' } ++
        [_]u8{ aml_package_op, 0x05, 2, aml_one_op, aml_byte_prefix, 2 };
    const both = short ++ real;
    try std.testing.expectEqual(S5{ .slp_typa = 1, .slp_typb = 2 }, parseS5(&both).?);
}
