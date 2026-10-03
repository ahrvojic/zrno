const std = @import("std");

pub fn build(b: *std.Build) void {
    const Features = std.Target.x86.Feature;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        // Kernel stays SSE/AVX-free so IRQ/SYSCALL do not clobber user XSAVE state.
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

    const bootinfo = b.createModule(.{
        .root_source_file = b.path("../common/bootinfo.zig"),
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const font = b.createModule(.{
        .root_source_file = b.path("assets/437_US.F16"),
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        // Fixed link address. The bootloader does not apply relocations.
        .pic = false,
        .red_zone = false,
        // RBP walks in panicImpl. .safe would otherwise omit them.
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "bootinfo", .module = bootinfo },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "437_US.F16", .module = font },
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
    kernel.lto = .none;
    // Zig 0.17.0 compiler-rt does not build for x86 soft-float (#37006).
    // src/lib/rt.zig provides the integer and memory helpers LLVM still emits.
    kernel.bundle_compiler_rt = false;

    b.installArtifact(kernel);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bootinfo", .module = bootinfo },
                .{ .name = "437_US.F16", .module = font },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
