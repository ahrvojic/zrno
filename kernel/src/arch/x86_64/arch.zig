pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn hlt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub inline fn hang() noreturn {
    cli();
    hlt();
}
