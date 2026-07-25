//! DynamoDB operation implementations for `Client`.
const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const attr = @import("attr.zig");
const types = @import("types.zig");
const request = @import("http/request.zig");
const Client = @import("client.zig").Client;

pub fn init(allocator: Allocator, config: Client.Config, options: Client.InitOptions) !Client {
    if (options.http_client) |client| {
        return .{
            .allocator = allocator,
            .http_client = client,
            .owns_http_client = false,
            .config = config,
        };
    }

    // Validate `io` before allocating so we never leak the http.Client on error.
    const io = options.io orelse return error.IoRequired;
    const client = try allocator.create(http.Client);
    errdefer allocator.destroy(client);
    client.* = .{ .allocator = allocator, .io = io };
    return .{
        .allocator = allocator,
        .http_client = client,
        .owns_http_client = true,
        .config = config,
    };
}

pub fn deinit(self: *Client) void {
    if (self.owns_http_client) {
        self.http_client.deinit();
        self.allocator.destroy(self.http_client);
    }
}

/// CreateTable with hash (+ optional range) key, on-demand billing by default,
/// and optional GSI / LSI definitions.
pub fn createTable(self: *Client, table: []const u8, options: Client.CreateTableOptions) Client.RequestError!void {
    const body = try buildCreateTableBody(self.allocator, table, options);
    defer self.allocator.free(body);

    var resp = try call(self, "DynamoDB_20120810.CreateTable", body, options.request);
    defer resp.deinit();

    if (resp.status.class() == .success) return;
    if (options.ignore_if_exists and std.mem.indexOf(u8, resp.body, "ResourceInUseException") != null) return;
    try expectSuccess(&resp);
}

fn buildCreateTableBody(allocator: Allocator, table: []const u8, options: Client.CreateTableOptions) ![]u8 {
    // Collect unique AttributeDefinitions (table keys + index keys).
    var attrs = std.ArrayList(Client.KeyAttribute).empty;
    defer attrs.deinit(allocator);

    try addAttrDef(allocator, &attrs, options.hash_key);
    if (options.range_key) |rk| try addAttrDef(allocator, &attrs, rk);
    for (options.global_secondary_indexes) |idx| {
        try addAttrDef(allocator, &attrs, idx.hash_key);
        if (idx.range_key) |rk| try addAttrDef(allocator, &attrs, rk);
    }
    for (options.local_secondary_indexes) |idx| {
        try addAttrDef(allocator, &attrs, idx.hash_key);
        if (idx.range_key) |rk| try addAttrDef(allocator, &attrs, rk);
    }

    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);

    const table_json = try jsonStringAlloc(allocator, table);
    defer allocator.free(table_json);
    const billing = try jsonStringAlloc(allocator, options.billing_mode);
    defer allocator.free(billing);

    try body.appendSlice(allocator, "{\"TableName\":");
    try body.appendSlice(allocator, table_json);
    try body.appendSlice(allocator, ",\"BillingMode\":");
    try body.appendSlice(allocator, billing);

    try body.appendSlice(allocator, ",\"AttributeDefinitions\":[");
    for (attrs.items, 0..) |a, i| {
        if (i > 0) try body.append(allocator, ',');
        try writeAttrDef(&body, allocator, a);
    }

    try body.appendSlice(allocator, "],\"KeySchema\":");
    try writeKeySchema(&body, allocator, options.hash_key, options.range_key);

    if (options.global_secondary_indexes.len > 0) {
        try body.appendSlice(allocator, ",\"GlobalSecondaryIndexes\":[");
        for (options.global_secondary_indexes, 0..) |idx, i| {
            if (i > 0) try body.append(allocator, ',');
            try writeSecondaryIndex(&body, allocator, idx);
        }
        try body.append(allocator, ']');
    }

    if (options.local_secondary_indexes.len > 0) {
        try body.appendSlice(allocator, ",\"LocalSecondaryIndexes\":[");
        for (options.local_secondary_indexes, 0..) |idx, i| {
            if (i > 0) try body.append(allocator, ',');
            try writeSecondaryIndex(&body, allocator, idx);
        }
        try body.append(allocator, ']');
    }

    try body.append(allocator, '}');
    return body.toOwnedSlice(allocator);
}

fn addAttrDef(allocator: Allocator, list: *std.ArrayList(Client.KeyAttribute), key: Client.KeyAttribute) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing.name, key.name)) return;
    }
    try list.append(allocator, key);
}

fn writeAttrDef(body: *std.ArrayList(u8), allocator: Allocator, key: Client.KeyAttribute) !void {
    const name = try jsonStringAlloc(allocator, key.name);
    defer allocator.free(name);
    const typ = try jsonStringAlloc(allocator, key.attr_type);
    defer allocator.free(typ);
    try body.appendSlice(allocator, "{\"AttributeName\":");
    try body.appendSlice(allocator, name);
    try body.appendSlice(allocator, ",\"AttributeType\":");
    try body.appendSlice(allocator, typ);
    try body.append(allocator, '}');
}

fn writeKeySchema(
    body: *std.ArrayList(u8),
    allocator: Allocator,
    hash_key: Client.KeyAttribute,
    range_key: ?Client.KeyAttribute,
) !void {
    const hk = try jsonStringAlloc(allocator, hash_key.name);
    defer allocator.free(hk);
    try body.appendSlice(allocator, "[{\"AttributeName\":");
    try body.appendSlice(allocator, hk);
    try body.appendSlice(allocator, ",\"KeyType\":\"HASH\"}");
    if (range_key) |rk| {
        const name = try jsonStringAlloc(allocator, rk.name);
        defer allocator.free(name);
        try body.appendSlice(allocator, ",{\"AttributeName\":");
        try body.appendSlice(allocator, name);
        try body.appendSlice(allocator, ",\"KeyType\":\"RANGE\"}");
    }
    try body.append(allocator, ']');
}

fn writeSecondaryIndex(body: *std.ArrayList(u8), allocator: Allocator, idx: Client.SecondaryIndex) !void {
    const name = try jsonStringAlloc(allocator, idx.name);
    defer allocator.free(name);
    try body.appendSlice(allocator, "{\"IndexName\":");
    try body.appendSlice(allocator, name);
    try body.appendSlice(allocator, ",\"KeySchema\":");
    try writeKeySchema(body, allocator, idx.hash_key, idx.range_key);
    try body.appendSlice(allocator, ",\"Projection\":{\"ProjectionType\":\"");
    try body.appendSlice(allocator, idx.projection.asJson());
    try body.append(allocator, '"');
    if (idx.projection == .include and idx.non_key_attributes.len > 0) {
        try body.appendSlice(allocator, ",\"NonKeyAttributes\":[");
        for (idx.non_key_attributes, 0..) |attr_name, i| {
            if (i > 0) try body.append(allocator, ',');
            const a = try jsonStringAlloc(allocator, attr_name);
            defer allocator.free(a);
            try body.appendSlice(allocator, a);
        }
        try body.append(allocator, ']');
    }
    try body.appendSlice(allocator, "}}");
}

/// DeleteTable.
pub fn deleteTable(self: *Client, table: []const u8, options: Client.DeleteTableOptions) Client.RequestError!void {
    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);

    const body = try std.fmt.allocPrint(
        self.allocator,
        "{{\"TableName\":{s}}}",
        .{table_json},
    );
    defer self.allocator.free(body);

    var resp = try call(self, "DynamoDB_20120810.DeleteTable", body, options.request);
    defer resp.deinit();

    if (resp.status.class() == .success) return;
    if (options.ignore_if_missing and std.mem.indexOf(u8, resp.body, "ResourceNotFoundException") != null) return;
    try expectSuccess(&resp);
}

/// PutItem: encode `item` struct as DynamoDB attributes and store it.
pub fn put(self: *Client, table: []const u8, item: anytype, options: types.PutOptions) Client.RequestError!void {
    const item_json = try attr.encodeItem(self.allocator, item);
    defer self.allocator.free(item_json);

    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);

    const body = try std.fmt.allocPrint(
        self.allocator,
        "{{\"TableName\":{s},\"Item\":{s}}}",
        .{ table_json, item_json },
    );
    defer self.allocator.free(body);

    var resp = try call(self, "DynamoDB_20120810.PutItem", body, options.request);
    defer resp.deinit();
    try expectSuccess(&resp);
}

/// GetItem: returns null when the item does not exist.
/// String fields in the result are owned by `self.allocator`; free with `zdb.free`.
pub fn get(self: *Client, comptime T: type, table: []const u8, key: anytype, options: types.GetOptions) Client.RequestError!?T {
    const key_json = try attr.encodeItem(self.allocator, key);
    defer self.allocator.free(key_json);

    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);

    const body = if (options.consistent_read)
        try std.fmt.allocPrint(
            self.allocator,
            "{{\"TableName\":{s},\"Key\":{s},\"ConsistentRead\":true}}",
            .{ table_json, key_json },
        )
    else
        try std.fmt.allocPrint(
            self.allocator,
            "{{\"TableName\":{s},\"Key\":{s}}}",
            .{ table_json, key_json },
        );
    defer self.allocator.free(body);

    var resp = try call(self, "DynamoDB_20120810.GetItem", body, options.request);
    defer resp.deinit();
    try expectSuccess(&resp);

    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const item_val = parsed.value.object.get("Item") orelse return null;
    return try attr.decodeItem(self.allocator, T, item_val);
}

/// DeleteItem by key attributes.
pub fn delete(self: *Client, table: []const u8, key: anytype, options: types.DeleteOptions) Client.RequestError!void {
    const key_json = try attr.encodeItem(self.allocator, key);
    defer self.allocator.free(key_json);

    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);

    const body = try std.fmt.allocPrint(
        self.allocator,
        "{{\"TableName\":{s},\"Key\":{s}}}",
        .{ table_json, key_json },
    );
    defer self.allocator.free(body);

    var resp = try call(self, "DynamoDB_20120810.DeleteItem", body, options.request);
    defer resp.deinit();
    try expectSuccess(&resp);
}

/// Query by hash key equality: `hash_attr = hash_value`.
pub fn queryHash(
    self: *Client,
    comptime T: type,
    table: []const u8,
    hash_attr: []const u8,
    hash_value: anytype,
    options: types.QueryOptions,
) Client.RequestError!types.ResultsPage(T) {
    const value_json = try attr.encodeValue(self.allocator, hash_value);
    defer self.allocator.free(value_json);

    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);
    const attr_json = try jsonStringAlloc(self.allocator, hash_attr);
    defer self.allocator.free(attr_json);

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(self.allocator);

    try body_buf.appendSlice(self.allocator, "{\"TableName\":");
    try body_buf.appendSlice(self.allocator, table_json);
    try body_buf.appendSlice(self.allocator, ",\"KeyConditionExpression\":\"#hk = :hv\"");
    try body_buf.appendSlice(self.allocator, ",\"ExpressionAttributeNames\":{\"#hk\":");
    try body_buf.appendSlice(self.allocator, attr_json);
    try body_buf.appendSlice(self.allocator, "},\"ExpressionAttributeValues\":{\":hv\":");
    try body_buf.appendSlice(self.allocator, value_json);
    try body_buf.append(self.allocator, '}');

    try appendQueryCommonOpts(&body_buf, self.allocator, options, .{ .skip_expression_maps = true });

    try body_buf.append(self.allocator, '}');

    const body = try body_buf.toOwnedSlice(self.allocator);
    defer self.allocator.free(body);

    return queryExecute(self, T, body, options.request);
}

/// Query with a raw `KeyConditionExpression` and optional expression name/value maps.
///
/// ```zig
/// const names = [_]zdb.ExpressionName{.{ .key = "#pk", .name = "customer_id" }};
/// const pk_json = try zdb.encodeValue(allocator, "acme");
/// defer allocator.free(pk_json);
/// const values = [_]zdb.ExpressionValue{.{ .key = ":pk", .value_json = pk_json }};
/// var page = try client.query(Order, "orders", .{
///     .key_condition = "#pk = :pk",
///     .expression_attribute_names = &names,
///     .expression_attribute_values = &values,
/// });
/// ```
pub fn query(
    self: *Client,
    comptime T: type,
    table: []const u8,
    options: types.QueryOptions,
) Client.RequestError!types.ResultsPage(T) {
    const key_condition = options.key_condition orelse return error.MissingKeyCondition;

    const table_json = try jsonStringAlloc(self.allocator, table);
    defer self.allocator.free(table_json);
    const cond_json = try jsonStringAlloc(self.allocator, key_condition);
    defer self.allocator.free(cond_json);

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(self.allocator);

    try body_buf.appendSlice(self.allocator, "{\"TableName\":");
    try body_buf.appendSlice(self.allocator, table_json);
    try body_buf.appendSlice(self.allocator, ",\"KeyConditionExpression\":");
    try body_buf.appendSlice(self.allocator, cond_json);

    try appendQueryCommonOpts(&body_buf, self.allocator, options, .{});
    try body_buf.append(self.allocator, '}');

    const body = try body_buf.toOwnedSlice(self.allocator);
    defer self.allocator.free(body);

    return queryExecute(self, T, body, options.request);
}

const AppendQueryOpts = struct {
    /// When true, skip ExpressionAttributeNames/Values from options (queryHash
    /// already emitted its own maps).
    skip_expression_maps: bool = false,
};

fn appendQueryCommonOpts(
    body_buf: *std.ArrayList(u8),
    allocator: Allocator,
    options: types.QueryOptions,
    append_opts: AppendQueryOpts,
) Allocator.Error!void {
    if (options.limit) |lim| {
        var lim_buf: [48]u8 = undefined;
        const lim_s = std.fmt.bufPrint(&lim_buf, ",\"Limit\":{d}", .{lim}) catch unreachable;
        try body_buf.appendSlice(allocator, lim_s);
    }
    if (!options.scan_index_forward) {
        try body_buf.appendSlice(allocator, ",\"ScanIndexForward\":false");
    }
    if (options.consistent_read) {
        try body_buf.appendSlice(allocator, ",\"ConsistentRead\":true");
    }
    if (options.index_name) |idx| {
        const idx_json = try jsonStringAlloc(allocator, idx);
        defer allocator.free(idx_json);
        try body_buf.appendSlice(allocator, ",\"IndexName\":");
        try body_buf.appendSlice(allocator, idx_json);
    }
    if (options.exclusive_start_key_json) |lek| {
        try body_buf.appendSlice(allocator, ",\"ExclusiveStartKey\":");
        try body_buf.appendSlice(allocator, lek);
    }

    if (!append_opts.skip_expression_maps) {
        if (options.expression_attribute_names.len > 0) {
            try body_buf.appendSlice(allocator, ",\"ExpressionAttributeNames\":{");
            for (options.expression_attribute_names, 0..) |entry, i| {
                if (i > 0) try body_buf.append(allocator, ',');
                const k = try jsonStringAlloc(allocator, entry.key);
                defer allocator.free(k);
                const v = try jsonStringAlloc(allocator, entry.name);
                defer allocator.free(v);
                try body_buf.appendSlice(allocator, k);
                try body_buf.append(allocator, ':');
                try body_buf.appendSlice(allocator, v);
            }
            try body_buf.append(allocator, '}');
        }
        if (options.expression_attribute_values.len > 0) {
            try body_buf.appendSlice(allocator, ",\"ExpressionAttributeValues\":{");
            for (options.expression_attribute_values, 0..) |entry, i| {
                if (i > 0) try body_buf.append(allocator, ',');
                const k = try jsonStringAlloc(allocator, entry.key);
                defer allocator.free(k);
                try body_buf.appendSlice(allocator, k);
                try body_buf.append(allocator, ':');
                try body_buf.appendSlice(allocator, entry.value_json);
            }
            try body_buf.append(allocator, '}');
        }
    }
}

fn queryExecute(self: *Client, comptime T: type, body: []const u8, req_opts: types.RequestOptions) Client.RequestError!types.ResultsPage(T) {
    var resp = try call(self, "DynamoDB_20120810.Query", body, req_opts);
    defer resp.deinit();
    try expectSuccess(&resp);

    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const items_val = parsed.value.object.get("Items");
    if (items_val == null) {
        return .{
            .items = try self.allocator.alloc(T, 0),
            .last_evaluated_key_json = null,
            .allocator = self.allocator,
        };
    }
    if (items_val.? != .array) return error.InvalidResponse;

    const items = try self.allocator.alloc(T, items_val.?.array.items.len);
    var decoded: usize = 0;
    errdefer {
        for (items[0..decoded]) |*it| attr.free(self.allocator, it);
        self.allocator.free(items);
    }
    for (items_val.?.array.items, 0..) |item_val, i| {
        items[i] = try attr.decodeItem(self.allocator, T, item_val);
        decoded = i + 1;
    }

    var lek_json: ?[]u8 = null;
    errdefer if (lek_json) |p| self.allocator.free(p);
    if (parsed.value.object.get("LastEvaluatedKey")) |lek| {
        lek_json = std.json.Stringify.valueAlloc(self.allocator, lek, .{}) catch return error.InvalidResponse;
    }

    return .{
        .items = items,
        .last_evaluated_key_json = lek_json,
        .allocator = self.allocator,
    };
}

fn call(self: *Client, target: []const u8, body: []const u8, options: types.RequestOptions) Client.RequestError!request.Response {
    return request.execute(
        self.allocator,
        self.http_client,
        self.config.toRequestConfig(),
        target,
        body,
        options,
    );
}

fn expectSuccess(resp: *const request.Response) types.ServiceError!void {
    if (resp.status.class() == .success) return;

    // Best-effort map of DynamoDB exception names from body
    if (std.mem.indexOf(u8, resp.body, "ResourceNotFoundException") != null) return error.ResourceNotFound;
    if (std.mem.indexOf(u8, resp.body, "ResourceInUseException") != null) return error.ResourceInUse;
    if (std.mem.indexOf(u8, resp.body, "ConditionalCheckFailedException") != null) return error.ConditionalCheckFailed;
    if (std.mem.indexOf(u8, resp.body, "ValidationException") != null) return error.ValidationException;
    if (std.mem.indexOf(u8, resp.body, "AccessDeniedException") != null) return error.AccessDenied;
    if (std.mem.indexOf(u8, resp.body, "UnrecognizedClientException") != null) return error.AccessDenied;
    if (std.mem.indexOf(u8, resp.body, "InvalidSignatureException") != null) return error.AccessDenied;
    if (std.mem.indexOf(u8, resp.body, "ProvisionedThroughputExceededException") != null) return error.ProvisionedThroughputExceeded;
    if (std.mem.indexOf(u8, resp.body, "RequestLimitExceeded") != null) return error.RequestLimitExceeded;
    if (std.mem.indexOf(u8, resp.body, "InternalServerError") != null) return error.InternalServerError;

    const snippet_len = @min(resp.body.len, 240);
    std.log.err("DynamoDB request failed: status={} body={s}", .{
        resp.status,
        resp.body[0..snippet_len],
    });

    return switch (resp.status) {
        .unauthorized, .forbidden => error.AccessDenied,
        .not_found => error.ResourceNotFound,
        else => error.DynamoDbError,
    };
}

/// JSON-encode a string value including surrounding quotes.
fn jsonStringAlloc(allocator: Allocator, s: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
    return list.toOwnedSlice(allocator);
}

// ── unit tests ───────────────────────────────────────────────────────

test "put request body shape" {
    const Item = struct { pk: []const u8, n: i32 };
    const item_json = try attr.encodeItem(std.testing.allocator, Item{ .pk = "a", .n = 1 });
    defer std.testing.allocator.free(item_json);
    const table_json = try jsonStringAlloc(std.testing.allocator, "t");
    defer std.testing.allocator.free(table_json);
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"TableName\":{s},\"Item\":{s}}}", .{ table_json, item_json });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"TableName\":\"t\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Item\":{") != null);
}

test "createTable body includes GSI and attribute defs" {
    const gsis = [_]Client.SecondaryIndex{
        .{
            .name = "byStatus",
            .hash_key = .{ .name = "status", .attr_type = "S" },
            .range_key = .{ .name = "order_id", .attr_type = "S" },
            .projection = .all,
        },
        .{
            .name = "byTotal",
            .hash_key = .{ .name = "total", .attr_type = "N" },
            .projection = .keys_only,
        },
    };
    const body = try buildCreateTableBody(std.testing.allocator, "orders", .{
        .hash_key = .{ .name = "customer_id", .attr_type = "S" },
        .range_key = .{ .name = "order_id", .attr_type = "S" },
        .global_secondary_indexes = &gsis,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"TableName\":\"orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"AttributeName\":\"customer_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"AttributeName\":\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"AttributeName\":\"total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"AttributeType\":\"N\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"GlobalSecondaryIndexes\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"IndexName\":\"byStatus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"IndexName\":\"byTotal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ProjectionType\":\"ALL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ProjectionType\":\"KEYS_ONLY\"") != null);
    // AttributeDefinitions lists order_id once (also appears again in KeySchemas).
    const defs_start = std.mem.indexOf(u8, body, "\"AttributeDefinitions\":[").?;
    const defs_end = std.mem.indexOfPos(u8, body, defs_start, "],\"KeySchema\"").?;
    const defs = body[defs_start..defs_end];
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, defs, start, "\"AttributeName\":\"order_id\"")) |pos| {
        count += 1;
        start = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "createTable body LSI and INCLUDE projection" {
    const lsis = [_]Client.SecondaryIndex{.{
        .name = "bySk2",
        .hash_key = .{ .name = "pk", .attr_type = "S" },
        .range_key = .{ .name = "sk2", .attr_type = "S" },
        .projection = .include,
        .non_key_attributes = &.{"status"},
    }};
    const body = try buildCreateTableBody(std.testing.allocator, "t", .{
        .hash_key = .{ .name = "pk", .attr_type = "S" },
        .range_key = .{ .name = "sk", .attr_type = "S" },
        .local_secondary_indexes = &lsis,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"LocalSecondaryIndexes\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"IndexName\":\"bySk2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ProjectionType\":\"INCLUDE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"NonKeyAttributes\":[\"status\"]") != null);
}

test "query body includes expression attribute maps" {
    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(std.testing.allocator);

    try body_buf.appendSlice(std.testing.allocator, "{\"TableName\":\"t\",\"KeyConditionExpression\":\"#pk = :pk\"");

    const names = [_]types.ExpressionName{.{ .key = "#pk", .name = "customer_id" }};
    const values = [_]types.ExpressionValue{.{ .key = ":pk", .value_json = "{\"S\":\"acme\"}" }};
    try appendQueryCommonOpts(&body_buf, std.testing.allocator, .{
        .key_condition = "#pk = :pk",
        .expression_attribute_names = &names,
        .expression_attribute_values = &values,
        .limit = 10,
    }, .{});
    try body_buf.append(std.testing.allocator, '}');

    const body = body_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ExpressionAttributeNames\":{\"#pk\":\"customer_id\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"acme\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Limit\":10") != null);
}
