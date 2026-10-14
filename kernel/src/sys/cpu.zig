const logger = std.log.scoped(.cpu);

const std = @import("std");

const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const ivt = @import("ivt.zig");
const madt = @import("../acpi/madt.zig");
const pmm = @import("../mm/pmm.zig");
const proc = @import("../sched/proc.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

const msr_lapic = 0x1b;
const msr_gs_base: u32 = 0xc0000101;
const msr_efer = 0xc0000080;
const msr_pat = 0x277;
// Architectural defaults, except index 5 is WC. Framebuffer PTEs select that index.
const pat_wc_at_5: u64 = 0x0007_0106_0007_0406;
const msr_star = 0xc0000081;
const msr_lstar = 0xc0000082;
const msr_fmask = 0xc0000084;
const efer_sce: u64 = 1 << 0;
const syscall_feature: u32 = 1 << 11;
const cr0_mp: u64 = 1 << 1;
const cr0_em: u64 = 1 << 2;
const cr0_ts: u64 = 1 << 3;
const cr0_ne: u64 = 1 << 5;
const cr0_wp: u64 = 1 << 16;
const cr4_osfxsr: u64 = 1 << 9;
const cr4_osxmmexcpt: u64 = 1 << 10;
// Gates `wrgsbase` / `rdgsbase` only. `%gs:disp` and `WRMSR` do not need it.
const cr4_fsgsbase: u64 = 1 << 16;
const cr4_osxsave: u64 = 1 << 18;
const cr4_smep: u64 = 1 << 20;
const cr4_smap: u64 = 1 << 21;
// CPUID.1:EDX
const fpu_feature: u32 = 1 << 0;
const fxsr_feature: u32 = 1 << 24;
const sse_feature: u32 = 1 << 25;
// CPUID.1:ECX
const xsave_feature: u32 = 1 << 26;
const avx_feature: u32 = 1 << 28;
// CPUID.7.0:EBX
const smep_feature: u32 = 1 << 7;
const smap_feature: u32 = 1 << 20;
const rflags_tf: u64 = 1 << 8;
const rflags_if: u64 = 1 << 9;
const rflags_df: u64 = 1 << 10;
const rflags_iopl: u64 = 3 << 12;
const rflags_nt: u64 = 1 << 14;
const rflags_ac: u64 = 1 << 18;
const syscall_fmask: u64 = rflags_tf | rflags_if | rflags_df | rflags_iopl | rflags_nt | rflags_ac;
const apic_base_x2apic: u64 = 1 << 10;
const apic_base_enable: u64 = 1 << 11;
const apic_base_addr_mask: u64 = ~@as(u64, 0xfff);
const tsc_feature: u32 = 1 << 4;
// x2APIC MSR = 0x800 + (MMIO offset >> 4).
const x2apic_msr_base: u32 = 0x800;

/// `CPU.tlb_req` value that reloads CR3 instead of invalidating one page.
pub const tlb_flush_all: u64 = 1;

const lapic_reg_id = 0x20;
const lapic_reg_eoi = 0xb0;
const lapic_reg_spurious = 0xf0;
// xAPIC command. x2APIC uses one MSR at 0x800 + (0x300 >> 4).
const lapic_reg_icr_low = 0x300;
const lapic_reg_icr_high = 0x310;
const icr_delivery_status: u32 = 1 << 12;
// Fixed delivery ignores the trigger bit. Level must be assert.
const icr_level_assert: u32 = 1 << 14;
const icr_trigger_level: u32 = 1 << 15;
const icr_dm_nmi: u32 = 4 << 8;
const icr_dm_init: u32 = 5 << 8;
const icr_dm_startup: u32 = 6 << 8;
const lapic_reg_lvt_timer = 0x320;
const lapic_reg_lvt_lint0 = 0x350;
const lapic_reg_lvt_lint1 = 0x360;
const lapic_reg_timer_icr = 0x380;
const lapic_reg_timer_ccr = 0x390;
const lapic_reg_timer_dcr = 0x3e0;
const lapic_lvt_masked: u32 = 1 << 16;
const lapic_lvt_periodic: u32 = 1 << 17;
// Delivery mode NMI (bits 8-10). Vector field is ignored.
const lapic_lvt_nmi: u32 = 0b100 << 8;
const lapic_timer_div16: u32 = 0b0011;
comptime {
    std.debug.assert(x2apic_msr_base + (lapic_reg_id >> 4) == 0x802);
    std.debug.assert(x2apic_msr_base + (lapic_reg_eoi >> 4) == 0x80b);
    std.debug.assert(x2apic_msr_base + (lapic_reg_spurious >> 4) == 0x80f);
    std.debug.assert(x2apic_msr_base + (lapic_reg_lvt_timer >> 4) == 0x832);
    std.debug.assert(x2apic_msr_base + (lapic_reg_lvt_lint0 >> 4) == 0x835);
    std.debug.assert(x2apic_msr_base + (lapic_reg_lvt_lint1 >> 4) == 0x836);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_icr >> 4) == 0x838);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_ccr >> 4) == 0x839);
    std.debug.assert(x2apic_msr_base + (lapic_reg_timer_dcr >> 4) == 0x83e);
    std.debug.assert(x2apic_msr_base + (lapic_reg_icr_low >> 4) == 0x830);
}

var cpus: std.DoublyLinkedList = .{};
/// Initial count `timer.init` programmed on the bootstrap processor.
/// Application processors use the same value once the scheduler is live.
var lapic_icr_value: u32 = 0;

var bsp_value: CPU = .{};

comptime {
    // `CPU` has no fixed layout, so a field cannot be exported. These
    // absolute symbols are GS displacements of the running CPU.
    asm (std.fmt.comptimePrint(
            \\.globl cpu_gs_self
            \\.globl cpu_gs_user_rsp
            \\.globl cpu_gs_kernel_rsp
            \\cpu_gs_self = {d}
            \\cpu_gs_user_rsp = {d}
            \\cpu_gs_kernel_rsp = {d}
        , .{
            @offsetOf(CPU, "this"),
            @offsetOf(CPU, "syscall_user_rsp"),
            @offsetOf(CPU, "syscall_kernel_rsp"),
        }));
}

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

    pub fn irqOn(self: *const Context) bool {
        return self.rflags & rflags_if != 0;
    }
};

const nmi_stack_size = 2 * pmm.page_size;
const df_stack_size = 2 * pmm.page_size;
const pf_stack_size = 16 * pmm.page_size;

pub const DoomedStack = struct { phys: usize, base: usize };

pub const CPU = struct {
    /// `IA32_GS_BASE` points here. `current` reads this field as `%gs:cpu_gs_self`.
    /// A user `mov` to GS would replace the base. Userspace does not load GS.
    this: *CPU = undefined,
    /// User RSP saved by `syscallEntry`, and the kernel stack it switches to.
    /// Entry reads both as `%gs:disp`. `kernel_rsp` matches `tss.rsp[0]`.
    syscall_user_rsp: u64 = 0,
    syscall_kernel_rsp: u64 = 0,
    gdt: gdt.GDT = .{},
    idt: idt.IDT = .{},
    tss: gdt.TSS = .{},
    // Dedicated stacks for NMI / #DF / #PF (IST). BSS so they are valid before PMM.
    // NMI must not share the page-fault stack: a fault during NMI reloads that IST.
    nmi_stack: [nmi_stack_size]u8 align(16) = undefined,
    df_stack: [df_stack_size]u8 align(16) = undefined,
    pf_stack: [pf_stack_size]u8 align(16) = undefined,
    // HH-mapped MMIO; unused when x2apic is set.
    lapic_base: usize = 0,
    x2apic: bool = false,
    thread: ?*proc.Thread = null,
    /// Kernel stack of a thread that exited while still running on it.
    doomed_stack: ?DoomedStack = null,
    /// PML4 of an address space that exited while CR3 still pointed at it.
    doomed_pt: ?usize = null,
    /// Shootdown request. 0 means none. `tlb_flush_all` reloads CR3. Any
    /// other value is a virtual address for `invlpg` (not page 0). Cleared
    /// only after the flush. The lock spinner and `vec_tlb` both run
    /// `serviceTlb`; doing it twice is harmless. `shootdown` is the writer.
    tlb_req: std.atomic.Value(u64) = .init(0),
    /// PML4 in CR3. 0 before the first `schedule`. `schedule` stores it after
    /// the CR3 write. `abandon` stores the kernel root without the lock.
    loaded_pt: std.atomic.Value(usize) = .init(0),
    /// PML4 this core must leave. 0 means none. Cleared only after CR3 no
    /// longer holds it. `vec_leave` and the lock spinner both run `abandon`.
    leave_pt: std.atomic.Value(usize) = .init(0),
    node: std.DoublyLinkedList.Node = .{},
    /// This core's idle thread. Not on the run queue.
    idle: ?*proc.Thread = null,
    /// Local-APIC id the bootstrap processor targeted. Checked at entry.
    expected_apic_id: u32 = 0,
    /// Id read on this core. The local APIC register is not reachable from another core.
    apic_id: u32 = 0,
    /// 1 once this core's local APIC is up and it is waiting for the scheduler.
    online: std.atomic.Value(u8) = .init(0),
    initialized: bool = false,
    lapic_initialized: bool = false,

    pub fn init(self: *CPU) void {
        self.expectUninit();

        // IOPB at the TSS limit means no I/O bitmap (offset 0 would
        // interpret the TSS itself as permission bits).
        self.tss.iopb_offset = @sizeOf(gdt.TSS);

        // IDT IST n uses TSS.ist[n - 1]. Set before LTR so NMI / #DF / #PF are
        // safe from the moment the TSS is loaded. #PF has its own stack
        // so the handler does not run on a nearly-full kernel stack.
        self.tss.ist[ivt.ist_nmi - 1] = @intFromPtr(&self.nmi_stack) + self.nmi_stack.len;
        self.tss.ist[ivt.ist_double_fault - 1] = @intFromPtr(&self.df_stack) + self.df_stack.len;
        self.tss.ist[ivt.ist_page_fault - 1] = @intFromPtr(&self.pf_stack) + self.pf_stack.len;

        self.gdt.load(&self.tss);
        // After `lgdt`. `gdt.reload` does not write FS or GS, which would
        // zero the base installed here. Before `lidt`, so a handler that
        // calls `current` already has a CPU pointer.
        self.bindGs();
        self.idt.load();
        enableSyscall();
        enableProtections();
        writeMSR(msr_pat, pat_wc_at_5);
        enableFpu();
        self.initialized = true;
        cpus.append(&self.node);
        if (bootLogging()) logger.info("bsp gdt idt tss gs syscall wp smep smap xsave", .{});
    }

    /// GDT, IDT, and this core's local APIC. No heap, and no serial: the
    /// bootstrap processor still holds the kernel lock. The xAPIC window is
    /// already mapped. The timer stays masked.
    pub fn bootApplication(self: *CPU) void {
        self.init();
        self.finishApic();
    }

    /// Publish `self` as the GS base. Clears the selector first: a non-null
    /// GS from firmware is a GDT base, and loading null does not change the
    /// hidden base that `WRMSR` then sets.
    fn bindGs(self: *CPU) void {
        self.this = self;
        asm volatile (
            \\mov %%ax, %%gs
            :
            : [_] "{eax}" (@as(u32, 0)),
            : .{ .memory = true });
        writeMSR(msr_gs_base, @intFromPtr(self));
    }

    /// IRQ and SYSCALL kernel stack top. `TSS.rsp[0]` for privilege-changing
    /// interrupts; `syscall_kernel_rsp` for `syscallEntry` (SYSCALL does not
    /// switch stacks).
    pub fn setIrqStack(self: *CPU, top: u64) void {
        self.tss.rsp[0] = top;
        self.syscall_kernel_rsp = top;
    }

    /// Apply this core's shootdown request, if any. Does not take the kernel
    /// lock. The spinner calls it with IF clear; `vec_tlb` calls it from user
    /// mode or `hlt`.
    pub fn serviceTlb(self: *CPU) void {
        while (true) {
            const req = self.tlb_req.load(.acquire);
            if (req == 0) return;
            if (req == tlb_flush_all) {
                reloadCr3();
            } else {
                invlpg(req);
            }
            // Ack this value only. A request stored after the load stays up.
            _ = self.tlb_req.cmpxchgStrong(req, 0, .release, .acquire);
        }
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
        self.apic_id = id;
        if (id > 0xff) {
            logger.err("apic_id={d} not routable via I/O APIC", .{id});
            return error.LapicIdNotRoutable;
        }
        const entry = madt.find(id, self.x2apic) orelse {
            logger.err("bsp apic_id={d} not in madt", .{id});
            return error.BspNotInMadt;
        };

        self.programLintNmis(entry.processor_id);

        self.lapic_initialized = true;
        if (self.x2apic) {
            logger.info("lapic x2apic id={d} cpu={d}", .{ id, entry.processor_id });
        } else {
            logger.info("lapic 0x{x} id={d} cpu={d}", .{ madt.lapicAddress(), id, entry.processor_id });
        }
    }

    /// Local APIC for a core the bootstrap processor already mapped.
    /// Does not call `mapMmio` and does not log.
    fn finishApic(self: *CPU) void {
        self.expectInit();
        self.expectLapicUninit();
        self.adoptApicBase();
        self.enableLapic();
        self.lapicWrite(lapic_reg_lvt_timer, lapic_lvt_masked);
        const id = self.decodeLapicId(self.lapicRead(lapic_reg_id));
        self.apic_id = id;
        if (id != self.expected_apic_id) @panic("ap apic id mismatch");
        const entry = madt.find(id, self.x2apic) orelse @panic("ap not in madt");
        self.programLintNmis(entry.processor_id);
        self.lapic_initialized = true;
    }

    fn adoptApicBase(self: *CPU) void {
        self.x2apic = bsp_value.x2apic;
        self.lapic_base = bsp_value.lapic_base;
        const base = readMSR(msr_lapic);
        if (bsp_value.x2apic) {
            if (base & apic_base_x2apic == 0) {
                const enabled = (base & ~apic_base_addr_mask) | apic_base_enable;
                writeMSR(msr_lapic, enabled);
                writeMSR(msr_lapic, enabled | apic_base_x2apic);
            } else if (base & apic_base_enable == 0) {
                writeMSR(msr_lapic, base | apic_base_enable);
            }
            return;
        }
        if (base & apic_base_x2apic != 0) @panic("ap x2apic while bsp is xapic");
        const phys: u64 = @intCast(madt.lapicAddress());
        writeMSR(msr_lapic, (base & ~apic_base_addr_mask) | phys | apic_base_enable);
    }

    pub fn eoi(self: *const CPU) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_eoi, 0);
    }

    /// Fixed IPI to `dest` (physical local-APIC id). ICR high is the xAPIC
    /// destination; x2APIC packs it into the high half of MSR 0x830.
    fn sendIpi(self: *const CPU, dest: u32, vector: u8) void {
        self.sendIcr(dest, @as(u32, vector) | icr_level_assert);
    }

    /// INIT, then on xAPIC an INIT deassert, then two SIPIs of `vector`
    /// (trampoline page number). x2APIC has no INIT deassert.
    pub fn startupIpi(self: *const CPU, dest: u32, vector: u8) void {
        self.sendIcr(dest, icr_dm_init | icr_level_assert | icr_trigger_level);
        delayUs(10_000);
        if (!self.x2apic) {
            self.sendIcr(dest, icr_dm_init | icr_trigger_level);
            delayUs(200);
        }
        const sipi: u32 = @as(u32, vector) | icr_dm_startup | icr_level_assert;
        self.sendIcr(dest, sipi);
        delayUs(200);
        self.sendIcr(dest, sipi);
    }

    fn sendIcr(self: *const CPU, dest: u32, command: u32) void {
        self.expectLapicInit();
        if (self.x2apic) {
            writeMSR(x2apic_msr_base + (lapic_reg_icr_low >> 4), (@as(u64, dest) << 32) | command);
            return;
        }
        while (self.lapicRead(lapic_reg_icr_low) & icr_delivery_status != 0) pause();
        self.lapicWrite(lapic_reg_icr_high, dest << 24);
        self.lapicWrite(lapic_reg_icr_low, command);
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
        self.programTimer(lapic_lvt_masked, initial);
    }

    pub fn lapicTimerPeriodic(self: *const CPU, initial: u32) void {
        lapic_icr_value = initial;
        self.programTimer(lapic_lvt_periodic, initial);
    }

    fn programTimer(self: *const CPU, lvt: u32, initial: u32) void {
        self.expectLapicInit();
        self.lapicWrite(lapic_reg_timer_dcr, lapic_timer_div16);
        self.lapicWrite(lapic_reg_lvt_timer, @as(u32, ivt.vec_timer) | lvt);
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

    fn programLintNmis(self: *const CPU, acpi_id: u32) void {
        // Firmware leaves LINT0 as ExtINT (virtual 8259). I/O APIC owns IRQs.
        self.lapicWrite(lapic_reg_lvt_lint0, lapic_lvt_masked);
        self.lapicWrite(lapic_reg_lvt_lint1, lapic_lvt_masked);

        for (madt.lapicNmis()) |nmi| {
            if (nmi.lint > 1) {
                if (bootLogging()) logger.warn("nmi lint={d} ignored", .{nmi.lint});
                continue;
            }
            if (!nmi.appliesTo(acpi_id)) continue;
            const reg: u32 = if (nmi.lint == 0) lapic_reg_lvt_lint0 else lapic_reg_lvt_lint1;
            // MPS INTI: bit 1 active-low (LVT 13), bit 3 level (LVT 15). Same packing as I/O APIC.
            const value = lapic_lvt_nmi | (@as(u32, nmi.flags & 0b1010) << 12);
            self.lapicWrite(reg, value);
            if (bootLogging()) logger.info("nmi lint={d} flags=0x{x}", .{ nmi.lint, nmi.flags });
        }
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

fn enableSyscall() void {
    const ext = cpuid(0x80000000, 0);
    if (ext.eax < 0x80000001) @panic("syscall not supported");
    if (cpuid(0x80000001, 0).edx & syscall_feature == 0) @panic("syscall not supported");

    writeMSR(msr_efer, readMSR(msr_efer) | efer_sce);
    writeMSR(msr_star, (@as(u64, gdt.star_user) << 48) | (@as(u64, gdt.kernel_code_sel) << 32));
    writeMSR(msr_lstar, @intFromPtr(&ivt.syscallEntry));
    writeMSR(msr_fmask, syscall_fmask);
    if (bootLogging()) logger.info("syscall lstar=0x{x} star_user=0x{x}", .{ @intFromPtr(&ivt.syscallEntry), gdt.star_user });
}

fn enableProtections() void {
    if (cpuid(0, 0).eax < 7) @panic("smep not supported");
    const ebx = cpuid(7, 0).ebx;
    if (ebx & smep_feature == 0) @panic("smep not supported");
    if (ebx & smap_feature == 0) @panic("smap not supported");

    writeCr0(readCr0() | cr0_wp);
    // `wrgsbase` stays disabled. Entry uses `%gs:disp`, not `swapgs`.
    writeCr4((readCr4() | cr4_smep | cr4_smap) & ~cr4_fsgsbase);
    if (bootLogging()) logger.info("wp smep smap", .{});
}

fn enableFpu() void {
    if (cpuid(0, 0).eax < 1) @panic("fpu not supported");
    const leaf1 = cpuid(1, 0);
    if (leaf1.edx & fpu_feature == 0) @panic("fpu not supported");
    if (leaf1.edx & fxsr_feature == 0) @panic("fxsr not supported");
    if (leaf1.edx & sse_feature == 0) @panic("sse not supported");
    if (leaf1.ecx & xsave_feature == 0) @panic("xsave not supported");
    if (leaf1.ecx & avx_feature == 0) @panic("avx not supported");
    if (cpuid(0, 0).eax < 0xd) @panic("xsave not supported");
    const xstate = cpuid(0xd, 0);
    if (xstate.eax & fpu.xcr0_mask != fpu.xcr0_mask) @panic("avx not supported");

    writeCr0((readCr0() | cr0_mp | cr0_ne) & ~(cr0_em | cr0_ts));
    writeCr4(readCr4() | cr4_osfxsr | cr4_osxmmexcpt | cr4_osxsave);
    xsetbv(0, fpu.xcr0_mask);

    const xsave_bytes = cpuid(0xd, 0).ebx;
    if (xsave_bytes == 0 or xsave_bytes > fpu.state_size) @panic("xsave area too large");

    asm volatile ("fninit");
    var mxcsr: u32 = fpu.mxcsr_default;
    asm volatile (
        \\ldmxcsr (%[ptr])
        :
        : [ptr] "r" (&mxcsr),
        : .{ .memory = true });
    if (bootLogging()) logger.info("mp ne osfxsr osxmmexcpt osxsave xcr0=0x{x} xsave={d}", .{ fpu.xcr0_mask, xsave_bytes });
}

pub const FpuState = fpu.State;

pub fn saveFpu(state: *FpuState) void {
    xsaveOp(false, state);
}

pub fn restoreFpu(state: *const FpuState) void {
    xsaveOp(true, state);
}

fn xsaveOp(comptime restore: bool, ptr: *const FpuState) void {
    std.debug.assert(std.mem.isAligned(@intFromPtr(ptr), fpu.state_align));
    const lo: u32 = @truncate(fpu.xcr0_mask);
    const hi: u32 = @truncate(fpu.xcr0_mask >> 32);
    if (restore) {
        asm volatile (
            \\xrstor (%[ptr])
            :
            : [ptr] "r" (ptr),
              [_] "{eax}" (lo),
              [_] "{edx}" (hi),
            : .{ .memory = true });
    } else {
        asm volatile (
            \\xsave (%[ptr])
            :
            : [ptr] "r" (ptr),
              [_] "{eax}" (lo),
              [_] "{edx}" (hi),
            : .{ .memory = true });
    }
}

fn xsetbv(reg: u32, value: u64) void {
    asm volatile (
        \\xsetbv
        :
        : [_] "{ecx}" (reg),
          [_] "{eax}" (@as(u32, @truncate(value))),
          [_] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

pub fn tscHz() u64 {
    return tsc_hz_value;
}

pub const MachineSnap = struct {
    vendor: [12]u8,
    family: u32,
    model: u32,
    tsc_hz: u64,
    usable_pages: usize,
};

pub fn machineSnap() MachineSnap {
    return .{
        .vendor = vendor,
        .family = display_family,
        .model = display_model,
        .tsc_hz = tsc_hz_value,
        .usable_pages = pmm.usablePages(),
    };
}

/// `snapshotCores` writes this when `CPU.thread` is null. Not a tid.
pub const no_tid: u64 = ~@as(u64, 0);

pub const CoreSnap = struct {
    apic_id: u32,
    online: bool,
    idle_tid: u64,
    tid: u64,
};

/// Walk order. The bootstrap processor is first. `online` is the local
/// APIC, not `CPU.online`: the bootstrap processor never sets that atomic.
pub fn snapshotCores(out: []CoreSnap) usize {
    var n: usize = 0;
    var core = firstCpu();
    while (core) |c| {
        if (n == out.len) return n;
        const idle = c.idle orelse @panic("no idle thread");
        out[n] = .{
            .apic_id = c.apic_id,
            .online = c.lapic_initialized,
            .idle_tid = idle.tid,
            .tid = if (c.thread) |t| t.tid else no_tid,
        };
        n += 1;
        core = nextCpu(c);
    }
    return n;
}

pub fn lapicIcr() u32 {
    return lapic_icr_value;
}

/// Spin for `us` microseconds. The TSC rate is known after `timer.init`.
pub fn delayUs(us: u64) void {
    const hz = tsc_hz_value;
    if (hz == 0) @panic("tsc rate unknown");
    const start = rdtsc();
    const need = us * hz / 1_000_000;
    if (need == 0) return;
    while (rdtsc() -% start < need) pause();
}

pub fn rdtsc() u64 {
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
    const tsc_mhz: ?u64 = if (tsc_hz_value != 0) tsc_hz_value / 1_000_000 else null;
    const cpu_mhz: ?u32 = if (cpu_base_mhz != 0) cpu_base_mhz else null;
    logger.info("{s} family={d} model={d} tsc={} tsc_mhz={?} cpu_mhz={?}", .{
        vendor,
        display_family,
        display_model,
        tsc_ok,
        tsc_mhz,
        cpu_mhz,
    });
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

/// Store a measured rate. A leaf `0x15` rate is left alone.
pub fn setTscHz(hz: u64) bool {
    if (!tsc_ok or tsc_hz_value != 0 or hz == 0) return false;
    tsc_hz_value = hz;
    return true;
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

fn bootLogging() bool {
    return current() == &bsp_value;
}

pub fn firstCpu() ?*CPU {
    const n = cpus.first orelse return null;
    return cpuFromNode(n);
}

pub fn nextCpu(self: *CPU) ?*CPU {
    const n = self.node.next orelse return null;
    return cpuFromNode(n);
}

/// Other cores drop translations for [virt_addr, virt_addr+len). This core has already
/// run invlpg. A single page is one `invlpg` request. A longer range reloads
/// CR3, because `tlb_req` holds one address. The word is 0 only after the flush.
pub fn shootdown(virt_addr: usize, len: usize) void {
    std.debug.assert(std.mem.isAligned(virt_addr, pmm.page_size));
    std.debug.assert(len != 0 and std.mem.isAligned(len, pmm.page_size));
    // One page: `invlpg` that address (aligned, so it is not `tlb_flush_all`).
    // A longer run is one CR3 reload. Zero is not a request.
    const req: u64 = if (len == pmm.page_size) @intCast(virt_addr) else tlb_flush_all;
    std.debug.assert(req != 0);
    const me = current();
    var node = cpus.first;
    while (node) |n| {
        const other = cpuFromNode(n);
        node = n.next;
        if (other == me or !other.lapic_initialized) continue;
        while (other.tlb_req.load(.acquire) != 0) pause();
        other.tlb_req.store(req, .release);
        me.sendIpi(other.apic_id, @intCast(ivt.vec_tlb));
        while (other.tlb_req.load(.acquire) != 0) pause();
    }
}

/// NMI every other core whose local APIC is up. A core still waiting for
/// SIPI is left alone. The handler halts when a panic is already in progress.
pub fn nmiOthers() void {
    if (!bsp_value.initialized) return;
    const me = current();
    if (!me.lapic_initialized) return;
    var node = cpus.first;
    while (node) |n| {
        const other = cpuFromNode(n);
        node = n.next;
        if (other == me or !other.lapic_initialized) continue;
        me.sendIcr(other.apic_id, icr_dm_nmi | icr_level_assert);
    }
}

/// Switch to the kernel root when `leave_pt` names the current PML4.
/// Does not take the kernel lock. True when this call performed the switch's ack.
pub fn abandon(self: *CPU) bool {
    const pt = self.leave_pt.load(.acquire);
    if (pt == 0) return false;
    if (vmm.readCR3() == pt) vmm.kernel_vmm.switchTo();
    if (self.loaded_pt.load(.acquire) == pt) {
        self.loaded_pt.store(vmm.kernel_vmm.pt_addr_phys, .release);
    }
    _ = self.leave_pt.cmpxchgStrong(pt, 0, .release, .acquire);
    return true;
}

/// Cores whose CR3 is `pt` switch to the kernel root. The caller holds the
/// kernel lock. Each target acks from `abandon` before it takes the lock,
/// then schedules once its thread is stopped.
pub fn evacuate(pt: usize) void {
    if (pt == 0 or !vmm.kernel_vmm.initialized or pt == vmm.kernel_vmm.pt_addr_phys) return;
    const me = current();
    var node = cpus.first;
    while (node) |n| {
        const other = cpuFromNode(n);
        node = n.next;
        if (other == me or !other.lapic_initialized) continue;
        if (other.loaded_pt.load(.acquire) != pt) continue;
        while (other.leave_pt.load(.acquire) != 0) pause();
        other.leave_pt.store(pt, .release);
        me.sendIpi(other.apic_id, @intCast(ivt.vec_leave));
        while (other.leave_pt.load(.acquire) != 0) pause();
    }
}

fn cpuFromNode(n: *std.DoublyLinkedList.Node) *CPU {
    // IST stacks make `CPU` align 16. The list node is not.
    return @alignCast(@fieldParentPtr("node", n));
}

/// CPU executing this call. `CPU.init` points `IA32_GS_BASE` at that object.
pub fn current() *CPU {
    return asm volatile (
        \\movq %%gs:cpu_gs_self, %[cpu]
        : [cpu] "=r" (-> *CPU),
    );
}

pub fn currentThread() *proc.Thread {
    return current().thread orelse @panic("no current thread");
}

pub fn currentProcess() *proc.Process {
    return currentThread().parent;
}

pub inline fn interruptsOff() void {
    asm volatile ("cli");
}

pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

fn reloadCr3() void {
    const cr3 = asm volatile (
        \\movq %%cr3, %[cr3]
        : [cr3] "=r" (-> u64),
        :
        : .{ .memory = true });
    asm volatile (
        \\movq %[cr3], %%cr3
        :
        : [cr3] "r" (cr3),
        : .{ .memory = true });
}

fn invlpg(virt_addr: u64) void {
    asm volatile (
        \\invlpg (%[virt_addr])
        :
        : [virt_addr] "r" (virt_addr),
        : .{ .memory = true });
}

pub fn readCr2() u64 {
    return asm volatile (
        \\movq %%cr2, %[cr2]
        : [cr2] "=r" (-> u64),
    );
}

inline fn readCr0() u64 {
    return asm volatile (
        \\movq %%cr0, %[cr0]
        : [cr0] "=r" (-> u64),
    );
}

inline fn writeCr0(value: u64) void {
    asm volatile (
        \\movq %[value], %%cr0
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

inline fn readCr4() u64 {
    return asm volatile (
        \\movq %%cr4, %[cr4]
        : [cr4] "=r" (-> u64),
    );
}

inline fn writeCr4(value: u64) void {
    asm volatile (
        \\movq %[value], %%cr4
        :
        : [value] "r" (value),
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
