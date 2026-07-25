# dynamo — Minimal DynamoDB client

Module of [aws_zig](../../README.md). Import as `@import("dynamo")`.

Lightweight DynamoDB client: pure Zig, AWS SigV4, env/STS credentials, small API surface.

Structs serialize to DynamoDB AttributeValues at **comptime** (Zig 0.17 reflection). Field names on Zig structs are attribute names.

## Features

- **Minimal ops**: PutItem, GetItem, DeleteItem, Query, CreateTable, DeleteTable
- **Comptime serialization**: Zig structs → DynamoDB items (`S`, `N`, `BOOL`, `NULL`, `L`, `M`)
- **AWS credentials**: `AWS_ACCESS_KEY_ID` / `SECRET` / `SESSION_TOKEN` / region
- **STS Web Identity**: `AssumeRoleWithWebIdentity` via `dynamo.sts`
- **Custom endpoint**: Floci / LocalStack via `AWS_ENDPOINT_URL`, or `DYNAMODB_ENDPOINT` / `Config.endpoint`

## Quick start

```zig
const std = @import("std");
const dynamo = @import("dynamo");

const Order = struct {
    customer_id: []const u8,
    order_id: []const u8,
    total: i64,
    status: []const u8,
    note: ?[]const u8 = null, // omitted from put when null
};

pub fn main(init: std.process.Init) !void {
    var config = try dynamo.Client.Config.fromEnvMap(init.environ_map);
    var client = try dynamo.Client.init(init.gpa, config, .{ .io = init.io });
    defer client.deinit();

    try client.put("orders", Order{
        .customer_id = "acme",
        .order_id = "42",
        .total = 100,
        .status = "open",
    }, .{});

    if (try client.get(Order, "orders", .{
        .customer_id = "acme",
        .order_id = "42",
    }, .{})) |item| {
        var owned = item;
        defer dynamo.free(init.gpa, &owned);
        std.debug.print("{s}\n", .{owned.status});
    }

    var page = try client.queryHash(Order, "orders", "customer_id", "acme", .{});
    defer page.deinit();
}
```

## Attribute mapping

| Zig type | DynamoDB |
|----------|----------|
| `[]const u8`, `[]u8` | `S` |
| integers / floats | `N` |
| `bool` | `BOOL` |
| `?T` | omitted on put when null; missing becomes null on get |
| struct | nested `M` |
| `[]T` | `L` |
| enum | `S` (tag name) |

Field names are attribute names. Keys for get/delete are partial structs with the key attributes.

## Create table (keys + secondary indexes)

```zig
const gsis = [_]dynamo.Client.SecondaryIndex{
    .{
        .name = "byStatus",
        .hash_key = .{ .name = "status" },
        .range_key = .{ .name = "order_id" },
        .projection = .all, // .keys_only | .include (+ non_key_attributes)
    },
};

try client.createTable("orders", .{
    .hash_key = .{ .name = "customer_id" },
    .range_key = .{ .name = "order_id" },
    .global_secondary_indexes = &gsis,
    // .local_secondary_indexes = &lsis, // LSI hash must match table hash
});
try client.deleteTable("orders", .{});
```

Attribute definitions are collected automatically from the table key and all index keys.

## Query

**Common case:** hash key equality (base table or GSI via `index_name`):

```zig
var page = try client.queryHash(Order, "orders", "customer_id", "acme", .{
    .limit = 50,
    // .index_name = "byStatus",
});
defer page.deinit();
// next page:
// .exclusive_start_key_json = page.last_evaluated_key_json
```

**Custom** `KeyConditionExpression` via `client.query` with typed expression maps:

```zig
const names = [_]dynamo.ExpressionName{
    .{ .key = "#pk", .name = "customer_id" },
    .{ .key = "#sk", .name = "order_id" },
};
const pk_json = try dynamo.encodeValue(allocator, "acme");
defer allocator.free(pk_json);
const sk_json = try dynamo.encodeValue(allocator, "4");
defer allocator.free(sk_json);
const values = [_]dynamo.ExpressionValue{
    .{ .key = ":pk", .value_json = pk_json },
    .{ .key = ":sk", .value_json = sk_json },
};

var page = try client.query(Order, "orders", .{
    .key_condition = "#pk = :pk AND begins_with(#sk, :sk)",
    .expression_attribute_names = &names,
    .expression_attribute_values = &values,
    .limit = 50,
});
defer page.deinit();
```

Prefer `queryHash` for simple hash-key equality.

## Auth

- `Client.Config.fromEnvMap`: standard AWS env vars; optional `DYNAMODB_ENDPOINT`
- `dynamo.sts.assumeRoleWithWebIdentity` + `Config.fromStsCredentials`

## Ownership (`dynamo.free`)

Decoded items own every pointer/slice field (including values filled from struct
field defaults such as `name: []const u8 = "unknown"`). Call `dynamo.free` once
per item from `get`, or `ResultsPage.deinit` for query results.

## Retries

`RequestOptions.max_attempts` applies to the **whole request**: connect, send,
receive, HTTP 5xx/429, and DynamoDB throttle bodies
(`ProvisionedThroughputExceeded`, `RequestLimitExceeded`, and similar), with
exponential backoff and jitter from `initial_retry_time`.

## Limitations (v0)

- No UpdateItem, Scan, BatchWrite, TransactWrite
- No expression-builder DSL (pass pre-encoded AttributeValue JSON for query values)

## Example

```bash
zig build example-dynamo-basic   # needs credentials + table
```

Source: [`examples/dynamo/basic.zig`](../../examples/dynamo/basic.zig).

## Tests

```bash
zig build test
```

### Integration tests

Runs when `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set; otherwise skips.

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1   # optional, defaults to us-east-1
zig build integration-test-dynamo
```

Creates/uses table `zdb-integration-test` (override with `ZDB_TEST_TABLE`), then put/get/query/delete and tears the table down.

Optional endpoint: `DYNAMODB_ENDPOINT` / `AWS_ENDPOINT_URL_DYNAMODB` / `AWS_ENDPOINT_URL`.
