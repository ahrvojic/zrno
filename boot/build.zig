const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    const bootinfo = b.createModule(.{
        .root_source_file = b.path("../common/bootinfo.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bootinfo", .module = bootinfo },
            },
        }),
    });
    exe.use_llvm = true;
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mmap.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bootinfo", .module = bootinfo },
            },
        }),
    });
    const test_step = b.step("test", "Run memory-map tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
