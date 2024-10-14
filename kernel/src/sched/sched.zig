const logger = std.log.scoped(.sched);

const std = @import("std");

const cpu = @import("../sys/cpu.zig");
const proc = @import("proc.zig");

var processes: std.DoublyLinkedList(proc.Process) = .{};
var current: proc.Process = null;

pub fn init() !void {
    // TODO
}

pub fn schedule(ctx: *cpu.Context) void {
    _ = ctx;
    // TODO
}
