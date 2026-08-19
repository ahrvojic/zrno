const logger = std.log.scoped(.cpu);

const std = @import("std");

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const ivt = @import("ivt.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("../sched/proc.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const msr_lapic = 0x1b;

const lapic_reg_id = 0x20;
const lapic_reg_eoi = 0xb0;
const lapic_reg_spurious = 0xf0;

pub var bsp: CPU = .{};

// Layout matches interruptStub: last register pushed is first field,
// then vector/error_code, then the CPU-pushed iretq frame.
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

    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const CPU = struct {
    gdt: gdt.GDT = .{},
    idt: idt.IDT = .{},
    tss: gdt.TSS = std.mem.zeroes(gdt.TSS),
    lapic_base: u64 = undefined,
    thread: ?*proc.Thread = null,
    initialized: bool = false,
    lapic_initialized: bool = false,

    pub fn init(self: *@This()) void {
        self.expectUninit();

        // IOPB at the TSS limit means no I/O bitmap (offset 0 would
        // interpret the TSS itself as permission bits).
        self.tss.iopb_offset = @sizeOf(gdt.TSS);

        logger.info("Load GDT", .{});
        self.gdt.load(&self.tss);

        logger.info("Load IDT", .{});
        self.idt.load();
        self.initialized = true;
    }

    pub fn initLapic(self: *@This()) !void {
        self.expectInit();
        self.expectLapicUninit();
        logger.info("Init local APIC", .{});
        const phys = readMSR(msr_lapic) & 0xfffff000;
        try vmm.mapMmio(phys, pmm.page_size);
        self.lapic_base = virt.toHH(u64, phys);
        self.enableLapic();
        self.lapic_initialized = true;
    }

    pub fn eoi(self: *const @This()) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    pub fn lapicId(self: *const @This()) u32 {
        self.expectLapicInit();
        // Local APIC ID register: APIC ID is in bits 24-31.
        return self.lapicRead(lapic_reg_id) >> 24;
    }

    fn enableLapic(self: *const @This()) void {
        // Spurious interrupt vector register:
        // - Set lowest byte to interrupt vector
        // - Set bit 8 to enable local APIC
        self.lapicWrite(lapic_reg_spurious, self.lapicRead(lapic_reg_spurious) | ivt.vec_apic_spurious | 0x100);
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

    fn expectInit(self: *const @This()) void {
        if (!self.initialized) @panic("cpu used before init");
    }

    fn expectUninit(self: *const @This()) void {
        if (self.initialized) @panic("cpu already initialized");
    }

    fn expectLapicInit(self: *const @This()) void {
        if (!self.lapic_initialized) @panic("cpu lapic used before init");
    }

    fn expectLapicUninit(self: *const @This()) void {
        if (self.lapic_initialized) @panic("cpu lapic already initialized");
    }
};

pub fn init() !void {
    logger.info("Init bootstrap processor", .{});
    bsp.init();
}

pub fn initLapic() !void {
    try bsp.initLapic();
}

pub inline fn interruptsOn() void {
    asm volatile ("sti");
}

pub inline fn interruptsOff() void {
    asm volatile ("cli");
}

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

inline fn readMSR(msr: u32) u64 {
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

inline fn writeMSR(msr: u32, value: u64) void {
    asm volatile (
        \\wrmsr
        :
        : [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
          [_] "{ecx}" (msr),
    );
}
