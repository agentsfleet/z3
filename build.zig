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

    const examples = .{
        .{ "example-get-multipart", "examples/get_object_multipart.zig" },
        .{ "example-put-fetch-async", "examples/put_fetch_async.zig" },
    };

    inline for (examples) |ex| {
        const example_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = b.createModule(.{ .root_source_file = b.path(ex[1]), .target = target, .optimize = optimize, .imports = &.{.{ .name = "s3", .module = s3_mod }} }),
        });

        b.installArtifact(example_exe);

        const run = b.addRunArtifact(example_exe);
        if (b.args) |args| run.addArgs(args);

        const step = b.step(ex[0], "Run " ++ ex[0]);
        step.dependOn(&run.step);
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
