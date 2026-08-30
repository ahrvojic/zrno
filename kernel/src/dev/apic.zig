const madt = @import("../acpi/madt.zig");
const BoundedArray = @import("../lib/bounded_array.zig").BoundedArray;
const Lock = @import("../lib/lock.zig");
const pmm = @import("../mm/pmm.zig");
const port = @import("../sys/port.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const pic1_data = 0x21;
const pic2_data = 0xa1;

const ioapic_ver = 0x01;
const ioapic_redir_base = 0x10;
const ioapic_redir_mask = @as(u64, 1) << 16;

var io_apics: BoundedArray(IOApic, madt.max_io_apics) = .{};
var lock: Lock.SpinLock = .{};
var initialized = false;

const IOApic = struct {
    address: u64,
    gsi_base: u32,
    max_redir: u32,

    fn init(address: u32, gsi_base: u32) !@This() {
        try vmm.kernel_vmm.mapMmio(address, pmm.page_size);
        var self: @This() = .{
            .address = virt.toHH(u64, address),
            .gsi_base = gsi_base,
            .max_redir = 0,
        };
        // IOAPICVER bits 16-23: highest redirection-table index
        self.max_redir = (self.read(ioapic_ver) >> 16) & 0xff;
        self.maskAll();
        return self;
    }

    fn ownsGsi(self: *const @This(), gsi: u32) bool {
        return gsi >= self.gsi_base and (gsi - self.gsi_base) <= self.max_redir;
    }

    fn gsiMax(self: *const @This()) u32 {
        return self.gsi_base + self.max_redir;
    }

    fn overlaps(self: *const @This(), other: *const @This()) bool {
        return self.gsi_base <= other.gsiMax() and other.gsi_base <= self.gsiMax();
    }

    fn maskAll(self: *const @This()) void {
        var i: u32 = 0;
        while (i <= self.max_redir) : (i += 1) {
            self.writeRedir(i, ioapic_redir_mask);
        }
    }

    fn route(self: *const @This(), lapic_id: u32, vector: u8, gsi: u32, flags: u16) void {
        const index = gsi - self.gsi_base;
        // Flags: level-triggered (bit 15), active-low (bit 13)
        // N.B. APIC will be unmasked
        const value = @as(u64, vector) | @as(u64, flags & 0b1010) << 12 | @as(u64, lapic_id) << 56;
        self.writeRedir(index, value);
    }

    fn writeRedir(self: *const @This(), index: u32, value: u64) void {
        const offset = ioapic_redir_base + index * 2;
        // High dword first so the entry is not live with a stale destination
        self.write(offset + 1, @truncate(value >> 32));
        self.write(offset + 0, @truncate(value));
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
    expectUninit();

    // Dual 8259 is still live only when MADT PCAT_COMPAT is set.
    // Mask it so IRQs only arrive through the I/O APIC.
    if (madt.pcatCompat()) {
        port.outb(pic1_data, 0xff);
        port.outb(pic2_data, 0xff);
    }

    if (madt.ioApics().len == 0) {
        return error.NoIoApic;
    }

    for (madt.ioApics()) |entry| {
        const io_apic = try IOApic.init(entry.address, entry.gsi_base);
        for (io_apics.slice()) |*existing| {
            if (io_apic.overlaps(existing)) return error.OverlappingIoApic;
        }
        try io_apics.append(io_apic);
    }

    initialized = true;
}

pub fn routeIrq(lapic_id: u32, vector: u8, irq: u8) void {
    expectInit();
    var gsi: u32 = irq;
    var flags: u16 = 0;
    for (madt.ioApicIsos()) |iso| {
        if (iso.irq_source == irq) {
            gsi = iso.gsi;
            flags = iso.flags;
            break;
        }
    }
    routeGsi(lapic_id, vector, gsi, flags);
}

pub fn routeGsi(lapic_id: u32, vector: u8, gsi: u32, flags: u16) void {
    expectInit();
    lock.lock();
    defer lock.unlock();
    const io_apic = findForGsi(gsi) orelse @panic("GSI not owned by any I/O APIC");
    io_apic.route(lapic_id, vector, gsi, flags);
}

fn findForGsi(gsi: u32) ?*const IOApic {
    for (io_apics.slice()) |*io_apic| {
        if (io_apic.ownsGsi(gsi)) return io_apic;
    }
    return null;
}

fn expectInit() void {
    if (!initialized) @panic("apic used before init");
}

fn expectUninit() void {
    if (initialized) @panic("apic already initialized");
}
