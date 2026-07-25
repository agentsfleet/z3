//! DynamoDB integration tests.
//!
//! Skips when `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are missing.
//! Hits real AWS DynamoDB by default; optional local endpoint via env.
//!
//! ```
//! export AWS_ACCESS_KEY_ID=...
//! export AWS_SECRET_ACCESS_KEY=...
//! export AWS_REGION=us-east-1   # or AWS_DEFAULT_REGION
//! zig build integration-test
//! ```
//!
//! Optional endpoint (first match): `DYNAMODB_ENDPOINT` → `AWS_ENDPOINT_URL_DYNAMODB` → `AWS_ENDPOINT_URL`
//! Optional table name: `ZDB_TEST_TABLE` (default `zdb-integration-test`)
const std = @import("std");
const zdb = @import("zdb");
const Client = zdb.Client;

const test_table = "zdb-integration-test";

const Order = struct {
    customer_id: []const u8,
    order_id: []const u8,
    total: i64,
    status: []const u8,
    note: ?[]const u8 = null,
};

const TestContext = struct {
    gpa: std.heap.DebugAllocator(.{}),
    client: Client,
    table: []const u8,

    pub fn init() !*TestContext {
        const environ = std.testing.environ;

        const access_key = environ.getPosix("AWS_ACCESS_KEY_ID") orelse return error.SkipZigTest;
        const secret_key = environ.getPosix("AWS_SECRET_ACCESS_KEY") orelse return error.SkipZigTest;

        const endpoint = environ.getPosix("DYNAMODB_ENDPOINT") orelse
            environ.getPosix("AWS_ENDPOINT_URL_DYNAMODB") orelse
            environ.getPosix("AWS_ENDPOINT_URL");

        const region = environ.getPosix("AWS_REGION") orelse
            environ.getPosix("AWS_DEFAULT_REGION") orelse
            "us-east-1";

        const config: Client.Config = .{
            .access_key_id = access_key,
            .secret_access_key = secret_key,
            .session_token = environ.getPosix("AWS_SESSION_TOKEN"),
            .region = region,
            .endpoint = endpoint,
        };

        const ctx = try std.testing.allocator.create(TestContext);
        ctx.gpa = .init;
        const allocator = ctx.gpa.allocator();

        std.log.info("  endpoint={s} region={s}", .{
            endpoint orelse "(aws default)",
            region,
        });

        ctx.client = try Client.init(allocator, config, .{ .io = std.testing.io });
        ctx.table = environ.getPosix("ZDB_TEST_TABLE") orelse test_table;
        std.log.info("  table={s}", .{ctx.table});
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

// 1. Create table (hash + range)
test "01_createTable" {
    std.log.info("=== START 01_createTable ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    try ctx.client.createTable(ctx.table, .{
        .hash_key = .{ .name = "customer_id", .attr_type = "S" },
        .range_key = .{ .name = "order_id", .attr_type = "S" },
    });

    // Real AWS CreateTable is async; wait until PutItem succeeds (or timeout).
    var attempt: usize = 0;
    while (attempt < 30) : (attempt += 1) {
        ctx.client.put(ctx.table, Order{
            .customer_id = "_probe",
            .order_id = "0",
            .total = 0,
            .status = "probe",
        }, .{}) catch {
            std.testing.io.sleep(.fromMilliseconds(1000), .awake) catch {};
            continue;
        };
        // cleanup probe row
        ctx.client.delete(ctx.table, .{ .customer_id = "_probe", .order_id = "0" }, .{}) catch {};
        break;
    } else {
        return error.TableNotActive;
    }

    std.log.info("=== DONE 01_createTable ===\n", .{});
}

// 2. Put item
test "02_put" {
    std.log.info("=== START 02_put ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    try ctx.client.put(ctx.table, Order{
        .customer_id = "acme",
        .order_id = "42",
        .total = 100,
        .status = "open",
        .note = "integration",
    }, .{});

    try ctx.client.put(ctx.table, Order{
        .customer_id = "acme",
        .order_id = "43",
        .total = 200,
        .status = "paid",
        .note = null,
    }, .{});

    std.log.info("=== DONE 02_put ===\n", .{});
}

// 3. Get item
test "03_get" {
    std.log.info("=== START 03_get ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    const got = try ctx.client.get(Order, ctx.table, .{
        .customer_id = "acme",
        .order_id = "42",
    }, .{});
    try std.testing.expect(got != null);
    var item = got.?;
    defer zdb.free(ctx.gpa.allocator(), &item);

    try std.testing.expectEqualStrings("acme", item.customer_id);
    try std.testing.expectEqualStrings("42", item.order_id);
    try std.testing.expectEqual(@as(i64, 100), item.total);
    try std.testing.expectEqualStrings("open", item.status);
    try std.testing.expectEqualStrings("integration", item.note.?);

    std.log.info("=== DONE 03_get ===\n", .{});
}

// 3b. Get missing
test "03b_getMissing" {
    std.log.info("=== START 03b_getMissing ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    const got = try ctx.client.get(Order, ctx.table, .{
        .customer_id = "nope",
        .order_id = "missing",
    }, .{});
    try std.testing.expect(got == null);

    std.log.info("=== DONE 03b_getMissing ===\n", .{});
}

// 4. Query by hash key
test "04_queryHash" {
    std.log.info("=== START 04_queryHash ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    var page = try ctx.client.queryHash(Order, ctx.table, "customer_id", "acme", .{});
    defer page.deinit();

    try std.testing.expect(page.items.len >= 2);
    std.log.info("  query returned {d} items", .{page.items.len});

    var found_42 = false;
    var found_43 = false;
    for (page.items) |it| {
        if (std.mem.eql(u8, it.order_id, "42")) found_42 = true;
        if (std.mem.eql(u8, it.order_id, "43")) found_43 = true;
    }
    try std.testing.expect(found_42);
    try std.testing.expect(found_43);

    std.log.info("=== DONE 04_queryHash ===\n", .{});
}

// 5. Delete item
test "05_delete" {
    std.log.info("=== START 05_delete ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    try ctx.client.delete(ctx.table, .{
        .customer_id = "acme",
        .order_id = "43",
    }, .{});

    const got = try ctx.client.get(Order, ctx.table, .{
        .customer_id = "acme",
        .order_id = "43",
    }, .{});
    try std.testing.expect(got == null);

    std.log.info("=== DONE 05_delete ===\n", .{});
}

// 6. Delete table (cleanup)
test "06_deleteTable" {
    std.log.info("=== START 06_deleteTable ===", .{});

    var ctx = try TestContext.init();
    defer ctx.deinit();

    try ctx.client.deleteTable(ctx.table, .{});

    std.log.info("=== DONE 06_deleteTable ===\n", .{});
}
