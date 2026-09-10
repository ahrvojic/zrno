const lib = @import("lib");

pub fn main(_: usize, _: []const [*:0]const u8) u64 {
    lib.print("Hello from userspace!\n");
    return 0;
}
