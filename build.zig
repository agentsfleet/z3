const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // S3 client library module (no external dependencies - uses std.http.Client)
    const s3_mod = b.addModule("s3", .{
        .root_source_file = b.path("src/s3_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library module (exports S3Client)
    _ = b.addModule("zigasync", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example executable
    const exe = b.addExecutable(.{
        .name = "s3-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "s3", .module = s3_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests for S3 client
    const s3_tests = b.addTest(.{
        .root_module = s3_mod,
    });
    const run_s3_tests = b.addRunArtifact(s3_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_s3_tests.step);

    // Integration tests for S3 operations
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/s3_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_step = b.step("integration-test", "Run S3 integration tests");
    integration_step.dependOn(&run_integration_tests.step);
}
