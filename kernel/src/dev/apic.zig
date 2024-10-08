const boot = @import("../sys/boot.zig");
const madt = @import("../acpi/madt.zig");
const virt = @import("../lib/virt.zig");

pub var io_apic: IOApic = .{};

const IOApic = struct {
    address: u64 = undefined,
    gsib: u32 = undefined,

    pub fn init(self: *@This()) void {
        // QEMU Q35 machine only has one I/O APIC
        const io_apic_entry = madt.io_apics.get(0);
        self.address = virt.toHH(u64, io_apic_entry.address);
        self.gsib = io_apic_entry.gsib;
    }

    pub fn routeIrq(self: *const @This(), lapic_id: u32, vector: u8, irq: u8) void {
        // Use interrupt source override if exists
        for (madt.io_apic_isos.slice()) |iso| {
            if (iso.irq_source == irq) {
                self.route(lapic_id, vector, iso.gsi, iso.flags);
                return;
            }
        }

        // Otherwise route IRQ directly
        self.route(lapic_id, vector, irq, 0);
    }

    fn route(self: *const @This(), lapic_id: u32, vector: u8, gsi: u32, flags: u16) void {
        // Calculate offset to I/O redirection table entry:
        // - Table starts at 0x10
        // - Add entry distance from global system interrupt base
        // - Two registers per entry
        const offset = 0x10 + (gsi - self.gsib) * 2;

        // Construct redirection entry value
        // Flags: level-triggered (bit 15), active-low (bit 13)
        // N.B. APIC will be unmasked
        const value = @as(u64, @intCast(vector)) | @as(u64, @intCast(flags & 0b1010)) << 12 | @as(u64, @intCast(lapic_id)) << 56;

        self.write(offset + 0, @truncate(value));
        self.write(offset + 1, @truncate(value >> 32));
    }

    fn read(self: *const @This(), offset: u32) u32 {
        @as(*volatile u32, @ptrFromInt(self.address)).* = offset;
        return @as(*volatile u32, @ptrFromInt(self.address + 0x10)).*;
    }

    fn write(self: *const @This(), offset: u32, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.address)).* = offset;
        @as(*volatile u32, @ptrFromInt(self.address + 0x10)).* = value;
    }
};

pub fn init() !void {
    io_apic.init();
}
