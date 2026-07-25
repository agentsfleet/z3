const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("lib", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const s3_mod = b.addModule("s3", .{
        .root_source_file = b.path("src/s3/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lib", .module = lib_mod }},
    });

    const dynamo_mod = b.addModule("dynamo", .{
        .root_source_file = b.path("src/dynamo/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lib", .module = lib_mod }},
    });

    const s3_examples = .{
        .{ "example-get-multipart", "examples/s3/get_object_multipart.zig" },
        .{ "example-put-multipart", "examples/s3/put_object_multipart.zig" },
        .{ "example-put-fetch-async", "examples/s3/put_fetch_async.zig" },
        .{ "example-track-progress", "examples/s3/track_progress.zig" },
    };
    inline for (s3_examples) |ex| {
        const example_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "s3", .module = s3_mod }},
            }),
        });
        b.installArtifact(example_exe);
        const run = b.addRunArtifact(example_exe);
        if (@hasField(std.Build, "args")) {
            if (b.args) |args| run.addArgs(args);
        } else {
            run.addPassthruArgs();
        }
        const step = b.step(ex[0], "Run " ++ ex[0]);
        step.dependOn(&run.step);
    }

    const dynamo_examples = .{
        .{ "example-dynamo-basic", "examples/dynamo/basic.zig" },
    };
    inline for (dynamo_examples) |ex| {
        const example_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "dynamo", .module = dynamo_mod }},
            }),
        });
        b.installArtifact(example_exe);
        const run = b.addRunArtifact(example_exe);
        if (@hasField(std.Build, "args")) {
            if (b.args) |args| run.addArgs(args);
        } else {
            run.addPassthruArgs();
        }
        const step = b.step(ex[0], "Run " ++ ex[0]);
        step.dependOn(&run.step);
    }

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const s3_tests = b.addTest(.{ .root_module = s3_mod });
    const dynamo_tests = b.addTest(.{ .root_module = dynamo_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_s3_tests = b.addRunArtifact(s3_tests);
    const run_dynamo_tests = b.addRunArtifact(dynamo_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_s3_tests.step);
    test_step.dependOn(&run_dynamo_tests.step);

    const s3_integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/s3/tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "s3", .module = s3_mod }},
        }),
    });
    const run_s3_integration = b.addRunArtifact(s3_integration);
    run_s3_integration.has_side_effects = true;

    const dynamo_integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dynamo/tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dynamo", .module = dynamo_mod }},
        }),
    });
    const run_dynamo_integration = b.addRunArtifact(dynamo_integration);
    run_dynamo_integration.has_side_effects = true;

    const integration_s3 = b.step("integration-test-s3", "Run S3 integration tests");
    integration_s3.dependOn(&run_s3_integration.step);

    const integration_dynamo = b.step("integration-test-dynamo", "Run DynamoDB integration tests");
    integration_dynamo.dependOn(&run_dynamo_integration.step);

    const integration_all = b.step("integration-test", "Run all integration tests");
    integration_all.dependOn(&run_s3_integration.step);
    integration_all.dependOn(&run_dynamo_integration.step);
}
