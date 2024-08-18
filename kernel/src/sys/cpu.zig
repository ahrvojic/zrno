const logger = std.log.scoped(.cpu);

const std = @import("std");

const boot = @import("boot.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const ivt = @import("ivt.zig");
const virt = @import("../lib/virt.zig");

const msr_lapic = 0x1b;

const lapic_reg_id = 0x20;
const lapic_reg_eoi = 0xb0;
const lapic_reg_spurious = 0xf0;

pub var bsp: CPU = .{};

pub const Context = extern struct {
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

pub const CPU = struct {
    gdt: gdt.GDT = .{},
    tss: gdt.TSS = .{},
    idt: idt.IDT = .{},
    lapic_base: u64 = undefined,

    pub fn init(self: *@This()) void {
        logger.info("Load GDT", .{});
        self.gdt.load(&self.tss);

        logger.info("Load IDT", .{});
        self.idt.load();

        logger.info("Init local APIC", .{});
        self.lapic_base = virt.toHH(u64, readMSR(msr_lapic) & 0xfffff000);
        self.initLapic();
    }

    pub fn eoi(self: *const @This()) void {
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    pub fn lapicId(self: *const @This()) u32 {
        return self.lapicRead(lapic_reg_id);
    }

    fn initLapic(self: *const @This()) void {
        // Spurious interrupt vector register:
        // - Set lowest byte to interrupt vector
        // - Set bit 8 to enable local APIC
        self.lapicWrite(
            lapic_reg_spurious,
            self.lapicRead(lapic_reg_spurious) | ivt.vec_apic_spurious | 0x100
        );
    }

    fn lapicRead(self: *const @This(), reg: u32) u32 {
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }

    fn lapicWrite(self: *const @This(), reg: u32, value: u32) void {
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        ptr.* = value;
    }
};

pub fn init() !void {
    logger.info("Init bootstrap processor", .{});
    bsp.init();
}

pub fn interruptsEnable() callconv(.Inline) void {
    asm volatile ("sti");
}

pub fn interruptsDisable() callconv(.Inline) void {
    asm volatile ("cli");
}

pub fn halt() callconv(.Inline) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

fn readMSR(msr: u32) callconv(.Inline) u64 {
    var high: u32 = undefined;
    var low: u32 = undefined;

    asm volatile (
        \\rdmsr
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (msr),
    );

    return (@as(u64, high) << 32) | low;
}

fn writeMSR(msr: u32, value: u64) callconv(.Inline) void {
    asm volatile (
        \\wrmsr
        :
        : [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
          [_] "{ecx}" (msr),
    );
}
