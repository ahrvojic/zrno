const app = @import("app");
const lib = @import("lib");

// rdi=argc, rsi=argv. App defines `pub fn main(argc: usize, argv: []const [*:0]const u8) u64`.
export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    const n: usize = @intCast(argc);
    lib.sys.exit(app.main(n, argv[0..n]));
}
