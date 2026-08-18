const std = @import("std");

pub fn build(b: *std.Build) void {
    const Features = std.Target.x86.Feature;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            Features.mmx,
            Features.sse,
            Features.sse2,
            Features.avx,
            Features.avx2,
        }),
    });

    const optimize = b.standardOptimizeOption(.{});

    const limine = b.dependency("limine", .{}).module("limine");

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .pic = true,
        .red_zone = false,
        .imports = &.{
            .{ .name = "limine", .module = limine },
        },
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });

    kernel.setLinkerScript(b.path("linker.ld"));
    // The self-hosted x86 backend cannot encode kernel asm (port I/O,
    // CR3, AT&T memory operands, jumps to exported stubs).
    kernel.use_llvm = true;
    // LTO can discard Limine request symbols.
    kernel.lto = .none;

    b.installArtifact(kernel);
}
