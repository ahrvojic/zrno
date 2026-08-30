const std = @import("std");

const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");
const sched = @import("sched/sched.zig");
const syscall = @import("sys/syscall.zig");
const virt = @import("lib/virt.zig");
const vmm = @import("mm/vmm.zig");

const text_base: usize = 0x400000;
const heap_base: usize = 0x500000;
const msg = "Hello from userspace!\n";

pub fn spawnHello() !u64 {
    const process = try sched.startProcess(heap.kernel_heap.allocator(), true);
    errdefer sched.exitProcess(process, 1);

    const phys = pmm.alloc(1) orelse return error.OutOfMemory;
    const page = virt.toHH([*]u8, phys)[0..pmm.page_size];
    loadImage(page);

    process.vmm.map(
        text_base,
        phys,
        pmm.page_size,
        @bitCast(vmm.Flags{ .present = true, .user = true }),
    ) catch |err| {
        pmm.free(phys, 1);
        return err;
    };

    // Hole: copyToUser demand-maps the message; write() copies it back.
    try process.vmm.copyToUser(heap_base, msg);

    _ = try sched.startUserThread(process, text_base, 0, true);
    return process.pid;
}

fn loadImage(page: []u8) void {
    @memset(page, 0);

    var o: usize = 0;
    o = movImm(page, o, .rax, syscall.nr_write);
    o = movImm(page, o, .rdi, 1);
    o = movAbs(page, o, .rsi, heap_base);
    o = movImm(page, o, .rdx, msg.len);
    o = int80(page, o);
    o = movImm(page, o, .rax, syscall.nr_exit);
    o = movImm(page, o, .rdi, 0);
    o = int80(page, o);
}

const Reg = enum(u8) { rax = 0, rcx = 1, rdx = 2, rbx = 3, rsp = 4, rbp = 5, rsi = 6, rdi = 7 };

fn movImm(page: []u8, o: usize, reg: Reg, value: u64) usize {
    page[o] = 0x48;
    page[o + 1] = 0xc7;
    page[o + 2] = 0xc0 | @intFromEnum(reg);
    std.mem.writeInt(u32, page[o + 3 ..][0..4], @intCast(value), .little);
    return o + 7;
}

fn movAbs(page: []u8, o: usize, reg: Reg, value: usize) usize {
    page[o] = 0x48;
    page[o + 1] = 0xb8 | @intFromEnum(reg);
    std.mem.writeInt(u64, page[o + 2 ..][0..8], @intCast(value), .little);
    return o + 10;
}

fn int80(page: []u8, o: usize) usize {
    page[o] = 0xcd;
    page[o + 1] = 0x80;
    return o + 2;
}
