const logger = std.log.scoped(.cpu);

const std = @import("std");

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const ivt = @import("ivt.zig");
const madt = @import("../acpi/madt.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("../sched/proc.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const msr_lapic = 0x1b;
const rflags_if: u64 = 1 << 9;
const apic_base_x2apic: u64 = 1 << 10;
const apic_base_enable: u64 = 1 << 11;
const apic_base_addr_mask: u64 = ~@as(u64, 0xfff);
const tsc_feature: u32 = 1 << 4;
// x2APIC MSR = 0x800 + (MMIO offset >> 4).
const x2apic_msr_base: u32 = 0x800;

const lapic_reg_id = 0x20;
const lapic_reg_eoi = 0xb0;
const lapic_reg_spurious = 0xf0;
const lapic_reg_lvt_timer = 0x320;
const lapic_reg_timer_icr = 0x380;
const lapic_reg_timer_ccr = 0x390;
const lapic_reg_timer_dcr = 0x3e0;
const lapic_lvt_masked: u32 = 1 << 16;
const lapic_lvt_periodic: u32 = 1 << 17;
const lapic_timer_div16: u32 = 0b0011;
comptime {
    std.debug.assert(x2apic_msr_base + (lapic_reg_id >> 4) == 0x802);
    std.debug.assert(x2apic_msr_base + (lapic_reg_eoi >> 4) == 0x80b);
    std.debug.assert(x2apic_msr_base + (lapic_reg_spurious >> 4) == 0x80f);
    std.debug.assert(x2apic_msr_base + (lapic_reg_lvt_timer >> 4) == 0x832);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_icr >> 4) == 0x838);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_ccr >> 4) == 0x839);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_dcr >> 4) == 0x83e);
}

var bsp_value: CPU = .{};

var vendor: [12]u8 = undefined;
var display_family: u32 = 0;
var display_model: u32 = 0;
var tsc_ok = false;
var tsc_origin: u64 = 0;
var tsc_hz_value: u64 = 0;
var cpu_base_mhz: u32 = 0;

const Cpuid = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

// Layout matches interruptStub: last register pushed is first field,
// then vector/error_code, then the CPU-pushed iretq frame.
pub const Context = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rbp: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,

    vector: u64 = 0,
    error_code: u64 = 0,

    rip: u64 = 0,
    cs: u64 = 0,
    rflags: u64 = 0,
    rsp: u64 = 0,
    ss: u64 = 0,
};

const df_stack_size = 2 * pmm.page_size;
const pf_stack_size = 16 * pmm.page_size;

pub const CPU = struct {
    gdt: gdt.GDT = .{},
    idt: idt.IDT = .{},
    tss: gdt.TSS = .{},
    // Dedicated stacks for #DF / #PF (IST). BSS so they are valid before PMM.
    df_stack: [df_stack_size]u8 align(16) = undefined,
    pf_stack: [pf_stack_size]u8 align(16) = undefined,
    // HH-mapped MMIO; unused when x2apic is set.
    lapic_base: usize = 0,
    x2apic: bool = false,
    thread: ?*proc.Thread = null,
    ncli: u32 = 0,
    intena: bool = false,
    initialized: bool = false,
    lapic_initialized: bool = false,

    pub fn init(self: *CPU) void {
        self.expectUninit();

        // IOPB at the TSS limit means no I/O bitmap (offset 0 would
        // interpret the TSS itself as permission bits).
        self.tss.iopb_offset = @sizeOf(gdt.TSS);

        // IDT IST n uses TSS.ist[n - 1]. Set before LTR so #DF / #PF are
        // safe from the moment the TSS is loaded. #PF has its own stack
        // so the handler (log + map) does not run on a nearly-full kernel stack.
        self.tss.ist[ivt.ist_double_fault - 1] = @intFromPtr(&self.df_stack) + self.df_stack.len;
        self.tss.ist[ivt.ist_page_fault - 1] = @intFromPtr(&self.pf_stack) + self.pf_stack.len;

        self.gdt.load(&self.tss);
        self.idt.load();
        self.initialized = true;
        logger.info("bsp gdt idt tss", .{});
    }

    pub fn initLapic(self: *CPU) !void {
        self.expectInit();
        self.expectLapicUninit();

        const msr = readMSR(msr_lapic);
        self.x2apic = msr & apic_base_x2apic != 0;

        if (self.x2apic) {
            // MMIO is dead. Address field is ignored. Do not clear bit 10.
            if (msr & apic_base_enable == 0) {
                writeMSR(msr_lapic, msr | apic_base_enable);
            }
        } else {
            const phys = madt.lapicAddress();
            const phys64: u64 = @intCast(phys);
            if (phys == 0 or phys64 & ~apic_base_addr_mask != 0) return error.InvalidLapicAddress;
            writeMSR(msr_lapic, (msr & ~apic_base_addr_mask) | phys64 | apic_base_enable);
            try vmm.kernel_vmm.mapMmio(phys, pmm.page_size);
            self.lapic_base = virt.toHH(usize, phys);
        }

        self.enableLapic();

        const id = self.decodeLapicId(self.lapicRead(lapic_reg_id));
        if (id > 0xff) {
            logger.err("apic_id={d} not routable via I/O APIC", .{id});
            return error.LapicIdNotRoutable;
        }
        const entry = madt.find(id, self.x2apic) orelse {
            logger.err("bsp apic_id={d} not in madt", .{id});
            return error.BspNotInMadt;
        };

        var disabled: usize = 0;
        for (madt.lapics()) |lapic| {
            if (!lapic.enabled()) disabled += 1;
        }

        self.lapic_initialized = true;
        if (self.x2apic) {
            logger.info("lapic x2apic id={d} cpu={d} disabled={d}", .{ id, entry.processor_id, disabled });
        } else {
            logger.info("lapic 0x{x} id={d} cpu={d} disabled={d}", .{ madt.lapicAddress(), id, entry.processor_id, disabled });
        }
    }

    pub fn eoi(self: *const CPU) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    pub fn lapicId(self: *const CPU) u32 {
        self.expectLapicInit();
        return self.decodeLapicId(self.lapicRead(lapic_reg_id));
    }

    pub fn lapicTimerCurrent(self: *const CPU) u32 {
        self.expectLapicInit();
        return self.lapicRead(lapic_reg_timer_ccr);
    }

    /// Masked one-shot. Counts down from `initial`; does not interrupt.
    pub fn lapicTimerArm(self: *const CPU, initial: u32) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_timer_dcr, lapic_timer_div16);
        self.lapicWrite(lapic_reg_lvt_timer, @as(u32, ivt.vec_timer) | lapic_lvt_masked);
        self.lapicWrite(lapic_reg_timer_icr, initial);
    }

    pub fn lapicTimerPeriodic(self: *const CPU, initial: u32) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_timer_dcr, lapic_timer_div16);
        self.lapicWrite(lapic_reg_lvt_timer, @as(u32, ivt.vec_timer) | lapic_lvt_periodic);
        self.lapicWrite(lapic_reg_timer_icr, initial);
    }

    fn decodeLapicId(self: *const CPU, raw: u32) u32 {
        // xAPIC ID is bits 24-31; x2APIC ID is the full 32-bit value.
        return if (self.x2apic) raw else raw >> 24;
    }

    fn enableLapic(self: *const CPU) void {
        // Spurious interrupt vector register:
        // - Set lowest byte to interrupt vector
        // - Set bit 8 to enable local APIC
        self.lapicWrite(lapic_reg_spurious, self.lapicRead(lapic_reg_spurious) | ivt.vec_apic_spurious | 0x100);
    }

    fn lapicRead(self: *const CPU, reg: u32) u32 {
        if (self.x2apic) {
            return @truncate(readMSR(x2apic_msr_base + (reg >> 4)));
        }
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }

    fn lapicWrite(self: *const CPU, reg: u32, value: u32) void {
        if (self.x2apic) {
            writeMSR(x2apic_msr_base + (reg >> 4), value);
            return;
        }
        const addr = self.lapic_base + reg;
        const ptr: *align(4) volatile u32 = @ptrFromInt(addr);
        ptr.* = value;
    }

    fn expectInit(self: *const CPU) void {
        if (!self.initialized) @panic("cpu used before init");
    }

    fn expectUninit(self: *const CPU) void {
        if (self.initialized) @panic("cpu already initialized");
    }

    fn expectLapicInit(self: *const CPU) void {
        if (!self.lapic_initialized) @panic("cpu lapic used before init");
    }

    fn expectLapicUninit(self: *const CPU) void {
        if (self.lapic_initialized) @panic("cpu lapic already initialized");
    }
};

pub fn init() !void {
    bsp_value.init();
}

fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile (
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn identify() void {
    if (tsc_origin == 0) tsc_origin = rdtsc();

    const leaf0 = cpuid(0, 0);
    std.mem.writeInt(u32, vendor[0..4], leaf0.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], leaf0.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], leaf0.ecx, .little);

    if (leaf0.eax >= 1) {
        const leaf1 = cpuid(1, 0);
        const fm = familyModel(leaf1.eax);
        display_family = fm.family;
        display_model = fm.model;
        tsc_ok = leaf1.edx & tsc_feature != 0;
    }

    if (tsc_ok and tsc_hz_value == 0) {
        tsc_hz_value = probeTscHz(leaf0.eax);
    }
    if (cpu_base_mhz == 0) {
        cpu_base_mhz = probeCpuBaseMhz(leaf0.eax);
    }
}

pub fn logIdentity() void {
    if (tsc_hz_value != 0 and cpu_base_mhz != 0) {
        logger.info("{s} family={d} model={d} tsc={d} MHz cpu={d} MHz", .{
            vendor,
            display_family,
            display_model,
            tsc_hz_value / 1_000_000,
            cpu_base_mhz,
        });
    } else if (tsc_hz_value != 0) {
        logger.info("{s} family={d} model={d} tsc={d} MHz", .{
            vendor,
            display_family,
            display_model,
            tsc_hz_value / 1_000_000,
        });
    } else if (tsc_ok and cpu_base_mhz != 0) {
        logger.info("{s} family={d} model={d} tsc cpu={d} MHz", .{
            vendor,
            display_family,
            display_model,
            cpu_base_mhz,
        });
    } else if (tsc_ok) {
        logger.info("{s} family={d} model={d} tsc", .{ vendor, display_family, display_model });
    } else if (cpu_base_mhz != 0) {
        logger.info("{s} family={d} model={d} cpu={d} MHz", .{
            vendor,
            display_family,
            display_model,
            cpu_base_mhz,
        });
    } else {
        logger.info("{s} family={d} model={d}", .{ vendor, display_family, display_model });
    }
}

pub fn nsSinceBoot() ?u64 {
    if (tsc_hz_value == 0) return null;
    const delta = rdtsc() -% tsc_origin;
    const hz = tsc_hz_value;
    const sec = delta / hz;
    const rem = delta % hz;
    return sec * 1_000_000_000 + (rem * 1_000_000_000) / hz;
}

fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\pushq %%rbx
        \\cpuid
        \\movl %%ebx, %%r8d
        \\popq %%rbx
        : [eax] "={eax}" (eax),
          [ebx] "={r8d}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn familyModel(eax: u32) struct { family: u32, model: u32 } {
    const family_id = (eax >> 8) & 0xf;
    const model_id = (eax >> 4) & 0xf;
    const ext_model = (eax >> 16) & 0xf;
    const ext_family = (eax >> 20) & 0xff;
    const family = if (family_id == 0xf) family_id + ext_family else family_id;
    const model = if (family_id == 0x6 or family_id == 0xf)
        (ext_model << 4) + model_id
    else
        model_id;
    return .{ .family = family, .model = model };
}

fn probeTscHz(max_leaf: u32) u64 {
    // Leaf 0x15 is TSC / crystal ratio. Leaf 0x16 is CPU base frequency,
    // not TSC frequency — do not use it for timestamps.
    if (max_leaf >= 0x15) {
        const t = cpuid(0x15, 0);
        if (t.eax != 0 and t.ebx != 0 and t.ecx != 0) {
            return (@as(u64, t.ecx) * t.ebx) / t.eax;
        }
    }
    return 0;
}

fn probeCpuBaseMhz(max_leaf: u32) u32 {
    if (max_leaf < 0x16) return 0;
    return cpuid(0x16, 0).eax;
}

pub fn bsp() *CPU {
    return &bsp_value;
}

// BSP until per-CPU identity exists.
pub fn current() *CPU {
    return &bsp_value;
}

pub inline fn interruptsOn() void {
    asm volatile ("sti");
}

pub inline fn interruptsOff() void {
    asm volatile ("cli");
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn idle() void {
    asm volatile ("hlt");
}

pub inline fn halt() noreturn {
    while (true) {
        idle();
    }
}

pub fn pushCli() void {
    const flags = readFlags();
    interruptsOff();
    const this_cpu = current();
    if (this_cpu.ncli == 0) {
        this_cpu.intena = flags & rflags_if != 0;
    }
    this_cpu.ncli += 1;
}

pub fn popCli() void {
    const this_cpu = current();
    if (readFlags() & rflags_if != 0) {
        @panic("popCli with interrupts enabled");
    }
    if (this_cpu.ncli == 0) {
        @panic("popCli underflow");
    }
    this_cpu.ncli -= 1;
    if (this_cpu.ncli == 0 and this_cpu.intena) {
        interruptsOn();
    }
}

inline fn readFlags() u64 {
    return asm volatile (
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
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
