//! S3 Client Integration Tests
//! Tests all S3 operations in order: createBucket -> putObject -> listBuckets -> listObjects -> getObject -> deleteObject -> deleteBucket
const std = @import("std");
const S3Client = @import("s3_client.zig").S3Client;
const Io = std.Io;

const test_bucket = "zig-s3-test-bucket";
const test_key = "test-object.txt";
const test_content = "Hello from Zig S3 client test!";

const TestContext = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    threaded: Io.Threaded,
    client: S3Client,

    pub fn init() !*TestContext {
        const access_key = std.posix.getenv("AWS_ACCESS_KEY_ID") orelse return error.SkipZigTest;
        const secret_key = std.posix.getenv("AWS_SECRET_ACCESS_KEY") orelse return error.SkipZigTest;
        const region = std.posix.getenv("AWS_REGION") orelse "auto";
        const endpoint = std.posix.getenv("S3_ENDPOINT") orelse "https://7ba9afa0682066b2986a17f41ead69ea.r2.cloudflarestorage.com";

        const config: S3Client.Config = .{
            .access_key_id = access_key,
            .secret_access_key = secret_key,
            .region = region,
            .endpoint = endpoint,
        };

        const ctx = try std.testing.allocator.create(TestContext);
        ctx.gpa = .{};
        const allocator = ctx.gpa.allocator();

        ctx.threaded = Io.Threaded.init(allocator);
        const io = ctx.threaded.io();
        std.debug.print("  IO initialized\n", .{});

        ctx.client = try S3Client.init(allocator, config, .{ .io = io });
        std.debug.print("  Client initialized\n", .{});

        return ctx;
    }

    pub fn deinit(self: *TestContext) void {
        self.client.deinit();
        self.threaded.deinit();
        const check = self.gpa.deinit();
        std.testing.allocator.destroy(self);
        if (check == .leak) {
            std.debug.print("GPA leaked in TestContext!\n", .{});
        }
    }
};

// 1. Create bucket
test "01_createBucket" {
    std.debug.print("\n=== START 01_createBucket ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling createBucket...\n", .{});

    var response = try ctx.client.createBucket(test_bucket);
    defer response.deinit();
    std.debug.print("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    // 200 OK or 409 Conflict (already exists) are acceptable
    try std.testing.expect(response.status == .ok or response.status == .conflict);
    std.debug.print("=== DONE 01_createBucket: {} ===\n", .{response.status});
}

// 2. Put object
test "02_putObject" {
    std.debug.print("\n=== START 02_putObject ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling putObject...\n", .{});

    var response = try ctx.client.putObject(test_bucket, test_key, test_content);
    defer response.deinit();
    std.debug.print("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok or response.status == .created);
    std.debug.print("=== DONE 02_putObject: {} ===\n", .{response.status});
}

// 3. List buckets
test "03_listBuckets" {
    std.debug.print("\n=== START 03_listBuckets ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling listBuckets...\n", .{});

    var result = try ctx.client.listBuckets();
    defer result.deinit();
    std.debug.print("  Got {d} buckets\n", .{result.buckets.len});

    // Should contain our test bucket
    var found = false;
    for (result.buckets) |bucket| {
        if (std.mem.eql(u8, bucket.name, test_bucket)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    std.debug.print("=== DONE 03_listBuckets: success ({d} buckets) ===\n", .{result.buckets.len});
}

// 4. List objects in bucket
test "04_listObjects" {
    std.debug.print("\n=== START 04_listObjects ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling listObjects...\n", .{});

    var result = try ctx.client.listObjects(test_bucket, null);
    defer result.deinit();
    std.debug.print("  Got {d} objects\n", .{result.objects.len});

    // Should contain our test key
    var found = false;
    for (result.objects) |obj| {
        if (std.mem.eql(u8, obj.key, test_key)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    std.debug.print("=== DONE 04_listObjects: success ({d} objects) ===\n", .{result.objects.len});
}

// 5. Get object
test "05_getObject" {
    std.debug.print("\n=== START 05_getObject ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling getObject...\n", .{});

    var response = try ctx.client.getObject(test_bucket, test_key);
    defer response.deinit();
    std.debug.print("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    try std.testing.expect(response.status == .ok);
    try std.testing.expectEqualStrings(test_content, response.body);
    std.debug.print("=== DONE 05_getObject: {} - \"{s}\" ===\n", .{ response.status, response.body });
}

// 6. Delete object
test "06_deleteObject" {
    std.debug.print("\n=== START 06_deleteObject ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling deleteObject...\n", .{});

    var response = try ctx.client.deleteObject(test_bucket, test_key);
    defer response.deinit();
    std.debug.print("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });
    // 204 No Content is expected for successful delete
    try std.testing.expect(response.status == .no_content or response.status == .ok);
    std.debug.print("=== DONE 06_deleteObject: {} ===\n", .{response.status});
}

// 7. Delete bucket
test "07_deleteBucket" {
    std.debug.print("\n=== START 07_deleteBucket ===\n", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();
    std.debug.print("  calling deleteBucket...\n", .{});

    var response = try ctx.client.deleteBucket(test_bucket);
    defer response.deinit();
    std.debug.print("  Got response: {} body_len={d}\n", .{ response.status, response.body.len });

    // 204 No Content is expected for successful delete
    try std.testing.expect(response.status == .no_content or response.status == .ok);
    std.debug.print("=== DONE 07_deleteBucket: {} ===\n", .{response.status});
}
