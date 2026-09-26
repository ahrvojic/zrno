//! Page tables for the jump into the kernel.
//! Identity and the higher-half map use 2 MiB pages. The kernel image is
//! mapped with 4 KiB pages at its link address. Firmware on x86_64 has
//! already entered long mode and identity-mapped the loader, so these
//! tables only have to stay valid until the kernel installs its own.

const std = @import("std");

const bootinfo = @import("bootinfo");

const two_mib: u64 = 2 * 1024 * 1024;
const phys_limit: u64 = 1 << 39;
const present: u64 = 1;
const writable: u64 = 1 << 1;
const huge: u64 = 1 << 7;
const addr_mask: u64 = 0x000f_ffff_ffff_f000;

pub const Tables = struct {
    pool: []align(4096) [4096]u8,
    used: usize = 0,
    root: u64 = 0,

    pub fn reset(self: *Tables) !void {
        self.used = 0;
        self.root = try self.alloc();
    }

    /// Identity-map and higher-half-map `[base, end)`, expanded to 2 MiB.
    pub fn mapRam(self: *Tables, base: u64, end: u64) !void {
        if (end <= base) return;
        const first = base & ~(two_mib - 1);
        const last = std.math.add(u64, end, two_mib - 1) catch return error.PhysTooHigh;
        const aligned = last & ~(two_mib - 1);
        if (aligned > phys_limit) return error.PhysTooHigh;
        var phys = first;
        while (phys < aligned) : (phys += two_mib) {
            try self.map2M(phys, phys);
            try self.map2M(bootinfo.hhdm_offset + phys, phys);
        }
    }

    pub fn mapKernel(self: *Tables, phys: u64, bytes: u64) !void {
        var off: u64 = 0;
        while (off < bytes) : (off += bootinfo.page_size) {
            try self.map4K(bootinfo.kernel_virt + off, phys + off);
        }
    }

    fn alloc(self: *Tables) !u64 {
        if (self.used >= self.pool.len) return error.OutOfTables;
        const page = &self.pool[self.used];
        self.used += 1;
        @memset(page, 0);
        return @intFromPtr(page);
    }

    fn table(phys: u64) *[512]u64 {
        return @ptrFromInt(phys);
    }

    fn descend(self: *Tables, parent: u64, index: usize) !u64 {
        const entries = table(parent);
        if (entries[index] & present == 0) {
            const child = try self.alloc();
            entries[index] = child | present | writable;
            return child;
        }
        if (entries[index] & huge != 0) return error.Overlap;
        return entries[index] & addr_mask;
    }

    fn map2M(self: *Tables, virt: u64, phys: u64) !void {
        const pml4 = (virt >> 39) & 0x1ff;
        const pdpt = (virt >> 30) & 0x1ff;
        const pd = (virt >> 21) & 0x1ff;
        const level3 = try self.descend(self.root, pml4);
        const level2 = try self.descend(level3, pdpt);
        const entries = table(level2);
        const entry = phys | present | writable | huge;
        if (entries[pd] != 0 and entries[pd] != entry) return error.Overlap;
        entries[pd] = entry;
    }

    fn map4K(self: *Tables, virt: u64, phys: u64) !void {
        const pml4 = (virt >> 39) & 0x1ff;
        const pdpt = (virt >> 30) & 0x1ff;
        const pd = (virt >> 21) & 0x1ff;
        const pt = (virt >> 12) & 0x1ff;
        const level3 = try self.descend(self.root, pml4);
        const level2 = try self.descend(level3, pdpt);
        const level1 = try self.descend(level2, pd);
        table(level1)[pt] = phys | present | writable;
    }
};

// The jump cannot be a normal call: after CR3 changes, a compiler epilogue
// would use the new stack. The trampoline reads these instead.
export var jump_cr3: u64 = 0;
export var jump_entry: u64 = 0;
export var jump_info: u64 = 0;
export var jump_stack: u64 = 0;

pub fn enter(cr3: u64, entry: u64, info: u64, stack: u64) noreturn {
    jump_cr3 = cr3;
    jump_entry = entry;
    jump_info = info;
    jump_stack = stack;
    asm volatile ("jmp trampoline" ::: .{ .memory = true });
    unreachable;
}

export fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\cli
        \\movq jump_cr3(%rip), %r10
        \\movq jump_entry(%rip), %r11
        \\movq jump_info(%rip), %rdi
        \\movq jump_stack(%rip), %r12
        \\movl $0xC0000080, %ecx
        \\rdmsr
        \\orl $0x800, %eax
        \\wrmsr
        \\movq %r10, %cr3
        \\movq %r12, %rsp
        \\xorq %rbp, %rbp
        \\cld
        \\jmpq *%r11
    );
}
