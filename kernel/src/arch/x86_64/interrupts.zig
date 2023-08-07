//! Interrupt handlers

const debug = @import("debug.zig");

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

    vector_number: u64,
    error_code: u64,

    iret_rip: u64,
    iret_cs: u64,
    iret_flags: u64,
    iret_rsp: u64,
    iret_ss: u64,
};

export fn interruptDispatch(frame: *InterruptFrame) callconv(.C) void {
    switch (frame.vector_number) {
        13 => debug.print("General protection fault\r\n"),
        14 => debug.print("Page fault\r\n"),
        else => debug.print("Unexpected interrupt\r\n"),
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
        \\mov %rax, %rsp
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
        \\add $16, %rsp
        \\iretq
    );
}

pub const InterruptHandler = *const fn () callconv(.Naked) void;

pub fn makeHandler(comptime vector_number: usize) InterruptHandler {
    return struct {
        fn handler() callconv(.Naked) void {
            const has_error_code = switch (vector_number) {
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
                    \\push %[vector_number]
                    \\jmp interruptStub
                    :
                    : [vector_number] "i" (vector_number)
                );
            } else {
                asm volatile (
                    \\push $0
                    \\push %[vector_number]
                    \\jmp interruptStub
                    :
                    : [vector_number] "i" (vector_number)
                );
            }
        }
    }.handler;
}
