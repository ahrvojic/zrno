const limine = @import("limine");

const debug = @import("../sys/debug.zig");
const madt = @import("../acpi/madt.zig");

const IOApic = struct {
    io_apic_base: u64,

    fn read(self: *const IOApic, offset: u32) u32 {
        @as(*volatile u32, @ptrFromInt(self.address)).* = offset;
        return @as(*volatile u32, @ptrFromInt(self.address + 0x10)).*;
    }

    fn write(self: *const IOApic, offset: u32, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.address)).* = offset;
        @as(*volatile u32, @ptrFromInt(self.address + 0x10)).* = value;
    }
};

pub fn init(hhdm_res: *limine.HhdmResponse) !void {
    var io_apic: IOApic = .{
        // Just take first I/O APIC entry as Q35 machine only has one
        .io_apic_base = madt.io_apics[0].?.address + hhdm_res.offset,
    };

    _ = io_apic; // TODO
}
