pub inline fn inb(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[res]
        : [res] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn outb(port: u16, value: u8) void {
    asm volatile (
        \\outb %[value], %[port]
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}
