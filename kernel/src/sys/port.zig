pub fn inb(port: u16) callconv(.Inline) u8 {
    return asm volatile (
        \\inb %[port], %[res]
        : [res] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

pub fn outb(port: u16, value: u8) callconv(.Inline) void {
    asm volatile (
        \\outb %[value], %[port]
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}
