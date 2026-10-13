const lib = @import("lib");
const sys = lib.sys;

// A u64 is at most 20 digits, and each title is shorter than that.
const spaces = "                    ";
// 256 pages of 4 KiB is 1 MiB.
const pages_per_mib = 256;
const max_cores = 64;

const h_cpu = "cpu";
const h_apic = "apic";
const h_online = "online";
const h_idle = "idle";
const h_tid = "tid";

const Buf = extern struct {
    machine: sys.MachineInfo,
    cores: [max_cores]sys.CoreInfo,
};

fn digits(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

fn printPad(width: usize, len: usize) void {
    if (len < width) lib.print(spaces[0 .. width - len]);
}

fn printCol(text: []const u8, width: usize) void {
    printPad(width, text.len);
    lib.print(text);
}

fn printNum(v: u64, width: usize) void {
    printPad(width, digits(v));
    lib.printU64(v);
}

fn tidLen(tid: u64) usize {
    if (tid == sys.core_none) return 1;
    return digits(tid);
}

pub fn main() u64 {
    var buf: Buf = undefined;
    const bytes: [*]u8 = @ptrCast(&buf);
    const n = sys.cores(bytes[0..@sizeOf(Buf)]);
    if (n < 0) {
        lib.printErr("cores: err ", n);
        return 1;
    }
    const nbytes: usize = @intCast(n);
    if (nbytes < @sizeOf(sys.MachineInfo) or (nbytes - @sizeOf(sys.MachineInfo)) % @sizeOf(sys.CoreInfo) != 0) {
        lib.eprint("cores: bad snapshot\n");
        return 1;
    }
    const count = (nbytes - @sizeOf(sys.MachineInfo)) / @sizeOf(sys.CoreInfo);
    const rows = buf.cores[0..count];

    lib.print(buf.machine.vendor[0..12]);
    lib.print(" family ");
    lib.printU64(buf.machine.family);
    lib.print(" model ");
    lib.printU64(buf.machine.model);
    lib.print(" tsc ");
    if (buf.machine.tsc_hz == 0) {
        lib.print("?");
    } else {
        lib.printU64(buf.machine.tsc_hz / 1_000_000);
        lib.print(" MHz");
    }
    lib.print(" ");
    lib.printU64(buf.machine.usable_pages / pages_per_mib);
    lib.print(" MiB\n");

    var w_cpu: usize = h_cpu.len;
    var w_apic: usize = h_apic.len;
    var w_online: usize = h_online.len;
    var w_idle: usize = h_idle.len;
    var w_tid: usize = h_tid.len;
    for (rows, 0..) |e, i| {
        w_cpu = @max(w_cpu, digits(i));
        w_apic = @max(w_apic, digits(e.apic_id));
        w_online = @max(w_online, digits(e.online));
        w_idle = @max(w_idle, digits(e.idle_tid));
        w_tid = @max(w_tid, tidLen(e.tid));
    }

    printCol(h_cpu, w_cpu);
    lib.print(" ");
    printCol(h_apic, w_apic);
    lib.print(" ");
    printCol(h_online, w_online);
    lib.print(" ");
    printCol(h_idle, w_idle);
    lib.print(" ");
    printCol(h_tid, w_tid);
    lib.print("\n");

    for (rows, 0..) |e, i| {
        printNum(i, w_cpu);
        lib.print(" ");
        printNum(e.apic_id, w_apic);
        lib.print(" ");
        printNum(e.online, w_online);
        lib.print(" ");
        printNum(e.idle_tid, w_idle);
        lib.print(" ");
        if (e.tid == sys.core_none) {
            printCol("-", w_tid);
        } else {
            printNum(e.tid, w_tid);
        }
        lib.print("\n");
    }
    return 0;
}
