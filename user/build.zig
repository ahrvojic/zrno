const std = @import("std");

pub fn build(b: *std.Build) void {
    const Features = std.Target.x86.Feature;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        // SSE/SSE2 are in the x86_64 baseline. AVX/AVX2 need XSAVE + YMM in XCR0.
        .cpu_features_add = std.Target.x86.featureSet(&.{
            Features.avx,
            Features.avx2,
        }),
    });

    // Default ReleaseSmall: Debug/ReleaseSafe pull Zig's panic formatter
    // (ubsan_rt + compiler-rt) and userspace does not bundle compiler-rt.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseSmall;

    const lib = userMod(b, b.path("src/lib/lib.zig"), target, optimize, &.{});

    const io = b.graph.io;
    var cmd_dir = b.build_root.handle.openDir(io, "src/cmd", .{ .iterate = true }) catch
        @panic("open src/cmd");
    defer cmd_dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = cmd_dir.iterate();
    while (it.next(io) catch @panic("iterate src/cmd")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        names.append(b.allocator, b.dupe(stem)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b_name: []const u8) bool {
            return std.mem.lessThan(u8, a, b_name);
        }
    }.less);

    for (names.items) |name| {
        const app = userMod(b, b.path(b.fmt("src/cmd/{s}.zig", .{name})), target, optimize, &.{
            .{ .name = "lib", .module = lib },
        });
        const root = userMod(b, b.path("src/lib/start.zig"), target, optimize, &.{
            .{ .name = "app", .module = app },
            .{ .name = "lib", .module = lib },
        });
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = root,
            .use_llvm = true,
        });
        exe.entry = .{ .symbol_name = "_start" };
        exe.pie = false;
        exe.bundle_compiler_rt = false;
        exe.setLinkerScript(b.path("user.ld"));
        b.installArtifact(exe);
    }
}

fn userMod(
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .strip = true,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .imports = imports,
    });
}
