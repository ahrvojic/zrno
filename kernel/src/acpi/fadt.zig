const std = @import("std");

const acpi = @import("acpi.zig");
const debug = @import("../sys/debug.zig");

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

pub fn init(sdt: *const acpi.SDT) !void {
    const fadt = std.mem.bytesAsValue(FADT, sdt.getData()[0..@sizeOf(FADT)]);
    if (fadt.flags & 0x80000 == 1) {
        debug.panic("Hardware-reduced ACPI not supported!");
    }
}
