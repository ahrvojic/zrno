const logger = std.log.scoped(.ivt);

const std = @import("std");

const cpu = @import("cpu.zig");
const debug = @import("../lib/debug.zig");
const panic = @import("../lib/panic.zig").panic;
const ps2 = @import("../dev/ps2.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const syscall = @import("syscall.zig");
const vmm = @import("../mm/vmm.zig");

pub const vec_div_error = 0;
pub const vec_invalid_opcode = 6;
pub const vec_device_not_available = 7;
pub const vec_double_fault = 8;
pub const vec_stack_segment = 12;
pub const vec_gpf = 13;
pub const vec_page_fault = 14;
pub const vec_pit = 32;
pub const vec_keyboard = 33;
// Software only: must not overlap IOAPIC GSIs (32 + pin) or APIC spurious.
pub const vec_syscall = 0x80;
pub const vec_yield = 0x90;
pub const vec_apic_spurious = 255;

// IDT IST index (1-7). TSS.ist[index - 1] is the stack pointer.
pub const ist_double_fault: u8 = 1;
pub const ist_page_fault: u8 = 2;
comptime {
    std.debug.assert(ist_double_fault >= 1 and ist_double_fault <= 7);
    std.debug.assert(ist_page_fault >= 1 and ist_page_fault <= 7);
    std.debug.assert(ist_page_fault != ist_double_fault);
}

export fn interruptDispatch(ctx: *cpu.Context) callconv(.c) void {
    switch (ctx.vector) {
        vec_div_error => fatalException(ctx, "Divide error"),
        vec_invalid_opcode => fatalException(ctx, "Invalid opcode"),
        vec_device_not_available => fatalException(ctx, "Device not available"),
        vec_double_fault => fatalException(ctx, "Double fault"),
        vec_stack_segment => fatalException(ctx, "Stack-segment fault"),
        vec_gpf => fatalException(ctx, "General protection fault"),
        vec_page_fault => {
            const fault_addr = asm volatile (
                \\mov %%cr2, %[result]
                : [result] "=r" (-> usize),
            );

            const space = if (cpu.current().thread) |thread| &thread.parent.vmm else &vmm.kernel_vmm;
            if (space.handlePageFault(fault_addr, ctx.error_code)) return;

            fatalException(ctx, "Unhandled page fault");
        },
        vec_pit => {
            tty.pollSerial();
            sched.tick(ctx);
            cpu.current().eoi();
        },
        vec_keyboard => {
            if (ps2.handleInterrupt()) {
                sched.schedule(ctx);
            }
            cpu.current().eoi();
        },
        vec_syscall => {
            syscall.handle(ctx);
        },
        vec_yield => {
            sched.schedule(ctx);
        },
        vec_apic_spurious => {
            logger.info("APIC spurious interrupt", .{});
            // No EOI
        },
        else => fatalException(ctx, "Unexpected interrupt"),
    }
}

export fn interruptStub() callconv(.naked) void {
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
        \\addq $16, %rsp // discard vector + error_code
        \\iretq
    );
}

pub const InterruptHandler = *const fn () callconv(.naked) void;

pub fn makeHandler(comptime vector: u8) InterruptHandler {
    return struct {
        fn handler() callconv(.naked) void {
            const has_error_code = switch (vector) {
                vec_double_fault => true,
                10...14 => true,
                17 => true,
                21 => true,
                29 => true,
                30 => true,
                else => false,
            };

            // `push imm8` sign-extends, so vectors >= 128 become 0xff..xx.
            // Force a 32-bit immediate (bit 31 clear) to zero-extend into the u64 slot.
            const vector64: u64 = vector;

            if (comptime has_error_code) {
                asm volatile (
                    \\pushq %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector64),
                );
            } else {
                asm volatile (
                    \\pushq $0
                    \\pushq %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector64),
                );
            }
        }
    }.handler;
}

pub fn interrupt(comptime vector: u8) void {
    asm volatile (
        \\int %[vec]
        :
        : [vec] "i" (vector),
    );
}

fn fatalException(ctx: *cpu.Context, comptime message: []const u8) noreturn {
    printRegisters(ctx);
    panic(message);
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

    // Lock-free: we may already hold the debug lock, or be on the DF IST.
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    debug.printTo(&writer, "rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}\r\n", .{ ctx.rax, ctx.rbx, ctx.rcx, ctx.rdx });
    debug.printTo(&writer, "rbp={x:0>16} rdi={x:0>16} rsi={x:0>16} rsp={x:0>16}\r\n", .{ ctx.rbp, ctx.rdi, ctx.rsi, ctx.rsp });
    debug.printTo(&writer, " r8={x:0>16}  r9={x:0>16} r10={x:0>16} r11={x:0>16}\r\n", .{ ctx.r8, ctx.r9, ctx.r10, ctx.r11 });
    debug.printTo(&writer, "r12={x:0>16} r13={x:0>16} r14={x:0>16} r15={x:0>16}\r\n", .{ ctx.r12, ctx.r13, ctx.r14, ctx.r15 });
    debug.printTo(&writer, "rip={x:0>16} cr2={x:0>16} cr3={x:0>16} vec={d} err={x:0>16}\r\n", .{ ctx.rip, cr2, cr3, ctx.vector, ctx.error_code });
    debug.printUnsafe(writer.buffered());
}
