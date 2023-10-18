pub fn cli() callconv(.Inline) void {
    asm volatile ("cli");
}

pub fn sti() callconv(.Inline) void {
    asm volatile ("sti");
}

pub fn hlt() callconv(.Inline) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn hang() callconv(.Inline) noreturn {
    cli();
    hlt();
}
