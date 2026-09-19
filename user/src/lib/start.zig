const app = @import("app");
const lib = @import("lib");

// rdi=argv ptr, rsi=argc. App defines `pub fn main() u64` or
// `pub fn main(argv: []const []const u8) u64`.
export fn _start(argv: [*]const []const u8, argc: usize) callconv(.c) noreturn {
    lib.sys.exit(callMain(argv[0..argc]));
}

inline fn callMain(args: []const []const u8) u64 {
    const nparams = @typeInfo(@TypeOf(app.main)).@"fn".params.len;
    if (nparams == 0) return app.main();
    if (nparams == 1) return app.main(args);
    @compileError("main must be fn () u64 or fn ([]const []const u8) u64");
}
