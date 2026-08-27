const std = @import("std");

const sched = @import("sched/sched.zig");
const tty = @import("dev/tty.zig");

pub fn thread(_: u64) callconv(.c) noreturn {
    tty.print("type 'help'\n", .{});
    var buf: [128]u8 = undefined;
    while (true) {
        tty.print("> ", .{});
        run(tty.readLine(&buf));
    }
}

fn run(line: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return;
    if (std.mem.eql(u8, cmd, "help")) {
        help();
    } else if (std.mem.eql(u8, cmd, "ps")) {
        ps();
    } else if (std.mem.eql(u8, cmd, "yield")) {
        sched.yield();
    } else if (std.mem.eql(u8, cmd, "sleep")) {
        sleep(it.next());
    } else if (std.mem.eql(u8, cmd, "echo")) {
        tty.print("{s}\n", .{it.rest()});
    } else {
        tty.print("unknown command: {s}\n", .{cmd});
    }
}

fn help() void {
    tty.print("help          commands\n", .{});
    tty.print("ps            threads\n", .{});
    tty.print("yield         yield the CPU\n", .{});
    tty.print("sleep [ms]    sleep (default 1000)\n", .{});
    tty.print("echo [text]   print arguments\n", .{});
}

fn ps() void {
    var infos: [32]sched.ThreadInfo = undefined;
    const n = sched.copyThreads(&infos);
    tty.print(" tid  pid  status\n", .{});
    for (infos[0..n]) |info| {
        tty.print("{d: >4} {d: >4}  {s}\n", .{ info.tid, info.pid, @tagName(info.status) });
    }
}

fn sleep(arg: ?[]const u8) void {
    const ms: u64 = if (arg) |s| std.fmt.parseInt(u64, s, 10) catch {
        tty.print("usage: sleep [ms]\n", .{});
        return;
    } else 1000;
    sched.sleep(ms);
}
