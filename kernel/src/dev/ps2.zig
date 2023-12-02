const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const debug = @import("../sys/debug.zig");
const interrupts = @import("../sys/interrupts.zig");
const port = @import("../sys/port.zig");

const data_port = 0x60;

pub fn init() !void {
    const lapic_id = cpu.get().lapicId();
    apic.get().routeIrq(lapic_id, interrupts.vec_keyboard, 1);
}

pub fn handleKeyboardInterrupt() void {
    const scancode = port.inb(data_port);
    debug.print("Scancode: ");
    debug.printInt(scancode);
    debug.println("");
}
