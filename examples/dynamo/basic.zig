//! Minimal put / get / queryHash example.
//! Requires AWS credentials and a table (or DynamoDB Local via DYNAMODB_ENDPOINT).
const std = @import("std");
const zdb = @import("zdb");

const Order = struct {
    customer_id: []const u8,
    order_id: []const u8,
    total: i64,
    status: []const u8,
    note: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const config = try zdb.Client.Config.fromEnvMap(env);
    // Override endpoint for DynamoDB Local:
    // var config = try zdb.Client.Config.fromEnvMap(env);
    // config.endpoint = "http://localhost:8000";

    var client = try zdb.Client.init(allocator, config, .{ .io = io });
    defer client.deinit();

    const table = "orders";

    try client.put(table, Order{
        .customer_id = "acme",
        .order_id = "42",
        .total = 100,
        .status = "open",
        .note = "first order",
    }, .{});

    if (try client.get(Order, table, .{
        .customer_id = "acme",
        .order_id = "42",
    }, .{})) |item| {
        var owned = item;
        defer zdb.free(allocator, &owned);
        std.debug.print("got order {s}/{s} total={d} status={s}\n", .{
            owned.customer_id,
            owned.order_id,
            owned.total,
            owned.status,
        });
    } else {
        std.debug.print("item not found\n", .{});
    }

    var page = try client.queryHash(Order, table, "customer_id", "acme", .{});
    defer page.deinit();
    std.debug.print("query returned {d} item(s)\n", .{page.items.len});
}
