const logger = std.log.scoped(.pmtimer);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const fadt = @import("../acpi/fadt.zig");
const pmm = @import("../mm/pmm.zig");
const port = @import("../sys/port.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

pub const freq_hz: u64 = 3_579_545;

const tick_spins: u32 = 1_000_000;
const verify_spins: u32 = 1000;

var kind: ?fadt.PmTimer.Kind = null;
var address: u64 = 0;
var mmio_base: usize = 0;
var bits_value: u8 = 24;
var initialized = false;

pub fn init() !void {
    expectUninit();
    defer initialized = true;

    const spec = fadt.pmTimer() orelse {
        logger.info("no PM timer", .{});
        return;
    };

    switch (spec.kind) {
        .io => {
            address = spec.address;
        },
        .memory => {
            const phys: usize = @intCast(spec.address);
            try vmm.kernel_vmm.mapMmio(phys, pmm.page_size);
            mmio_base = virt.toHH(usize, phys);
            address = spec.address;
        },
    }

    bits_value = spec.bits;
    kind = spec.kind;

    const a = readVerified();
    pauseLoop(tick_spins);
    const b = readVerified();
    if (counterDelta(b, a, bits_value) == 0) {
        logger.warn("PM timer is not ticking", .{});
        kind = null;
        mmio_base = 0;
        return;
    }

    switch (spec.kind) {
        .io => logger.info("{d} Hz {d}-bit io=0x{x}", .{ freq_hz, bits_value, spec.address }),
        .memory => logger.info("{d} Hz {d}-bit mmio=0x{x}", .{ freq_hz, bits_value, spec.address }),
    }
}

pub fn present() bool {
    expectInit();
    return kind != null;
}

pub fn bits() u8 {
    expectPresent();
    return bits_value;
}

pub fn read() u32 {
    expectPresent();
    return readVerified();
}

pub fn delta(now: u32, then: u32) u32 {
    expectPresent();
    return counterDelta(now, then, bits_value);
}

fn readVerified() u32 {
    const mask = counterMask(bits_value);
    var spins: u32 = 0;
    while (true) {
        const v1 = readRaw() & mask;
        const v2 = readRaw() & mask;
        const v3 = readRaw() & mask;
        if (readsConsistent(v1, v2, v3)) return v2;
        spins += 1;
        if (spins >= verify_spins) return v2;
    }
}

fn readRaw() u32 {
    return switch (kind.?) {
        .io => port.inl(@intCast(address)),
        .memory => @as(*align(1) volatile u32, @ptrFromInt(mmio_base)).*,
    };
}

fn pauseLoop(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) cpu.pause();
}

fn expectPresent() void {
    if (!present()) @panic("pmtimer used when absent");
}

fn expectInit() void {
    if (!initialized) @panic("pmtimer used before init");
}

fn expectUninit() void {
    if (initialized) @panic("pmtimer already initialized");
}

fn counterMask(width: u8) u32 {
    return switch (width) {
        24 => 0x00ff_ffff,
        32 => 0xffff_ffff,
        else => unreachable,
    };
}

fn counterDelta(now: u32, then: u32, width: u8) u32 {
    return (now -% then) & counterMask(width);
}

// Linux acpi_pm verified-read: retry when the middle sample is an outlier.
fn readsConsistent(v1: u32, v2: u32, v3: u32) bool {
    return !((v1 > v2 and v1 < v3) or (v2 > v3 and v2 < v1) or (v3 > v1 and v3 < v2));
}

test "counterDelta wraps at 24 and 32 bits" {
    try std.testing.expectEqual(@as(u32, 0x20), counterDelta(0x10, 0x00ff_fff0, 24));
    try std.testing.expectEqual(@as(u32, 0x20), counterDelta(0x10, 0xffff_fff0, 32));
    try std.testing.expectEqual(@as(u32, 1), counterDelta(0, 0x00ff_ffff, 24));
    try std.testing.expectEqual(@as(u32, 0), counterDelta(0x123, 0x123, 24));
}

test "counterDelta 24-bit mask ignores high bits" {
    try std.testing.expectEqual(@as(u32, 1), counterDelta(0x0100_0000, 0x00ff_ffff, 24));
}

test "readsConsistent rejects an outlier middle sample" {
    try std.testing.expect(readsConsistent(5, 6, 7));
    try std.testing.expect(readsConsistent(5, 5, 5));
    try std.testing.expect(readsConsistent(5, 1, 2)); // wrap
    try std.testing.expect(!readsConsistent(5, 9, 6));
}