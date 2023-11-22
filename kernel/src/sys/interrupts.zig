const cpu = @import("cpu.zig");
const debug = @import("debug.zig");

pub const vec_gpf: u8 = 13;
pub const vec_page_fault: u8 = 14;
pub const vec_keyboard: u8 = 33;
pub const vec_apic_spurious: u8 = 255;

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
            debug.panic("General protection fault");
        },
        vec_page_fault => {
            debug.println("Page fault");
            // TODO
        },
        vec_keyboard => {
            debug.println("Keyboard interrupt");
            cpu.get().eoi();
        },
        vec_apic_spurious => {
            debug.println("APIC spurious interrupt");
            // No EOI
        },
        else => {
            debug.panic("Unexpected interrupt");
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
                    \\push %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector)
                );
            } else {
                asm volatile (
                    \\push $0
                    \\push %[vector]
                    \\jmp interruptStub
                    :
                    : [vector] "i" (vector)
                );
            }
        }
    }.handler;
}
