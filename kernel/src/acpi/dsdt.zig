const logger = std.log.scoped(.dsdt);

const std = @import("std");

const acpi = @import("acpi.zig");

const aml_name_op: u8 = 0x08;
const aml_package_op: u8 = 0x12;
const aml_zero_op: u8 = 0x00;
const aml_one_op: u8 = 0x01;
const aml_byte_prefix: u8 = 0x0A;

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
    while (i + 5 <= aml.len) : (i += 1) {
        if (aml[i] != aml_name_op) continue;
        if (!std.mem.startsWith(u8, aml[i + 1 ..], "_S5_")) continue;
        return parseS5Package(aml[i + 5 ..]) orelse continue;
    }
    return null;
}

fn parseS5Package(rest: []const u8) ?S5 {
    if (rest.len < 3 or rest[0] != aml_package_op) return null;
    const after_len = skipPkgLength(rest[1..]) orelse return null;
    if (after_len.len < 1 or after_len[0] < 2) return null;
    var elems = after_len[1..];
    const a = parseAmlInt(&elems) orelse return null;
    const b = parseAmlInt(&elems) orelse return null;
    if (a > 7 or b > 7) return null;
    return .{ .slp_typa = @truncate(a), .slp_typb = @truncate(b) };
}

fn skipPkgLength(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const extra = data[0] >> 6;
    if (data.len < 1 + extra) return null;
    return data[1 + extra ..];
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
