const app = @import("app");
const lib = @import("lib");

// rdi=argc, rsi=argv. App defines `pub fn main() u64` or `pub fn main(argv: []const [*:0]const u8) u64`.
export fn _start(argc: u64, argv: [*]const [*:0]const u8) callconv(.c) noreturn {
    lib.sys.exit(callMain(argv[0..@as(usize, @intCast(argc))]));
}

inline fn callMain(args: []const [*:0]const u8) u64 {
    const nparams = @typeInfo(@TypeOf(app.main)).@"fn".params.len;
    if (nparams == 0) return app.main();
    if (nparams == 1) return app.main(args);
    @compileError("main must be fn () u64 or fn ([]const [*:0]const u8) u64");
}
