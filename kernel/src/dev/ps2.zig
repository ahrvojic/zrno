const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const debug = @import("../sys/debug.zig");
const interrupts = @import("../sys/interrupts.zig");
const port = @import("../sys/port.zig");

pub fn init() !void {
    // TODO
    apic.get().routeIrq(cpu.get().lapicId(), interrupts.vec_keyboard, 1);
}
