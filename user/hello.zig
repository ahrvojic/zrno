const lib = @import("lib");

pub fn main() u64 {
    lib.print("Hello from userspace!\n");
    return 0;
}
