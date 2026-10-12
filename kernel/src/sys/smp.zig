const logger = std.log.scoped(.smp);

const std = @import("std");

const cpu = @import("cpu.zig");
const debug = @import("../lib/debug.zig");
const heap = @import("../mm/heap.zig");
const lock = @import("lock.zig");
const madt = @import("../acpi/madt.zig");
const pmm = @import("../mm/pmm.zig");
const sched = @import("../sched/sched.zig");
const virt = @import("../lib/virt.zig");
const vmm = @import("../mm/vmm.zig");

// Real-mode stub layout inside the identity-mapped page. The 64-bit
// fragment and the GDT sit at fixed offsets so the far jump and GDTR
// can be patched with the page's physical address.
const tramp_long = 0x80;
const tramp_gdt = 0x200;
const tramp_gdtr = 0x218;

comptime {
    std.debug.assert(tramp_long < tramp_gdt);
    std.debug.assert(tramp_gdtr + 6 < pmm.page_size);
}

var scheduler_live: std.atomic.Value(u8) = .init(0);

/// Other cores may enter the scheduler. They spin until this store.
pub fn live() void {
    scheduler_live.store(1, .release);
}

/// Start every other core. The caller holds the kernel lock. Each core
/// reaches `apEnter`, marks itself online, and spins until `live`.
pub fn start() !void {
    const bsp = cpu.bsp();
    var ids: [madt.max_lapics]u32 = undefined;
    const n = madt.applicationIds(bsp.lapicId(), bsp.x2apic, &ids);
    if (n == 0) {
        logger.info("smp bsp={d} aps=0", .{bsp.lapicId()});
        return;
    }
    const page = pmm.trampolinePage() orelse return error.OutOfMemory;
    logger.info("smp bsp={d} aps={d} trampoline=0x{x}", .{ bsp.lapicId(), n, page });
    const cr3 = vmm.kernel_vmm.pt_addr_phys;
    if (cr3 > 0xffff_f000 or cr3 & 0xfff != 0) @panic("kernel cr3 is not a 32-bit page");
    // Fetched with paging off, then with paging on, until the far jump
    // into the high half. Not the shared kernel half, so clones never see it.
    try vmm.kernel_vmm.map(page, page, pmm.page_size, .{
        .present = true,
        .writable = true,
    });

    for (ids[0..n]) |id| {
        try bootOne(page, cr3, id);
    }
    // The physical page stays reserved. A core may still have this
    // translation cached until its next CR3 load.
    vmm.kernel_vmm.unmap(page, pmm.page_size) catch @panic("unmap trampoline");
}

fn bootOne(page: usize, cr3: usize, id: u32) !void {
    const ap = try heap.kernel_heap.allocator().create(cpu.CPU);
    // The object is about 80 KiB of interrupt stacks. Zero through the
    // pointer so the boot stack does not hold a temporary. A zero GDT has
    // no code descriptor, and the application processor #GPs when it
    // reloads CS, so install that template before the startup IPI.
    @memset(@as([*]u8, @ptrCast(ap))[0..@sizeOf(cpu.CPU)], 0);
    ap.expected_apic_id = id;
    ap.gdt = .{};
    const idle = try sched.addIdle(ap);
    const dest = virt.toHH([*]u8, page)[0..pmm.page_size];
    buildTrampoline(dest, @intCast(page), @intCast(cr3), idle.ctx.rsp, @intFromPtr(ap), @intFromPtr(&apEnter));
    asm volatile ("mfence" ::: .{ .memory = true });
    cpu.bsp().startupIpi(id, @intCast(page / pmm.page_size));
    waitOnline(ap, id);
}

fn waitOnline(ap: *cpu.CPU, id: u32) void {
    const hz = cpu.tscHz();
    if (hz == 0) @panic("tsc rate unknown");
    const start_tick = cpu.rdtsc();
    const limit = hz * 5;
    while (ap.online.load(.acquire) == 0) {
        if (cpu.rdtsc() -% start_tick > limit) {
            var buf: [64]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            debug.printTo(&writer, "ap {d} did not come online", .{id});
            @panic(writer.buffered());
        }
        cpu.pause();
    }
    logger.info("ap online apic_id={d}", .{id});
}

/// Entered in long mode on the idle stack, with the kernel CR3. No heap
/// and no serial until the kernel lock is taken below.
export fn apEnter(self: *cpu.CPU) callconv(.c) noreturn {
    cpu.interruptsOff();
    self.bootApplication();
    self.online.store(1, .release);
    while (scheduler_live.load(.acquire) == 0) {
        // IF is clear, so a shootdown IPI stays pending. Poll the word.
        self.serviceTlb();
        cpu.pause();
    }
    const icr = cpu.lapicIcr();
    if (icr == 0) @panic("lapic timer not calibrated");
    self.lapicTimerPeriodic(icr);
    lock.acquire();
    sched.yield();
    unreachable;
}

const Buf = struct {
    dest: []u8,
    at: usize = 0,

    fn b(self: *@This(), xs: []const u8) void {
        @memcpy(self.dest[self.at..][0..xs.len], xs);
        self.at += xs.len;
    }

    fn dw(self: *@This(), v: u32) void {
        std.mem.writeInt(u32, self.dest[self.at..][0..4], v, .little);
        self.at += 4;
    }

    fn dq(self: *@This(), v: u64) void {
        std.mem.writeInt(u64, self.dest[self.at..][0..8], v, .little);
        self.at += 8;
    }
};

fn buildTrampoline(dest: []u8, page: u32, cr3: u32, stack: u64, boot_cpu: u64, entry: u64) void {
    @memset(dest, 0);
    var buf: Buf = .{ .dest = dest };

    // 16-bit entry. Operand-size prefix (0x66) selects eax; the address-size
    // prefix (0x67) lets `lgdt` use eax. NXE is required before paging
    // because kernel stacks are non-executable.
    buf.b(&.{
        0xfa, // cli
        0xfc, // cld
        0x31, 0xc0, // xor ax, ax
        0x8e, 0xd8, // mov ds, ax
        0x8e, 0xc0, // mov es, ax
        0x8e, 0xd0, // mov ss, ax
        0x66, 0xb8, // mov eax, gdtr
    });
    buf.dw(page + tramp_gdtr);
    buf.b(&.{
        0x67, 0x0f, 0x01, 0x10, // lgdt [eax]
        0x66, 0x0f, 0x20, 0xe0, // mov eax, cr4
        0x66, 0x83, 0xc8, 0x20, // or eax, PAE
        0x66, 0x0f, 0x22, 0xe0, // mov cr4, eax
        0x66, 0xb8, // mov eax, cr3
    });
    buf.dw(cr3);
    buf.b(&.{
        0x66, 0x0f, 0x22, 0xd8, // mov cr3, eax
        0x66, 0xb9, 0x80, 0x00, 0x00, 0xc0, // mov ecx, IA32_EFER
        0x0f, 0x32, // rdmsr
        0x66, 0x0d, 0x00, 0x09, 0x00, 0x00, // or eax, LME | NXE
        0x0f, 0x30, // wrmsr
        0x66, 0x0f, 0x20, 0xc0, // mov eax, cr0
        0x66, 0x25, 0xff, 0xff, 0xff, 0x9f, // and eax, ~CD & ~NW
        0x66, 0x0d, 0x01, 0x00, 0x00, 0x80, // or eax, PE | PG
        0x66, 0x0f, 0x22, 0xc0, // mov cr0, eax
        0x66, 0xea, // jmp far ptr16:32
    });
    buf.dw(page + tramp_long);
    buf.b(&.{ 0x08, 0x00 });
    std.debug.assert(buf.at <= tramp_long);

    buf.at = tramp_long;
    buf.b(&.{
        0xb8, 0x10, 0x00, 0x00, 0x00, // mov eax, 0x10
        0x8e, 0xd0, // mov ss, ax
        0x8e, 0xd8, // mov ds, ax
        0x8e, 0xc0, // mov es, ax
        0x48, 0xbc, // mov rsp, imm64
    });
    buf.dq(stack);
    buf.b(&.{ 0x48, 0xbf }); // mov rdi, imm64
    buf.dq(boot_cpu);
    buf.b(&.{ 0x48, 0xb8 }); // mov rax, imm64
    buf.dq(entry);
    buf.b(&.{ 0xff, 0xe0 }); // jmp rax
    std.debug.assert(buf.at <= tramp_gdt);

    const gdt = [_]u8{
        0,    0,    0, 0, 0, 0,    0,    0,
        0xff, 0xff, 0, 0, 0, 0x9a, 0xaf, 0,
        0xff, 0xff, 0, 0, 0, 0x92, 0xcf, 0,
    };
    @memcpy(dest[tramp_gdt..][0..gdt.len], &gdt);
    std.mem.writeInt(u16, dest[tramp_gdtr..][0..2], @intCast(gdt.len - 1), .little);
    std.mem.writeInt(u32, dest[tramp_gdtr + 2 ..][0..4], page + tramp_gdt, .little);
}
