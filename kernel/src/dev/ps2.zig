const apic = @import("apic.zig");
const cpu = @import("../sys/cpu.zig");
const debug = @import("../sys/debug.zig");
const interrupts = @import("../sys/interrupts.zig");
const port = @import("../sys/port.zig");

const ps2_data_port = 0x60;

const KeyboardState = enum {
    normal,
    prefix,
};

const KeyModifier = enum {
    alt,
    ctrl,
    shift,
    super,
};

const KeyEvent = struct {
    code: u8,
    state: u8,
};

const kb_buffer_size = 256;
var kb_buffer = [_]?KeyEvent{null} ** kb_buffer_size;
var kb_buffer_pos: usize = 0;

var kb_state = KeyboardState.normal;

pub fn init() !void {
    const lapic_id = cpu.get().lapicId();
    apic.get().routeIrq(lapic_id, interrupts.vec_keyboard, 1);
}

pub fn handleKeyboardInterrupt() void {
    const code = port.inb(ps2_data_port);
    debug.print("Scan code: ");
    debug.printInt(code);
    debug.println("");

    kb_buffer[kb_buffer_pos] = .{
        .code = code,
        .state = 0,
    };

    kb_buffer_pos = (kb_buffer_pos + 1) % kb_buffer_size;
    debug.print("Keyboard buffer position: ");
    debug.printInt(kb_buffer_pos);
    debug.println("");

    updateKeyboardState(code);
}

fn updateKeyboardState(code: u8) void {
    if (code == 0xe0) {
        kb_state = KeyboardState.prefix;
        debug.println("Keyboard state: prefix");
    } else if (kb_state == KeyboardState.prefix) {
        kb_state = KeyboardState.normal;
        debug.println("Keyboard state: normal");
    }
}
