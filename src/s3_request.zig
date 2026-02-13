const std = @import("std");
const http = std.http;
const Io = std.Io;
const internal = @import("s3_internal.zig");
const signing = @import("s3_signing.zig");
const url = @import("s3_url.zig");
const request_types = @import("s3_request_types.zig");
const S3Client = @import("s3_client.zig").S3Client;

const RequestParams = struct {
    query: ?[]const u8 = null,
    body: []const u8 = "",
    copy_source: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
    body_len: ?usize = null,
    range: ?S3Client.ContentRange = null,
    content_type: ?[]const u8 = null,
    metadata: ?[]const S3Client.Metadata = null,
    options: S3Client.RequestOptions = .{},
};

pub fn prepareRequest(
    self: *S3Client,
    method: http.Method,
    bucket: ?[]const u8,
    key: ?[]const u8,
    params: RequestParams,
) !request_types.UnifiedRequest {
    const url_str = if (bucket) |b|
        if (key) |k|
            try url.buildUrl(self, b, k, params.query)
        else
            try url.buildBucketUrl(self, b, params.query)
    else
        try url.buildServiceUrl(self);
    errdefer self.allocator.free(url_str);

    const host = if (bucket) |b| try url.getHost(self, b) else try url.getServiceHost(self);
    defer self.allocator.free(host);

    const timestamp = internal.getUnixTimestamp();
    var date_header_buf: [16]u8 = undefined;
    internal.formatAmzDate(timestamp, &date_header_buf);
    const date_header = &date_header_buf;

    const body_len = params.body_len orelse params.body.len;
    const content_hash = if (params.content_hash) |hash|
        hash
    else blk: {
        var content_hash_buf: [64]u8 = undefined;
        internal.sha256Hex(params.body, &content_hash_buf);
        break :blk &content_hash_buf;
    };

    var headers_to_sign = std.ArrayListUnmanaged(signing.HeaderToSign){};
    defer headers_to_sign.deinit(self.allocator);
    try headers_to_sign.append(self.allocator, .{ .name = "host", .value = host });
    try headers_to_sign.append(self.allocator, .{ .name = "x-amz-content-sha256", .value = content_hash });
    try headers_to_sign.append(self.allocator, .{ .name = "x-amz-date", .value = date_header });
    if (params.copy_source) |src| {
        try headers_to_sign.append(self.allocator, .{ .name = "x-amz-copy-source", .value = src });
    }

    var metadata_sign_names = std.ArrayListUnmanaged([]u8){};
    defer {
        for (metadata_sign_names.items) |name| {
            self.allocator.free(name);
        }
        metadata_sign_names.deinit(self.allocator);
    }
    if (params.metadata) |metadata| {
        for (metadata) |item| {
            const raw_name = try std.fmt.allocPrint(self.allocator, "x-amz-meta-{s}", .{item.name});
            defer self.allocator.free(raw_name);
            const lower_name = try internal.toLowerAlloc(self.allocator, raw_name);
            try metadata_sign_names.append(self.allocator, lower_name);
            try headers_to_sign.append(self.allocator, .{ .name = lower_name, .value = item.value });
        }
    }

    const auth_header = try signing.signRequest(
        self,
        @tagName(method),
        bucket,
        key,
        params.query,
        headers_to_sign.items,
    );
    errdefer self.allocator.free(auth_header);

    var temp_headers = std.ArrayListUnmanaged(http.Header){};
    var temp_headers_moved = false;
    defer {
        if (!temp_headers_moved) {
            for (temp_headers.items) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
            temp_headers.deinit(self.allocator);
        }
    }

    try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Date"), .value = try self.allocator.dupe(u8, date_header) });
    try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Content-Sha256"), .value = try self.allocator.dupe(u8, content_hash) });
    try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Authorization"), .value = auth_header });
    try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Accept-Encoding"), .value = try self.allocator.dupe(u8, "identity") });

    if (params.copy_source) |src| {
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Copy-Source"), .value = try self.allocator.dupe(u8, src) });
    }

    if (params.metadata) |metadata| {
        for (metadata) |item| {
            const raw_name = try std.fmt.allocPrint(self.allocator, "x-amz-meta-{s}", .{item.name});
            defer self.allocator.free(raw_name);
            const lower_name = try internal.toLowerAlloc(self.allocator, raw_name);
            const value_dupe = try self.allocator.dupe(u8, item.value);
            var owned = false;
            errdefer if (!owned) {
                self.allocator.free(lower_name);
                self.allocator.free(value_dupe);
            };
            try temp_headers.append(self.allocator, .{ .name = lower_name, .value = value_dupe });
            owned = true;
        }
    }

    if (params.content_type) |content_type| {
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Content-Type"), .value = try self.allocator.dupe(u8, content_type) });
    } else if (method == .PUT and body_len > 0) {
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Content-Type"), .value = try self.allocator.dupe(u8, "application/octet-stream") });
    }

    if (params.range) |range| {
        const range_fmt = try std.fmt.allocPrint(self.allocator, "bytes={d}-{d}", .{ range.start, range.end });
        defer self.allocator.free(range_fmt);
        try temp_headers.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, "Range"),
            .value = try self.allocator.dupe(u8, range_fmt),
        });
    }

    // Add Content-Length: 0 and Connection: close for DELETE to work around TLS+async Io issue
    if (method == .DELETE) {
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Content-Length"), .value = try self.allocator.dupe(u8, "0") });
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Connection"), .value = try self.allocator.dupe(u8, "close") });
    }

    const owned_headers = try temp_headers.toOwnedSlice(self.allocator);
    temp_headers_moved = true;

    return request_types.UnifiedRequest{
        .allocator = self.allocator,
        .http_method = method,
        .url = url_str,
        .headers = owned_headers,
        .body = params.body,
        .content_length = body_len,
        .max_body_size = params.options.max_body_size,
        .is_bodiless = body_len == 0 and method != .PUT and params.copy_source == null,
    };
}

pub fn executeRequest(self: *S3Client, req: *request_types.UnifiedRequest) !S3Client.Response {
    const uri = std.Uri.parse(req.url) catch return error.InvalidUri;

    // std.log.debug("URI: {}", .{uri});

    var http_req = self.http_client.request(req.http_method, uri, .{
        .extra_headers = req.headers,
    }) catch return error.ConnectionFailed;
    defer http_req.deinit();

    std.log.info("URI Scheme: {s}", .{http_req.uri.host.?.percent_encoded});
    std.log.info("URI: {s}", .{http_req.uri.path.percent_encoded});

    // std.log.info("REQUEST:\n{any}", .{http_req});

    if (req.is_bodiless) {
        http_req.sendBodiless() catch return error.SendFailed;
        // Extra flush to ensure data is fully sent before waiting for response
        // (workaround for TLS+async Io buffering issue with bodiless requests)
        http_req.connection.?.flush() catch return error.FlushFailed;
    } else {
        std.debug.assert(req.body.len == req.content_length);
        http_req.transfer_encoding = .{ .content_length = req.content_length };
        var body_writer = http_req.sendBody(&.{}) catch return error.SendFailed;
        body_writer.writer.writeAll(req.body) catch return error.WriteFailed;
        body_writer.end() catch return error.WriteFailed;
        http_req.connection.?.flush() catch return error.FlushFailed;
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

    const response_body: []u8 = if (response.head.status == .no_content or req.http_method == .HEAD)
        ""
    else blk: {
        var transfer_buffer: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        break :blk reader.allocRemaining(self.allocator, Io.Limit.limited(req.max_body_size)) catch return error.ReadFailed;
    };

    return S3Client.Response{
        .status = response.head.status,
        .body = response_body,
        .allocator = self.allocator,
    };
}

pub fn executeRequestWithReader(self: *S3Client, req: *request_types.UnifiedRequest, reader: *Io.Reader) !S3Client.Response {
    const uri = std.Uri.parse(req.url) catch return error.InvalidUri;

    var http_req = self.http_client.request(req.http_method, uri, .{
        .extra_headers = req.headers,
    }) catch return error.ConnectionFailed;
    defer http_req.deinit();

    std.debug.assert(!req.is_bodiless);
    http_req.transfer_encoding = .{ .content_length = req.content_length };
    var body_buffer: [16 * 1024]u8 = undefined;
    var body_writer = http_req.sendBody(&body_buffer) catch return error.SendFailed;
    const written = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
    };
    if (written != req.content_length) return error.BodyLengthMismatch;
    body_writer.end() catch return error.WriteFailed;
    http_req.connection.?.flush() catch return error.FlushFailed;

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

    const response_body: []u8 = if (response.head.status == .no_content or req.http_method == .HEAD)
        ""
    else blk: {
        var transfer_buffer: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const response_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        break :blk response_reader.allocRemaining(self.allocator, Io.Limit.limited(req.max_body_size)) catch return error.ReadFailed;
    };

    return S3Client.Response{
        .status = response.head.status,
        .body = response_body,
        .allocator = self.allocator,
    };
}

pub fn executeRequestStream(self: *S3Client, req_in: request_types.UnifiedRequest) !S3Client.ObjectStream {
    var req = req_in;
    errdefer req.deinit();
    const uri = std.Uri.parse(req.url) catch return error.InvalidUri;

    const request_ptr = try self.allocator.create(http.Client.Request);
    errdefer self.allocator.destroy(request_ptr);

    request_ptr.* = self.http_client.request(req.http_method, uri, .{
        .extra_headers = req.headers,
    }) catch return error.ConnectionFailed;
    errdefer request_ptr.deinit();

    if (req.is_bodiless) {
        request_ptr.sendBodiless() catch return error.SendFailed;
        request_ptr.connection.?.flush() catch return error.FlushFailed;
    } else {
        std.debug.assert(req.body.len == req.content_length);
        request_ptr.transfer_encoding = .{ .content_length = req.content_length };
        var body_writer = request_ptr.sendBody(&.{}) catch return error.SendFailed;
        body_writer.writer.writeAll(req.body) catch return error.WriteFailed;
        body_writer.end() catch return error.WriteFailed;
        request_ptr.connection.?.flush() catch return error.FlushFailed;
    }

    var stream = S3Client.ObjectStream{
        .allocator = self.allocator,
        .request = request_ptr,
        .response = undefined,
        .request_data = req,
    };

    stream.response = request_ptr.receiveHead(&stream.redirect_buffer) catch return error.ReceiveFailed;
    return stream;
}

test "prepareRequest signs metadata headers" {
    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .region = "us-east-1",
            .endpoint = "https://example.com",
        },
    };

    const metadata = [_]S3Client.Metadata{
        .{ .name = "Color", .value = "blue" },
    };

    var req = try prepareRequest(&client, .PUT, "bucket", "key", .{
        .body = "data",
        .metadata = &metadata,
    });
    defer req.deinit();

    var saw_meta = false;
    var saw_signed = false;
    for (req.headers) |header| {
        if (std.mem.eql(u8, header.name, "x-amz-meta-color")) saw_meta = true;
        if (std.mem.eql(u8, header.name, "Authorization")) {
            if (std.mem.indexOf(u8, header.value, "SignedHeaders=")) |idx| {
                const tail = header.value[idx..];
                if (std.mem.indexOf(u8, tail, "x-amz-meta-color") != null) {
                    saw_signed = true;
                }
            }
        }
    }

    try std.testing.expect(saw_meta);
    try std.testing.expect(saw_signed);
}
