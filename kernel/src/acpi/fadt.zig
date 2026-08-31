const logger = std.log.scoped(.fadt);

const std = @import("std");

const acpi = @import("acpi.zig");
const panic = @import("../lib/panic.zig").panic;
const port = @import("../sys/port.zig");

const GenericAddress = extern struct {
    address_space: u8 align(1),
    bit_width: u8 align(1),
    bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),
};

const FADT = extern struct {
    firmware_ctrl: u32 align(1),
    dsdt_addr: u32 align(1),
    reserved_1: u8 align(1),
    preferred_pm_profile: u8 align(1),
    sci_interrupt: u16 align(1),
    smi_cmd_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_ctrl: u8 align(1),
    pm1a_event_block: u32 align(1),
    pm1b_event_block: u32 align(1),
    pm1a_ctrl_block: u32 align(1),
    pm1b_ctrl_block: u32 align(1),
    pm2_ctrl_block: u32 align(1),
    pm_timer_block: u32 align(1),
    gpe0_block: u32 align(1),
    gpe1_block: u32 align(1),
    pm1_event_length: u8 align(1),
    pm1_ctrl_length: u8 align(1),
    pm2_ctrl_length: u8 align(1),
    pm_timer_length: u8 align(1),
    gpe0_length: u8 align(1),
    gpe1_length: u8 align(1),
    gpe1_base: u8 align(1),
    c_state_ctrl: u8 align(1),
    worst_c2_latency: u16 align(1),
    worst_c3_latency: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    boot_arch_flags: u16 align(1),
    reserved_2: u8 align(1),
    flags: u32 align(1),
    reset_reg: GenericAddress align(1),
    reset_value: u8 align(1),
    reserved_3: [3]u8 align(1),
    x_firmware_ctrl: u64 align(1),
    x_dsdt_addr: u64 align(1),
    x_pm1a_event_block: GenericAddress align(1),
    x_pm1b_event_block: GenericAddress align(1),
    x_pm1a_ctrl_block: GenericAddress align(1),
    x_pm1b_ctrl_block: GenericAddress align(1),
    x_pm2_ctrl_block: GenericAddress align(1),
    x_pm_timer_block: GenericAddress align(1),
    x_gpe0_block: GenericAddress align(1),
    x_gpe1_block: GenericAddress align(1),
};

// ACPI spec: FADT Flags bit 20 = HW_REDUCED_ACPI
const hw_reduced_acpi: u32 = 1 << 20;
// SCI_EN in PM1_CNT: platform has entered ACPI mode.
const sci_en: u16 = 1 << 0;
const sci_en_spins: u32 = 0xfffff;

// IAPC_BOOT_ARCH (ACPI 2.0 / FADT revision 3+).
const iapc_legacy_devices: u16 = 1 << 0;
const iapc_8042: u16 = 1 << 1;
const iapc_vga_not_present: u16 = 1 << 2;
const iapc_cmos_rtc_not_present: u16 = 1 << 5;
const fadt_rev_iapc: u8 = 3;

pub const BootArch = struct {
    legacy_devices: bool,
    has_8042: bool,
    vga_not_present: bool,
    cmos_rtc_not_present: bool,
};

pub const Info = struct {
    sci_interrupt: u16,
    smi_cmd_port: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    pm1a_ctrl_block: u32,
    boot_arch: BootArch,
};

var info_value: Info = undefined;
var initialized = false;

pub fn info() Info {
    expectInit();
    return info_value;
}

pub fn bootArch() BootArch {
    return info().boot_arch;
}

pub fn init(sdt: *align(1) const acpi.SDT) !void {
    expectUninit();

    const data = sdt.getData();
    if (data.len < @offsetOf(FADT, "flags") + @sizeOf(u32)) {
        return error.InvalidFadt;
    }

    const fadt: *align(1) const FADT = @ptrCast(data.ptr);
    if (fadt.flags & hw_reduced_acpi != 0) {
        panic("Hardware-reduced ACPI not supported!");
    }

    const boot_arch = parseBootArch(sdt.revision, fadt.boot_arch_flags);
    logger.info("sci={d} smi_cmd=0x{x} 8042={} vga={} rtc={} legacy={}", .{
        fadt.sci_interrupt,
        fadt.smi_cmd_port,
        boot_arch.has_8042,
        !boot_arch.vga_not_present,
        !boot_arch.cmos_rtc_not_present,
        boot_arch.legacy_devices,
    });

    info_value = .{
        .sci_interrupt = fadt.sci_interrupt,
        .smi_cmd_port = fadt.smi_cmd_port,
        .acpi_enable = fadt.acpi_enable,
        .acpi_disable = fadt.acpi_disable,
        .pm1a_ctrl_block = fadt.pm1a_ctrl_block,
        .boot_arch = boot_arch,
    };

    try enableAcpi(fadt);
    initialized = true;
}

fn parseBootArch(revision: u8, flags: u16) BootArch {
    // ACPI 1.0 has no IAPC_BOOT_ARCH; assume a PC with 8042, VGA, RTC.
    if (revision < fadt_rev_iapc) {
        return .{
            .legacy_devices = true,
            .has_8042 = true,
            .vga_not_present = false,
            .cmos_rtc_not_present = false,
        };
    }
    return .{
        .legacy_devices = flags & iapc_legacy_devices != 0,
        .has_8042 = flags & iapc_8042 != 0,
        .vga_not_present = flags & iapc_vga_not_present != 0,
        .cmos_rtc_not_present = flags & iapc_cmos_rtc_not_present != 0,
    };
}

fn enableAcpi(fadt: *align(1) const FADT) !void {
    if (fadt.smi_cmd_port == 0 or fadt.acpi_enable == 0) return;
    if (fadt.smi_cmd_port > std.math.maxInt(u16)) return error.InvalidFadt;

    const smi_cmd: u16 = @intCast(fadt.smi_cmd_port);
    if (inAcpiMode(fadt.pm1a_ctrl_block)) {
        logger.debug("already in ACPI mode", .{});
        return;
    }

    logger.info("enable ACPI mode via SMI_CMD 0x{x}", .{smi_cmd});
    port.outb(smi_cmd, fadt.acpi_enable);
    waitAcpiMode(fadt.pm1a_ctrl_block);
}

fn waitAcpiMode(pm1a_ctrl_block: u32) void {
    if (pm1a_ctrl_block == 0 or pm1a_ctrl_block > std.math.maxInt(u16)) return;
    const pm1a: u16 = @intCast(pm1a_ctrl_block);
    var spins: u32 = 0;
    while (port.inw(pm1a) & sci_en == 0) : (spins += 1) {
        if (spins >= sci_en_spins) {
            logger.err("ACPI enable did not set SCI_EN", .{});
            return;
        }
    }
}

fn inAcpiMode(pm1a_ctrl_block: u32) bool {
    if (pm1a_ctrl_block == 0 or pm1a_ctrl_block > std.math.maxInt(u16)) return false;
    return port.inw(@intCast(pm1a_ctrl_block)) & sci_en != 0;
}

fn expectInit() void {
    if (!initialized) @panic("fadt used before init");
}

fn expectUninit() void {
    if (initialized) @panic("fadt already initialized");
}
