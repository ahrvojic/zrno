const logger = std.log.scoped(.ivt);

const std = @import("std");

const cpu = @import("cpu.zig");
const debug = @import("../lib/debug.zig");
const panic = @import("../lib/panic.zig").panic;
const ps2 = @import("../dev/ps2.zig");
const sched = @import("../sched/sched.zig");
const vmm = @import("../mm/vmm.zig");

pub const vec_gpf = 13;
pub const vec_page_fault = 14;
pub const vec_pit = 32;
pub const vec_keyboard = 33;
pub const vec_apic_spurious = 255;

export fn interruptDispatch(ctx: *cpu.Context) callconv(.C) void {
    switch (ctx.vector) {
        vec_gpf => {
            printRegisters(ctx);
            panic("General protection fault");
        },
        vec_page_fault => {
            logger.err("Page fault", .{});

            const fault_addr = asm volatile (
                \\mov %%cr2, %[result]
                : [result] "=r" (-> u64),
            );

            const handled = vmm.handlePageFault(fault_addr, ctx.error_code) catch |err| blk: {
                logger.err("Error handling page fault: {s}", .{@errorName(err)});
                break :blk false;
            };

            if (handled) return;

            printRegisters(ctx);
            panic("Unhandled page fault");
        },
        vec_pit => {
            sched.schedule(ctx);
            cpu.bsp.eoi();
        },
        vec_keyboard => {
            logger.info("Keyboard interrupt", .{});
            ps2.handleInterrupt();
            cpu.bsp.eoi();
        },
        vec_apic_spurious => {
            logger.info("APIC spurious interrupt", .{});
            // No EOI
        },
        else => {
            logger.err("Vector {d}", .{ctx.vector});
            printRegisters(ctx);
            panic("Unexpected interrupt");
        },
    }
}

export fn interruptStub() callconv(.Naked) void {
    asm volatile (
        \\push %rax
        \\push %rbx
        \\push %rcx
        \\push %rdx
        \\push %rbp
        \\push %rdi
        \\push %rsi
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\push %r12
        \\push %r13
        \\push %r14
        \\push %r15
        \\
        \\mov %rsp, %rdi
        \\call interruptDispatch
        \\
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rsi
        \\pop %rdi
        \\pop %rbp
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\
        \\addq $16, %rsp
        \\iretq
    );
}

pub const InterruptHandler = *const fn () callconv(.Naked) void;

pub fn makeHandler(comptime vector: u8) InterruptHandler {
    return struct {
        fn handler() callconv(.Naked) void {
            const has_error_code = switch (vector) {
                8 => true,
                10...14 => true,
                17 => true,
                21 => true,
                29 => true,
                30 => true,
                else => false,
            };

            if (comptime has_error_code) {
                asm volatile (
                    \\pushq %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector),
                );
            } else {
                asm volatile (
                    \\pushq $0
                    \\pushq %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector),
                );
            }
        }
    }.handler;
}

fn printRegisters(ctx: *cpu.Context) void {
    const cr2 = asm volatile (
        \\mov %%cr2, %[result]
        : [result] "=r" (-> u64),
    );

    const cr3 = asm volatile (
        \\mov %%cr3, %[result]
        : [result] "=r" (-> u64),
    );

    logger.err("rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}", .{ ctx.rax, ctx.rbx, ctx.rcx, ctx.rdx });
    logger.err("rbp={x:0>16} rdi={x:0>16} rsi={x:0>16} rsp={x:0>16}", .{ ctx.rbp, ctx.rdi, ctx.rsi, ctx.iret_rsp });
    logger.err(" r8={x:0>16}  r9={x:0>16} r10={x:0>16} r11={x:0>16}", .{ ctx.r8, ctx.r9, ctx.r10, ctx.r11 });
    logger.err("r12={x:0>16} r13={x:0>16} r14={x:0>16} r15={x:0>16}", .{ ctx.r12, ctx.r13, ctx.r14, ctx.r15 });
    logger.err("rip={x:0>16} cr2={x:0>16} cr3={x:0>16} err={x:0>16}", .{ ctx.iret_rip, cr2, cr3, ctx.error_code });
}
