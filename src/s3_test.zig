//! S3 Client Integration Tests
//! Tests all S3 operations in order: createBucket -> putObject -> listBuckets -> listObjects -> getObject -> deleteObject -> deleteBucket
const std = @import("std");
const S3Client = @import("s3_client.zig").S3Client;

const test_bucket = "zig-s3-test-bucket";
const test_key = "test-object.txt";
const test_content = "Hello from Zig S3 client test!";
const test_meta_key = "test-object-meta.txt";
const test_meta_content = "Hello with metadata";

const TestContext = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    client: S3Client,

    pub fn init() !*TestContext {
        const environ = std.testing.environ;
        const access_key = environ.getPosix("AWS_ACCESS_KEY_ID") orelse return error.SkipZigTest;
        const secret_key = environ.getPosix("AWS_SECRET_ACCESS_KEY") orelse return error.SkipZigTest;
        const region = environ.getPosix("AWS_REGION") orelse "auto";
        const endpoint = environ.getPosix("S3_ENDPOINT") orelse "https://7ba9afa0682066b2986a17f41ead69ea.r2.cloudflarestorage.com";

        const config: S3Client.Config = .{
            .access_key_id = access_key,
            .secret_access_key = secret_key,
            .region = region,
            .endpoint = endpoint,
        };

        const ctx = try std.testing.allocator.create(TestContext);
        ctx.gpa = .{};
        const allocator = ctx.gpa.allocator();

        std.log.info("  IO initialized", .{});

        ctx.client = try S3Client.init(allocator, config, .{ .io = std.testing.io });
        std.log.info("  Client initialized", .{});

        return ctx;
    }

    pub fn deinit(self: *TestContext) void {
        self.client.deinit();
        const check = self.gpa.deinit();
        std.testing.allocator.destroy(self);
        if (check == .leak) {
            std.log.warn("GPA leaked in TestContext!", .{});
        }
    }
};

// 1. Create bucket
test "01_createBucket" {
    std.log.info("=== START 01_createBucket ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling createBucket...", .{});

    var response = try ctx.client.createBucket(test_bucket);
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    // 200 OK or 409 Conflict (already exists) are acceptable
    try std.testing.expect(response.status == .ok or response.status == .conflict);
    std.log.info("=== DONE 01_createBucket: {} ===\n", .{response.status});
}

// 2. Put object
test "02_putObject" {
    std.log.info("=== START 02_putObject ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling putObject...", .{});

    var response = try ctx.client.putObject(test_bucket, test_key, test_content, .{});
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok or response.status == .created);
    std.log.info("=== DONE 02_putObject: {} ===\n", .{response.status});
}

// 2b. Put object with metadata
test "02b_putObjectWithMetadata" {
    std.log.info("=== START 02b_putObjectWithMetadata ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling putObject with metadata...", .{});

    const metadata = [_]S3Client.Metadata{
        .{ .name = "color", .value = "blue" },
        .{ .name = "owner", .value = "zig-test" },
    };
    var response = try ctx.client.putObject(test_bucket, test_meta_key, test_meta_content, .{
        .metadata = &metadata,
    });
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok or response.status == .created);
    std.log.info("=== DONE 02b_putObjectWithMetadata: {} ===\n", .{response.status});
}

// 2b. Put object (file)
test "02c_putFile" {
    std.log.info("=== START 02c_putFile ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/putfile.txt", .{tmp.sub_path});
    defer std.testing.allocator.free(rel_path);

    const io = std.testing.io;
    const file = try std.Io.Dir.createFile(.cwd(), io, rel_path, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &file_buffer);
    try file_writer.interface.writeAll(test_content);
    try file_writer.interface.flush();

    std.log.info("  calling putFile...", .{});
    var response = try ctx.client.putFile(test_bucket, test_key, rel_path, .{});
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok or response.status == .created);
    std.log.info("=== DONE 02c_putFile: {} ===\n", .{response.status});
}

// 2c. Get object (file)
test "02d_getFile" {
    std.log.info("=== START 02d_getFile ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/getfile.txt", .{tmp.sub_path});
    defer std.testing.allocator.free(rel_path);

    std.log.info("  calling getFile...", .{});
    const result = try ctx.client.getFile(test_bucket, test_key, rel_path, .{});
    std.log.info("  Got response: {} bytes_written={d}\n", .{ result.status, result.bytes_written });
    try std.testing.expect(result.status == .ok);
    try std.testing.expectEqual(@as(u64, test_content.len), result.bytes_written);

    const io = std.testing.io;
    const file = try std.Io.Dir.openFile(.cwd(), io, rel_path, .{ .mode = .read_only });
    defer file.close(io);
    var reader_buffer: [4096]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &reader_buffer);
    const data = try file_reader.interface.allocRemaining(
        std.testing.allocator,
        std.Io.Limit.unlimited,
    );
    defer std.testing.allocator.free(data);

    try std.testing.expectEqualStrings(test_content, data);
    try std.testing.expectEqual(@as(u64, test_content.len), @as(u64, data.len));
    std.log.info("=== DONE 02d_getFile: {d} bytes ===\n", .{data.len});
}

// 3. List buckets
test "03_listBuckets" {
    std.log.info("=== START 03_listBuckets ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling listBuckets...", .{});

    var result = try ctx.client.listBuckets();
    defer result.deinit();
    std.log.info("  Got {d} buckets\n", .{result.buckets.len});

    // Should contain our test bucket
    var found = false;
    for (result.buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, test_bucket)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    std.log.info("=== DONE 03_listBuckets: success ({d} buckets) ===\n", .{result.buckets.len});
}

// 4. List objects in bucket
test "04_listObjects" {
    std.log.info("=== START 04_listObjects ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling listObjects...", .{});

    var result = try ctx.client.listObjects(test_bucket, .{});
    defer result.deinit();
    std.log.info("  Got {d} objects\n", .{result.objects.len});

    // Should contain our test key
    var found = false;
    for (result.objects) |obj| {
        if (std.mem.eql(u8, obj.key, test_key)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    std.log.info("=== DONE 04_listObjects: success ({d} objects) ===\n", .{result.objects.len});
}

// 4b. List objects with pagination
test "04b_listObjectsPagination" {
    std.log.info("=== START 04b_listObjectsPagination ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling listObjects...", .{});

    const extra_key = "test-object-paginate-2.txt";
    var response = try ctx.client.putObject(test_bucket, extra_key, test_content, .{});
    defer response.deinit();
    try std.testing.expect(response.status == .ok or response.status == .created);

    var first = try ctx.client.listObjects(test_bucket, .{
        .max_keys = 1,
    });
    defer first.deinit();
    try std.testing.expect(first.is_truncated);
    try std.testing.expect(first.next_continuation_token != null);

    var second = try ctx.client.listObjects(test_bucket, .{
        .max_keys = 1,
        .continuation_token = first.next_continuation_token.?,
    });
    defer second.deinit();
    try std.testing.expect(second.objects.len > 0);

    var delete_extra = try ctx.client.deleteObject(test_bucket, extra_key, .{});
    defer delete_extra.deinit();
    try std.testing.expect(delete_extra.status == .no_content or delete_extra.status == .ok);

    std.log.info("=== DONE 04b_listObjectsPagination: {d} + {d} ===\n", .{ first.objects.len, second.objects.len });
}

// 4c. Concurrent put/get similar to examples/put_fetch_async.zig
test "04c_concurrentPutGet" {
    std.log.info("=== START 04c_concurrentPutGet ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    var bucket_resp = try ctx.client.createBucket(test_bucket);
    defer bucket_resp.deinit();
    try std.testing.expect(bucket_resp.status == .ok or bucket_resp.status == .conflict);

    const io = std.testing.io;
    const keys = [_][]const u8{
        "concurrent-0.txt",
        "concurrent-1.txt",
        "concurrent-2.txt",
        "concurrent-3.txt",
    };
    const body = "THIS IS A CONCURRENT TEST FILE";

    const PutFuture = std.Io.Future(S3Client.RequestError!S3Client.Response);
    var put_futures: [keys.len]PutFuture = undefined;
    for (keys, 0..) |key, i| {
        put_futures[i] = io.async(S3Client.putObject, .{ &ctx.client, test_bucket, key, body, .{} });
    }
    for (&put_futures) |*future| {
        var response = try future.await(io);
        defer response.deinit();
        try std.testing.expect(response.status == .ok or response.status == .created);
    }

    const GetFuture = std.Io.Future(S3Client.RequestError!S3Client.Response);
    var get_futures: [keys.len]GetFuture = undefined;
    for (keys, 0..) |key, i| {
        get_futures[i] = io.async(S3Client.getObject, .{ &ctx.client, test_bucket, key, .{} });
    }
    for (&get_futures) |*future| {
        var response = try future.await(io);
        defer response.deinit();
        try std.testing.expect(response.status == .ok);
        try std.testing.expectEqualStrings(body, response.body);
    }

    for (keys) |key| {
        var delete_response = try ctx.client.deleteObject(test_bucket, key, .{});
        defer delete_response.deinit();
        try std.testing.expect(delete_response.status == .no_content or delete_response.status == .ok);
    }

    std.log.info("=== DONE 04c_concurrentPutGet ===", .{});
}

// 5. Get object
test "05_getObject" {
    std.log.info("=== START 05_getObject ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling getObject...", .{});

    var response = try ctx.client.getObject(test_bucket, test_key, .{});
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok);
    try std.testing.expectEqualStrings(test_content, response.body);
    std.log.info("=== DONE 05_getObject: {} - \"{s}\" ===\n", .{ response.status, response.body });
}

// 6. Get object (streaming)
test "06_getObjectStream" {
    std.log.info("=== START 06_getObjectStream ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling getObjectStream...", .{});

    var stream = try ctx.client.getObjectStream(test_bucket, test_key, .{});
    defer stream.deinit();

    const reader = try stream.reader();
    var buf = try std.ArrayList(u8).initCapacity(ctx.gpa.allocator(), 0);
    defer buf.deinit(ctx.gpa.allocator());

    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        try buf.appendSlice(ctx.gpa.allocator(), chunk[0..n]);
        if (n < chunk.len) break;
    }

    try std.testing.expectEqualStrings(test_content, buf.items);
    std.log.info("=== DONE 06_getObjectStream: {} - {d} bytes ===\n", .{ stream.status(), buf.items.len });
}

// 6b. Get object
test "06b_getObjectRange" {
    std.log.info("=== START 06b_getObjectRange ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling getObject...", .{});

    var response = try ctx.client.getObject(test_bucket, test_key, .{ .range = .{ .start = 6, .end = 13 } });
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .partial_content);
    try std.testing.expectEqualStrings(test_content[6..14], response.body);
    std.log.info("=== DONE 06b_getObjectRange: {} - \"{s}\" ===\n", .{ response.status, response.body });
}

// 7. Delete object
test "07_deleteObject" {
    std.log.info("=== START 07_deleteObject ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling deleteObject...", .{});

    var response = try ctx.client.deleteObject(test_bucket, test_key, .{});
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });
    // 204 No Content is expected for successful delete
    try std.testing.expect(response.status == .no_content or response.status == .ok);

    var meta_response = try ctx.client.deleteObject(test_bucket, test_meta_key, .{});
    defer meta_response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ meta_response.status, meta_response.body.len });
    try std.testing.expect(meta_response.status == .no_content or meta_response.status == .ok);

    std.log.info("=== DONE 07_deleteObject: {} ===\n", .{response.status});
}

// 8. Delete bucket
test "08_deleteBucket" {
    std.log.info("=== START 08_deleteBucket ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.log.info("  calling deleteBucket...", .{});

    var response = try ctx.client.deleteBucket(test_bucket);
    defer response.deinit();
    std.log.info("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    // 204 No Content is expected for successful delete
    try std.testing.expect(response.status == .no_content or response.status == .ok);
    std.log.info("=== DONE 08_deleteBucket: {} ===\n", .{response.status});
}
