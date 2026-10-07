//! PCI configuration space via ports 0xCF8 and 0xCFC.
//! Firmware has already assigned bus numbers and BARs.

const port = @import("../sys/port.zig");

const addr_port: u16 = 0xcf8;
const data_port: u16 = 0xcfc;

pub const Addr = struct {
    bus: u8,
    dev: u5,
    func: u3,
};

pub fn read32(addr: Addr, offset: u8) u32 {
    port.outl(addr_port, address(addr, offset));
    return port.inl(data_port);
}

pub fn write32(addr: Addr, offset: u8, value: u32) void {
    port.outl(addr_port, address(addr, offset));
    port.outl(data_port, value);
}

fn address(addr: Addr, offset: u8) u32 {
    return 0x80000000 |
        (@as(u32, addr.bus) << 16) |
        (@as(u32, addr.dev) << 11) |
        (@as(u32, addr.func) << 8) |
        (@as(u32, offset) & 0xfc);
}

/// First function whose vendor and device match. Scans every bus firmware
/// enumerated. A missing function 0 skips the rest of that device.
pub fn find(vendor: u16, device: u16) ?Addr {
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            var func: u8 = 0;
            while (func < 8) : (func += 1) {
                const addr = Addr{
                    .bus = @intCast(bus),
                    .dev = @intCast(dev),
                    .func = @intCast(func),
                };
                const id = read32(addr, 0);
                const got: u16 = @truncate(id);
                if (got == 0xffff) {
                    if (func == 0) break;
                    continue;
                }
                const dev_id: u16 = @truncate(id >> 16);
                if (got == vendor and dev_id == device) return addr;
                if (func == 0) {
                    const header: u8 = @truncate(read32(addr, 0x0c) >> 16);
                    if (header & 0x80 == 0) break;
                }
            }
        }
    }
    return null;
}
