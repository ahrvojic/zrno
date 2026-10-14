const logger = std.log.scoped(.ivt);

const std = @import("std");

const cpu = @import("cpu.zig");
const debug = @import("../lib/debug.zig");
const panic = @import("../lib/panic.zig");
const gdt = @import("gdt.zig");
const lock = @import("lock.zig");
const ps2 = @import("../dev/ps2.zig");
const sched = @import("../sched/sched.zig");
const tty = @import("../dev/tty.zig");
const syscall = @import("syscall.zig");
const vmm = @import("../mm/vmm.zig");

pub const vec_div_error = 0;
pub const vec_nmi = 2;
pub const vec_invalid_opcode = 6;
pub const vec_device_not_available = 7;
pub const vec_double_fault = 8;
pub const vec_stack_segment = 12;
pub const vec_gpf = 13;
pub const vec_page_fault = 14;
pub const vec_machine_check = 18;
pub const vec_timer = 32; // local APIC timer, not ISA IRQ 0
pub const vec_keyboard = 33;
// Software only: must not overlap IOAPIC GSIs (32 + pin) or APIC spurious.
pub const vec_yield = 0x90;
// Fixed IPI. Wakes a core in user mode or `hlt` so it flushes. The handler
// does not take the kernel lock. A core spinning for the lock has IF clear
// and services `CPU.tlb_req` itself.
pub const vec_tlb = 0xf0;
// Fixed IPI. The handler switches off a dying PML4 before it takes the
// kernel lock, then schedules once that thread is stopped.
pub const vec_leave = 0xf1;
pub const vec_apic_spurious = 255;

// IDT IST index (1-7). TSS.ist[index - 1] is the stack pointer.
// NMI is not masked by FMASK.IF. SYSCALL leaves RSP on the user stack for
// one instruction, and IST 0 would push that NMI onto it.
pub const ist_double_fault: u8 = 1;
pub const ist_page_fault: u8 = 2;
pub const ist_nmi: u8 = 3;
comptime {
    std.debug.assert(ist_nmi >= 1 and ist_nmi <= 7);
    std.debug.assert(ist_double_fault >= 1 and ist_double_fault <= 7);
    std.debug.assert(ist_page_fault >= 1 and ist_page_fault <= 7);
    std.debug.assert(ist_nmi != ist_double_fault);
    std.debug.assert(ist_nmi != ist_page_fault);
    std.debug.assert(ist_page_fault != ist_double_fault);
}

export fn interruptDispatch(ctx: *cpu.Context) callconv(.c) void {
    // A panic NMI must not take the lock: the panicking core may hold it.
    if (ctx.vector == vec_nmi and panic.isPanicking()) cpu.halt();
    // Ack the leave, then take the lock. The holder is waiting for the ack
    // and still owns the address space until this returns.
    if (ctx.vector == vec_leave) {
        const self = cpu.current();
        self.serviceTlb();
        const left = cpu.abandon(self);
        self.eoi();
        if (left) {
            const thread = self.thread orelse @panic("leave without thread");
            // `stop` runs after the ack. Service shootdowns while that core
            // still holds the lock.
            while (thread.stopped.load(.acquire) == 0) {
                self.serviceTlb();
                cpu.pause();
            }
            lock.acquire();
            sched.schedule(ctx);
            if (ctx.irqOn()) lock.release();
        }
        return;
    }
    // IF set: user mode or the idle halt, and this core does not hold the
    // lock. IF clear: already inside the kernel (`int 0x90`, a fault during
    // a syscall, a kernel page fault) and the lock stays with this core.
    // A kernel page fault is fatal or a demand fill and must not lock again.
    if (ctx.irqOn()) lock.acquire();
    if (cpu.current().thread) |t| {
        if (t.stopped.load(.acquire) != 0) {
            // The local APIC stays stuck if a timer or keyboard IRQ is dropped.
            switch (ctx.vector) {
                vec_timer, vec_keyboard => cpu.current().eoi(),
                else => {},
            }
            sched.schedule(ctx);
            if (ctx.irqOn()) lock.release();
            return;
        }
    }
    switch (ctx.vector) {
        vec_nmi => fatalException(ctx, "NMI"),
        vec_double_fault => fatalException(ctx, "Double fault"),
        vec_machine_check => fatalException(ctx, "Machine check"),
        vec_page_fault => {
            const fault_addr: usize = @intCast(cpu.readCr2());

            const reason: vmm.FaultReason = @bitCast(ctx.error_code);
            if (!reason.user and sched.isKernelStackGuard(fault_addr)) {
                fatalException(ctx, "Kernel stack overflow");
            } else if (reason.user and sched.isUserStackGuard(fault_addr)) {
                handleException(ctx, "User stack overflow");
            } else if (userDemand(reason) and sched.fillUserPage(fault_addr, reason.write)) {
                // iret runs the faulting instruction again.
            } else {
                handleException(ctx, "Unhandled page fault");
            }
        },
        vec_timer => {
            // Only the bootstrap processor advances the clock and drains
            // serial. Every core still schedules from its own timer.
            const this_cpu = cpu.current();
            if (this_cpu == cpu.bsp()) {
                tty.pollSerial();
                sched.tick(ctx);
            } else {
                sched.schedule(ctx);
            }
            this_cpu.eoi();
        },
        vec_keyboard => {
            if (ps2.handleInterrupt()) {
                sched.schedule(ctx);
            }
            cpu.current().eoi();
        },
        vec_yield => {
            sched.schedule(ctx);
        },
        vec_apic_spurious => {
            logger.info("APIC spurious interrupt", .{});
            // No EOI
        },
        else => {
            // INT3, TF/#DB, BOUND, INTO, AC, x87/SSE: no IDT DPL check.
            if (ctx.vector <= 31) {
                handleException(ctx, exceptionName(ctx.vector));
            } else {
                fatalException(ctx, "Unexpected interrupt");
            }
        },
    }
    // `schedule` may have replaced the frame. Drop the lock only when the
    // context we are about to run has interrupts on.
    if (ctx.irqOn()) lock.release();
}

// Shootdown IPI. Not `interruptDispatch`: that would take the kernel lock,
// and the holder may be waiting for this flush.
pub export fn tlbStub() callconv(.naked) void {
    asm volatile (
        \\push %rax
        \\push %rcx
        \\push %rdx
        \\push %rsi
        \\push %rdi
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\cld
        \\clac
        \\call tlbIpi
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %rax
        \\iretq
    );
}

export fn tlbIpi() callconv(.c) void {
    const this_cpu = cpu.current();
    this_cpu.serviceTlb();
    this_cpu.eoi();
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
        \\cld // DF=0 so user `std` cannot reverse kernel memcpy/memset
        \\clac // AC=0 so user RFLAGS.AC cannot disable SMAP
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

// SYSCALL does not switch stacks. Entry stashes user RSP through GS (the
// running CPU), then loads `syscall_kernel_rsp` (kept equal to TSS.rsp[0]).
// FMASK holds IF off so this is not re-entered. An NMI in that window uses
// `ist_nmi`. GS is already the kernel CPU; entry does not `swapgs`.

// Same `cpu.Context` layout as `interruptStub` (vector/error slots unused).
// SYSRET only if popped RCX is still the frame RIP and popped R11 is still
// the frame RFLAGS. This stub pushed both from those registers. A frame
// `schedule` copied in has the thread's real RCX and R11; SYSRET would
// replace them, so that path IRETs. Non-canonical RIP/RSP (Intel #GP in
// kernel) and kernel/non-user CS/SS also IRET. Kill here so IRETQ never
// sees a non-canonical RSP.
export fn syscallDispatch(ctx: *cpu.Context) callconv(.c) void {
    // User mode does not hold the lock. FMASK already cleared IF.
    lock.acquire();
    // The spin left a dying address space before the lock was granted.
    // `stop` has run; the call must not touch that process.
    if (cpu.current().thread) |t| {
        if (t.stopped.load(.acquire) != 0) {
            sched.schedule(ctx);
            if (ctx.irqOn()) lock.release();
            return;
        }
    }
    if (!sysretFrameOk(ctx)) {
        killUser(ctx, "Non-canonical syscall frame");
    } else {
        syscall.handle(ctx);
        if (!sysretFrameOk(ctx)) {
            killUser(ctx, "Non-canonical syscall frame");
        }
    }
    // `killCurrent` may have switched to another frame. A frame with IF
    // clear is still inside the kernel and keeps the lock.
    if (ctx.irqOn()) lock.release();
}

fn sysretFrameOk(ctx: *const cpu.Context) bool {
    return vmm.userCanonical(ctx.rip) and vmm.userCanonical(ctx.rsp);
}

pub export fn syscallEntry() callconv(.naked) void {
    const user_cs: u64 = gdt.user_code_sel | 3;
    const user_ss: u64 = gdt.user_data_sel | 3;
    const tf_rf: u64 = (1 << 8) | (1 << 16);

    asm volatile (
        \\movq %%rsp, %%gs:cpu_gs_user_rsp
        \\movq %%gs:cpu_gs_kernel_rsp, %%rsp
        \\
        \\pushq %[user_ss]
        \\pushq %%gs:cpu_gs_user_rsp
        \\pushq %%r11
        \\pushq %[user_cs]
        \\pushq %%rcx
        \\
        \\pushq $0
        \\pushq $0
        \\
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rbp
        \\push %%rdi
        \\push %%rsi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\
        \\cld
        \\clac
        \\mov %%rsp, %%rdi
        \\call syscallDispatch
        \\
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rsi
        \\pop %%rdi
        \\pop %%rbp
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\
        \\addq $16, %%rsp
        \\
        \\cmpq %[user_cs], 8(%%rsp)
        \\jne 1f
        \\cmpq %[user_ss], 32(%%rsp)
        \\jne 1f
        \\testq %[tf_rf], 16(%%rsp)
        \\jnz 1f
        \\cmpq (%%rsp), %%rcx // this stub's frame: RCX was RIP, R11 was RFLAGS
        \\jne 1f
        \\cmpq 16(%%rsp), %%r11
        \\jne 1f
        \\movq (%%rsp), %%rcx
        \\sarq $47, %%rcx
        \\jnz 1f
        \\movq 24(%%rsp), %%rcx
        \\sarq $47, %%rcx
        \\jnz 1f
        \\movq (%%rsp), %%rcx
        \\movq 16(%%rsp), %%r11
        \\movq 24(%%rsp), %%rsp
        \\sysretq
        \\1:
        \\iretq
        :
        : [user_ss] "i" (user_ss),
          [user_cs] "i" (user_cs),
          [tf_rf] "i" (tf_rf),
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
            // The immediate must be a non-negative imm32 so sign-extension preserves the vector.
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

fn fromUser(ctx: *const cpu.Context) bool {
    return ctx.cs & 3 == 3;
}

fn exceptionName(vector: u64) []const u8 {
    return switch (vector) {
        vec_div_error => "Divide error",
        1 => "Debug exception",
        3 => "Breakpoint",
        4 => "Overflow",
        5 => "BOUND range exceeded",
        vec_invalid_opcode => "Invalid opcode",
        vec_device_not_available => "Device not available",
        9 => "Coprocessor segment overrun",
        10 => "Invalid TSS",
        11 => "Segment not present",
        vec_stack_segment => "Stack-segment fault",
        vec_gpf => "General protection fault",
        16 => "x87 floating-point exception",
        17 => "Alignment check",
        19 => "SIMD floating-point exception",
        20 => "Virtualization exception",
        21 => "Control protection exception",
        28 => "Hypervisor injection exception",
        29 => "VMM communication exception",
        30 => "Security exception",
        else => "Exception",
    };
}

fn userDemand(reason: vmm.FaultReason) bool {
    return reason.user and !reason.protection and !reason.reserved and !reason.inst_fetch;
}

// CPL 3: stop the process and switch. Kernel faults stay fatal.
fn handleException(ctx: *cpu.Context, message: []const u8) void {
    if (!fromUser(ctx)) fatalException(ctx, message);
    killUser(ctx, message);
}

fn killUser(ctx: *cpu.Context, message: []const u8) void {
    const thread = cpu.current().thread orelse fatalException(ctx, message);
    const process = thread.parent;
    if (process.pid == 0) fatalException(ctx, message);

    // 128+vector: distinguishable from a normal exit(0..127).
    const code: u8 = 128 + @as(u8, @truncate(ctx.vector));
    if (ctx.vector == vec_page_fault) {
        logger.warn("pid {d} {s}: vec={d} err={x:0>16} rip={x:0>16} rsp={x:0>16} cr2={x:0>16} exit={d}", .{
            process.pid, message, ctx.vector, ctx.error_code, ctx.rip, ctx.rsp, cpu.readCr2(), code,
        });
    } else {
        logger.warn("pid {d} {s}: vec={d} err={x:0>16} rip={x:0>16} rsp={x:0>16} exit={d}", .{
            process.pid, message, ctx.vector, ctx.error_code, ctx.rip, ctx.rsp, code,
        });
    }
    sched.killCurrent(ctx, code);
}

fn fatalException(ctx: *cpu.Context, message: []const u8) noreturn {
    printRegisters(ctx);
    @panic(message);
}

fn printRegisters(ctx: *cpu.Context) void {
    const cr2 = cpu.readCr2();
    const cr3 = asm volatile (
        \\mov %%cr3, %[result]
        : [result] "=r" (-> u64),
    );

    // On the double-fault IST. Print and then panic; do not allocate.
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    debug.printTo(&writer, "rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}\r\n", .{ ctx.rax, ctx.rbx, ctx.rcx, ctx.rdx });
    debug.printTo(&writer, "rbp={x:0>16} rdi={x:0>16} rsi={x:0>16} rsp={x:0>16}\r\n", .{ ctx.rbp, ctx.rdi, ctx.rsi, ctx.rsp });
    debug.printTo(&writer, " r8={x:0>16}  r9={x:0>16} r10={x:0>16} r11={x:0>16}\r\n", .{ ctx.r8, ctx.r9, ctx.r10, ctx.r11 });
    debug.printTo(&writer, "r12={x:0>16} r13={x:0>16} r14={x:0>16} r15={x:0>16}\r\n", .{ ctx.r12, ctx.r13, ctx.r14, ctx.r15 });
    debug.printTo(&writer, "rip={x:0>16} cr2={x:0>16} cr3={x:0>16} vec={d} err={x:0>16}\r\n", .{ ctx.rip, cr2, cr3, ctx.vector, ctx.error_code });
    debug.print(writer.buffered());
}
