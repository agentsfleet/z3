//! Signed DynamoDB JSON POST requests.
const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lib = @import("lib");
const internal = lib.internal;
const signing = lib.signing;
const types = @import("../types.zig");

pub const ClientConfig = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
    region: []const u8,
    endpoint: ?[]const u8 = null,
};

pub const Response = struct {
    status: http.Status,
    body: []u8,
    allocator: Allocator,
    /// Owned copy of response head bytes (kept for status); freed on deinit.
    head_bytes: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.head_bytes);
        if (self.body.len > 0) self.allocator.free(self.body);
    }
};

pub const RequestError = error{
    InvalidUri,
    InvalidMaxAttempts,
    ConnectionFailed,
    SendFailed,
    FlushFailed,
    ReceiveFailed,
    ReadFailed,
    WriteFailed,
    RequestTooLong,
    StringToSignTooLong,
    KeyTooLong,
    CopyResponseHeadFailed,
    ParseResponseHeadFailed,
} || Allocator.Error;

/// Build endpoint URL and host for DynamoDB.
pub fn endpointUrl(allocator: Allocator, config: ClientConfig) ![]u8 {
    if (config.endpoint) |ep| {
        // Ensure trailing path works with Uri.parse; strip trailing slash for host extract consistency
        if (std.mem.endsWith(u8, ep, "/")) {
            return try allocator.dupe(u8, ep);
        }
        return try std.fmt.allocPrint(allocator, "{s}/", .{ep});
    }
    return try std.fmt.allocPrint(allocator, "https://dynamodb.{s}.amazonaws.com/", .{config.region});
}

pub fn hostFromEndpoint(allocator: Allocator, endpoint: []const u8) ![]u8 {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidUri;
    const host = uri.host orelse return error.InvalidUri;
    const host_str = switch (host) {
        .raw, .percent_encoded => |s| s,
    };
    if (uri.port) |port| {
        // Include non-default ports in Host header
        if (port != 443 and port != 80) {
            return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host_str, port });
        }
    }
    return try allocator.dupe(u8, host_str);
}

fn isRetryableTransportError(err: RequestError) bool {
    return switch (err) {
        error.ConnectionFailed,
        error.SendFailed,
        error.FlushFailed,
        error.ReceiveFailed,
        error.ReadFailed,
        error.WriteFailed,
        => true,
        else => false,
    };
}

fn isRetryableResponse(status: http.Status, body: []const u8) bool {
    return switch (status) {
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        .too_many_requests,
        => true,
        else => blk: {
            // DynamoDB often returns 400 with a retryable exception name in the body.
            if (std.mem.indexOf(u8, body, "ProvisionedThroughputExceededException") != null) break :blk true;
            if (std.mem.indexOf(u8, body, "RequestLimitExceeded") != null) break :blk true;
            if (std.mem.indexOf(u8, body, "ThrottlingException") != null) break :blk true;
            if (std.mem.indexOf(u8, body, "InternalServerError") != null) break :blk true;
            if (std.mem.indexOf(u8, body, "TransactionInProgressException") != null) break :blk true;
            break :blk false;
        },
    };
}

fn sleepBackoff(http_client: *http.Client, options: types.RequestOptions, attempt: usize) void {
    // attempt is 1-based; delay grows as initial * 2^(attempt-1) with ±jitter.
    // Saturating arithmetic keeps extreme initial_retry_time from overflowing.
    const shift: u6 = @intCast(@min(attempt -| 1, 6));
    const factor: u64 = @as(u64, 1) << shift;
    const base = options.initial_retry_time *| factor;
    var rand_int: [1]u8 = undefined;
    http_client.io.random(&rand_int);
    const jitter: u64 = rand_int[0] % 50;
    const interval: u64 = if (rand_int[0] % 2 == 0 and base > jitter)
        base - jitter
    else
        base +| jitter;
    const ms = if (interval == 0) @as(u64, 1) else interval;
    http_client.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Execute a signed DynamoDB request with whole-request retries.
///
/// Retries cover connection creation, send/receive/read failures, HTTP 5xx /
/// 429, and common DynamoDB throttle / internal error bodies. Non-retryable
/// application errors (e.g. ValidationException) are returned immediately.
pub fn execute(
    allocator: Allocator,
    http_client: *http.Client,
    config: ClientConfig,
    target: []const u8,
    body: []const u8,
    options: types.RequestOptions,
) RequestError!Response {
    if (options.max_attempts == 0) return error.InvalidMaxAttempts;

    const url = try endpointUrl(allocator, config);
    defer allocator.free(url);

    const host = try hostFromEndpoint(allocator, url);
    defer allocator.free(host);

    const uri = std.Uri.parse(url) catch return error.InvalidUri;

    var attempt: usize = 1;
    while (attempt <= options.max_attempts) : (attempt += 1) {
        const result = executeOnce(allocator, http_client, config, target, body, options, host, uri) catch |err| {
            if (attempt == options.max_attempts or !isRetryableTransportError(err)) return err;
            sleepBackoff(http_client, options, attempt);
            continue;
        };

        if (attempt < options.max_attempts and isRetryableResponse(result.status, result.body)) {
            var doomed = result;
            doomed.deinit();
            sleepBackoff(http_client, options, attempt);
            continue;
        }

        return result;
    }
    unreachable;
}

fn executeOnce(
    allocator: Allocator,
    http_client: *http.Client,
    config: ClientConfig,
    target: []const u8,
    body: []const u8,
    options: types.RequestOptions,
    host: []const u8,
    uri: std.Uri,
) RequestError!Response {
    const timestamp = internal.getUnixTimestamp();
    var date_buf: [16]u8 = undefined;
    internal.formatAmzDate(timestamp, &date_buf);
    const date_header = date_buf[0..];

    var content_hash_buf: [64]u8 = undefined;
    internal.sha256Hex(body, &content_hash_buf);
    const content_hash = content_hash_buf[0..];

    var headers_to_sign = std.ArrayList(signing.HeaderToSign).empty;
    defer headers_to_sign.deinit(allocator);

    try headers_to_sign.append(allocator, .{ .name = "content-type", .value = "application/x-amz-json-1.0" });
    try headers_to_sign.append(allocator, .{ .name = "host", .value = host });
    try headers_to_sign.append(allocator, .{ .name = "x-amz-content-sha256", .value = content_hash });
    try headers_to_sign.append(allocator, .{ .name = "x-amz-date", .value = date_header });
    try headers_to_sign.append(allocator, .{ .name = "x-amz-target", .value = target });
    if (config.session_token) |token| {
        try headers_to_sign.append(allocator, .{ .name = "x-amz-security-token", .value = token });
    }

    const auth_header = try signing.signRequest(
        allocator,
        config.access_key_id,
        config.secret_access_key,
        config.region,
        "dynamodb",
        "POST",
        "/",
        "",
        headers_to_sign.items,
    );
    defer allocator.free(auth_header);

    var owned = std.ArrayList(http.Header).empty;
    defer {
        for (owned.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        owned.deinit(allocator);
    }

    try appendHeader(allocator, &owned, "Content-Type", "application/x-amz-json-1.0");
    try appendHeader(allocator, &owned, "X-Amz-Date", date_header);
    try appendHeader(allocator, &owned, "X-Amz-Content-Sha256", content_hash);
    try appendHeader(allocator, &owned, "X-Amz-Target", target);
    try appendHeader(allocator, &owned, "Authorization", auth_header);
    try appendHeader(allocator, &owned, "Accept-Encoding", "identity");
    if (config.session_token) |token| {
        try appendHeader(allocator, &owned, "X-Amz-Security-Token", token);
    }

    var http_req = http_client.request(.POST, uri, .{
        .extra_headers = owned.items,
    }) catch return error.ConnectionFailed;
    defer http_req.deinit();

    http_req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = http_req.sendBody(&.{}) catch return error.SendFailed;
    body_writer.writer.writeAll(body) catch return error.WriteFailed;
    body_writer.end() catch return error.WriteFailed;
    http_req.connection.?.flush() catch return error.FlushFailed;

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

    const header_copy = allocator.dupe(u8, response.head.bytes) catch return error.CopyResponseHeadFailed;
    errdefer allocator.free(header_copy);
    const resp_head = http.Client.Response.Head.parse(header_copy) catch return error.ParseResponseHeadFailed;

    const response_body: []u8 = if (response.head.status == .no_content)
        ""
    else blk: {
        var transfer_buffer: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        break :blk reader.allocRemaining(allocator, Io.Limit.limited(options.max_body_size)) catch return error.ReadFailed;
    };

    return .{
        .status = resp_head.status,
        .body = response_body,
        .allocator = allocator,
        .head_bytes = header_copy,
    };
}

fn appendHeader(allocator: Allocator, list: *std.ArrayList(http.Header), name: []const u8, value: []const u8) !void {
    const n = try allocator.dupe(u8, name);
    errdefer allocator.free(n);
    const v = try allocator.dupe(u8, value);
    errdefer allocator.free(v);
    try list.append(allocator, .{ .name = n, .value = v });
}

test "endpointUrl default and custom" {
    const def = try endpointUrl(std.testing.allocator, .{
        .access_key_id = "a",
        .secret_access_key = "s",
        .region = "eu-west-1",
    });
    defer std.testing.allocator.free(def);
    try std.testing.expectEqualStrings("https://dynamodb.eu-west-1.amazonaws.com/", def);

    const custom = try endpointUrl(std.testing.allocator, .{
        .access_key_id = "a",
        .secret_access_key = "s",
        .region = "us-east-1",
        .endpoint = "http://localhost:8000",
    });
    defer std.testing.allocator.free(custom);
    try std.testing.expectEqualStrings("http://localhost:8000/", custom);
}

test "isRetryableResponse detects throttle and 5xx" {
    try std.testing.expect(isRetryableResponse(.internal_server_error, ""));
    try std.testing.expect(isRetryableResponse(.too_many_requests, ""));
    try std.testing.expect(isRetryableResponse(.bad_request, "{\"__type\":\"…ProvisionedThroughputExceededException\"}"));
    try std.testing.expect(!isRetryableResponse(.bad_request, "{\"__type\":\"com.amazon.coral.validate#ValidationException\"}"));
}

test "retry backoff base saturates for extreme initial_retry_time" {
    // Mirrors sleepBackoff scaling: initial * 2^min(attempt-1, 6) with *|.
    const initial: u64 = std.math.maxInt(u64);
    const shift: u6 = 6;
    const factor: u64 = @as(u64, 1) << shift;
    const base = initial *| factor;
    try std.testing.expectEqual(std.math.maxInt(u64), base);
    const with_jitter = base +| @as(u64, 49);
    try std.testing.expectEqual(std.math.maxInt(u64), with_jitter);
}
