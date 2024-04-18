const logger = std.log.scoped(.ivt);

const std = @import("std");

const cpu = @import("cpu.zig");
const debug = @import("../lib/debug.zig");
const panic = @import("../lib/panic.zig").panic;
const pit = @import("../dev/pit.zig");
const ps2 = @import("../dev/ps2.zig");
const vmm = @import("../mm/vmm.zig");

pub const vec_gpf = 13;
pub const vec_page_fault = 14;
pub const vec_pit = 32;
pub const vec_keyboard = 33;
pub const vec_apic_spurious = 255;

const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    vector: u64,
    error_code: u64,

    iret_rip: u64,
    iret_cs: u64,
    iret_flags: u64,
    iret_rsp: u64,
    iret_ss: u64,
};

export fn interruptDispatch(frame: *InterruptFrame) callconv(.C) void {
    switch (frame.vector) {
        vec_gpf => {
            printRegisters(frame);
            panic("General protection fault");
        },
        vec_page_fault => {
            logger.err("Page fault", .{});

            const fault_addr = asm volatile (
                \\mov %%cr2, %[result]
                : [result] "=r" (-> u64)
            );

            const handled = vmm.handlePageFault(fault_addr, frame.error_code) catch |err| blk: {
                logger.err("Error handling page fault: {s}", .{@errorName(err)});
                break :blk false;
            };

            if (handled) return;

            printRegisters(frame);
            panic("Unhandled page fault");
        },
        vec_pit => {
            pit.handleInterrupt();
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
            logger.err("Vector {d}", .{frame.vector});
            printRegisters(frame);
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
                    : [vector] "i" (vector)
                );
            } else {
                asm volatile (
                    \\pushq $0
                    \\pushq %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector)
                );
            }
        }
    }.handler;
}

fn printRegisters(frame: *InterruptFrame) void {
    const cr2 = asm volatile (
        \\mov %%cr2, %[result]
        : [result] "=r" (-> u64)
    );

    const cr3 = asm volatile (
        \\mov %%cr3, %[result]
        : [result] "=r" (-> u64)
    );

    logger.err("rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}", .{frame.rax, frame.rbx, frame.rcx, frame.rdx});
    logger.err("rbp={x:0>16} rdi={x:0>16} rsi={x:0>16} rsp={x:0>16}", .{frame.rbp, frame.rdi, frame.rsi, frame.iret_rsp});
    logger.err(" r8={x:0>16}  r9={x:0>16} r10={x:0>16} r11={x:0>16}", .{frame.r8, frame.r9, frame.r10, frame.r11});
    logger.err("r12={x:0>16} r13={x:0>16} r14={x:0>16} r15={x:0>16}", .{frame.r12, frame.r13, frame.r14, frame.r15});
    logger.err("rip={x:0>16} cr2={x:0>16} cr3={x:0>16} err={x:0>16}", .{frame.iret_rip, cr2, cr3, frame.error_code});
}
