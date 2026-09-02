const std = @import("std");

const ramfs = @import("sys/ramfs.zig");
const sched = @import("sched/sched.zig");
const tty = @import("dev/tty.zig");
const user = @import("user.zig");

pub fn thread(_: usize) callconv(.c) noreturn {
    tty.print("type 'help'\n", .{});
    var buf: [128]u8 = undefined;
    while (true) {
        tty.print("> ", .{});
        dispatch(tty.readLine(&buf));
    }
}

fn dispatch(line: []const u8) void {
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
    } else if (std.mem.eql(u8, cmd, "run")) {
        run(it.next());
    } else if (std.mem.eql(u8, cmd, "cat")) {
        cat(it.next());
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
    tty.print("run [path]    spawn a ramfs ELF\n", .{});
    tty.print("cat [path]    print a ramfs file\n", .{});
}

fn run(arg: ?[]const u8) void {
    const path = arg orelse {
        tty.print("usage: run [path]\n", .{});
        return;
    };
    const pid = user.spawnPath(path) catch |err| {
        tty.print("run: {s}\n", .{@errorName(err)});
        return;
    };
    _ = sched.waitProcess(pid) catch {};
}

fn cat(arg: ?[]const u8) void {
    const path = arg orelse {
        tty.print("usage: cat [path]\n", .{});
        return;
    };
    const data = ramfs.lookup(path) orelse {
        tty.print("cat: NoEnt\n", .{});
        return;
    };
    tty.writeBytes(data);
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
