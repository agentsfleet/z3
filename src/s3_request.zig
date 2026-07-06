const std = @import("std");
const http = std.http;
const Io = std.Io;
const internal = @import("s3_internal.zig");
const signing = @import("s3_signing.zig");
const url = @import("s3_url.zig");
const request_types = @import("s3_request_types.zig");
const S3Client = @import("s3_client.zig").S3Client;

fn containsHeaderName(headers: []const signing.HeaderToSign, lower_name: []const u8) bool {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, lower_name)) return true;
    }
    return false;
}

fn conflictsWithGeneratedHeader(
    method: http.Method,
    body_len: usize,
    params: RequestParams,
    lower_name: []const u8,
) bool {
    if (std.mem.eql(u8, lower_name, "authorization") or std.mem.eql(u8, lower_name, "accept-encoding")) {
        return true;
    }

    if (std.mem.eql(u8, lower_name, "content-type")) {
        return params.content_type != null or (method == .PUT and body_len > 0);
    }

    if (std.mem.eql(u8, lower_name, "range")) {
        return params.range != null;
    }

    if (method == .DELETE) {
        return std.mem.eql(u8, lower_name, "content-length") or std.mem.eql(u8, lower_name, "connection");
    }

    return false;
}

fn makeCanonicalCustomHeader(
    self: *S3Client,
    method: http.Method,
    body_len: usize,
    params: RequestParams,
    headers_to_sign: []const signing.HeaderToSign,
    header: http.Header,
) !http.Header {
    const lower_name = try internal.toLowerAlloc(self.allocator, header.name);
    errdefer self.allocator.free(lower_name);

    if (containsHeaderName(headers_to_sign, lower_name) or conflictsWithGeneratedHeader(method, body_len, params, lower_name)) {
        return error.ConflictingCustomHeader;
    }

    const value_dupe = try self.allocator.dupe(u8, header.value);
    errdefer self.allocator.free(value_dupe);

    return .{
        .name = lower_name,
        .value = value_dupe,
    };
}

fn appendOwnedHeader(self: *S3Client, headers: *std.ArrayListUnmanaged(http.Header), name: []const u8, value: []const u8) !void {
    const name_dupe = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_dupe);

    const value_dupe = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(value_dupe);

    try headers.append(self.allocator, .{
        .name = name_dupe,
        .value = value_dupe,
    });
}

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
        try url.buildUrl(self, b, key, params.query)
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
    const content_hash = if (self.config.unsigned_payload)
        "UNSIGNED-PAYLOAD"
    else if (params.content_hash) |hash|
        hash
    else blk: {
        var content_hash_buf: [64]u8 = undefined;
        internal.sha256Hex(params.body, &content_hash_buf);
        break :blk &content_hash_buf;
    };

    var headers_to_sign = std.ArrayList(signing.HeaderToSign).empty;
    defer headers_to_sign.deinit(self.allocator);
    try headers_to_sign.append(self.allocator, .{ .name = "host", .value = host });
    try headers_to_sign.append(self.allocator, .{ .name = "x-amz-content-sha256", .value = content_hash });
    try headers_to_sign.append(self.allocator, .{ .name = "x-amz-date", .value = date_header });
    if (params.copy_source) |src| {
        try headers_to_sign.append(self.allocator, .{ .name = "x-amz-copy-source", .value = src });
    }
    if (self.config.session_token) |token| {
        try headers_to_sign.append(self.allocator, .{ .name = "x-amz-security-token", .value = token });
    }

    var metadata_sign_names = std.ArrayList([]u8).empty;
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
            var lower_name_moved = false;
            errdefer if (!lower_name_moved) self.allocator.free(lower_name);

            try metadata_sign_names.append(self.allocator, lower_name);
            lower_name_moved = true;

            try headers_to_sign.append(self.allocator, .{ .name = lower_name, .value = item.value });
        }
    }

    var custom_headers = std.ArrayList(http.Header).empty;
    var custom_headers_moved = false;
    defer {
        if (!custom_headers_moved) {
            for (custom_headers.items) |header| {
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
            custom_headers.deinit(self.allocator);
        }
    }
    if (params.options.custom_header) |header_list| {
        for (header_list) |header| {
            const custom_header = try makeCanonicalCustomHeader(self, method, body_len, params, headers_to_sign.items, header);
            var custom_header_moved = false;
            errdefer if (!custom_header_moved) {
                self.allocator.free(custom_header.name);
                self.allocator.free(custom_header.value);
            };

            try headers_to_sign.append(self.allocator, .{ .name = custom_header.name, .value = custom_header.value });
            try custom_headers.append(self.allocator, custom_header);
            custom_header_moved = true;
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
    defer self.allocator.free(auth_header);

    var temp_headers = std.ArrayList(http.Header).empty;
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

    try appendOwnedHeader(self, &temp_headers, "X-Amz-Date", date_header);
    try appendOwnedHeader(self, &temp_headers, "X-Amz-Content-Sha256", content_hash);
    try appendOwnedHeader(self, &temp_headers, "Authorization", auth_header);
    try appendOwnedHeader(self, &temp_headers, "Accept-Encoding", "identity");

    if (params.copy_source) |src| {
        try appendOwnedHeader(self, &temp_headers, "X-Amz-Copy-Source", src);
    }
    if (self.config.session_token) |token| {
        try appendOwnedHeader(self, &temp_headers, "X-Amz-Security-Token", token);
    }

    if (params.metadata) |metadata| {
        for (metadata) |item| {
            const raw_name = try std.fmt.allocPrint(self.allocator, "x-amz-meta-{s}", .{item.name});
            defer self.allocator.free(raw_name);

            const lower_name = try internal.toLowerAlloc(self.allocator, raw_name);
            var lower_name_moved = false;
            errdefer if (!lower_name_moved) self.allocator.free(lower_name);

            const value_dupe = try self.allocator.dupe(u8, item.value);
            var owned = false;
            errdefer if (!owned) {
                self.allocator.free(value_dupe);
            };

            try temp_headers.append(self.allocator, .{ .name = lower_name, .value = value_dupe });
            lower_name_moved = true;
            owned = true;
        }
    }

    if (params.content_type) |content_type| {
        try appendOwnedHeader(self, &temp_headers, "Content-Type", content_type);
    } else if (method == .PUT and body_len > 0) {
        try appendOwnedHeader(self, &temp_headers, "Content-Type", "application/octet-stream");
    }

    if (params.range) |range| {
        const range_fmt = try std.fmt.allocPrint(self.allocator, "bytes={d}-{d}", .{ range.start, range.end });
        defer self.allocator.free(range_fmt);
        try appendOwnedHeader(self, &temp_headers, "Range", range_fmt);
    }

    // Add Content-Length: 0 and Connection: close for DELETE to work around TLS+async Io issue
    if (method == .DELETE) {
        try appendOwnedHeader(self, &temp_headers, "Content-Length", "0");
        try appendOwnedHeader(self, &temp_headers, "Connection", "close");
    }

    // Canonicalize and validate custom headers before signing so SigV4 covers
    // them and the client does not emit conflicting duplicates.
    if (custom_headers.items.len > 0) {
        try temp_headers.appendSlice(self.allocator, custom_headers.items);
        custom_headers.deinit(self.allocator);
        custom_headers_moved = true;
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
        .max_attempts = params.options.max_attempts,
        .initial_retry_time = params.options.initial_retry_time,
    };
}

pub fn executeRequest(self: *S3Client, req: *request_types.UnifiedRequest) !S3Client.Response {
    const uri = std.Uri.parse(req.url) catch return error.InvalidUri;

    if (req.max_attempts <= 0) return error.InvalidMaxAttempts;

    var attempt: usize = 1;
    var http_req: http.Client.Request = while (attempt <= req.max_attempts) : (attempt += 1) {
        const request = self.http_client.request(req.http_method, uri, .{
            .extra_headers = req.headers,
        }) catch {
            if (attempt == req.max_attempts) {
                return error.ConnectionFailed;
            } else {
                var rand_int: [1]u8 = undefined;
                self.http_client.io.random(&rand_int);
                const interval: i64 = if (rand_int[0] % 2 == 0)
                    req.initial_retry_time - rand_int[0]
                else
                    req.initial_retry_time + rand_int[0];
                self.http_client.io.sleep(.fromMilliseconds(@intCast(@abs(interval))), .awake) catch {};
                continue;
            }
        };
        break request;
    } else unreachable;
    defer http_req.deinit();

    if (req.is_bodiless) {
        if (http_req.method == .POST) {
            http_req.sendBodyComplete("") catch return error.SendFailed;
        } else {
            http_req.sendBodiless() catch return error.SendFailed;
            // Extra flush to ensure data is fully sent before waiting for response
            // (workaround for TLS+async Io buffering issue with bodiless requests)
            http_req.connection.?.flush() catch return error.FlushFailed;
        }
    } else {
        std.debug.assert(req.body.len == req.content_length);
        http_req.transfer_encoding = .{ .content_length = req.content_length };
        var body_writer = http_req.sendBody(&.{}) catch return error.SendFailed;
        // if (S3Client.custom_streams.custom_stream_writer) |w| {
        //     var writer_counter = w.init(&body_writer.writer, &.{});
        //     writer_counter.interface.writeAll(req.body) catch return error.WriteFailed;
        // } else {
        //     body_writer.writer.writeAll(req.body) catch return error.WriteFailed;
        // }
        var writer_counter: CountingWriter = .init(drainFn, &body_writer.writer, &.{});
        writer_counter.interface.writeAll(req.body) catch return error.WriteFailed;
        // body_writer.writer.writeAll(req.body) catch return error.WriteFailed;
        body_writer.end() catch return error.WriteFailed;
        http_req.connection.?.flush() catch return error.FlushFailed;
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

    const header_copy = self.allocator.dupe(u8, response.head.bytes) catch return error.CopyResponseHeadFailed;
    var resp_head_copy = http.Client.Response.Head.parse(header_copy) catch return error.ParseResponseHeadFailed;
    var head_iter = resp_head_copy.iterateHeaders();

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
        .http_head = resp_head_copy,
        .body = response_body,
        .allocator = self.allocator,
        .s3_head = try .parse(self.allocator, &head_iter),
    };
}

const ProgressState = struct {
    bytes_written: u64 = 0,
    total_bytes: u64,
};

pub const CountingWriter = struct {
    inner: *std.Io.Writer,
    pos: u64 = 0,
    interface: std.Io.Writer,
    progress_state: ProgressState,

    pub fn init(
        drain_fn: *const fn (
            w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize,
        inner: *std.Io.Writer,
        buffer: []u8,
        total_bytes: u64,
    ) CountingWriter {
        return .{
            .inner = inner,
            .interface = .{
                .vtable = &.{
                    .drain = drain_fn,
                },
                .buffer = buffer,
                .end = 0,
            },
            .progress_state = .{ .total_bytes = total_bytes },
        };
    }

    pub fn logicalPos(self: *const CountingWriter) u64 {
        return self.pos;
    }
};

fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *CountingWriter = @fieldParentPtr("interface", w);
    const n = try self.inner.vtable.drain(self.inner, data, splat);
    self.pos += n;
    self.progress_state.bytes_written += n;
    // std.debug.print("{d}\n", .{self.logicalPos()});
    return n;
}

pub const CountingReader = struct {
    inner: *std.Io.Reader,
    pos: u64 = 0,
    interface: std.Io.Reader,

    pub fn init(inner: *std.Io.Reader, buffer: []u8) CountingReader {
        return .{
            .inner = inner,
            .interface = .{
                .vtable = &.{
                    .stream = streamFn,
                    .discard = discardFn,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CountingReader = @fieldParentPtr("interface", r);
        const n = try self.inner.stream(w, limit);
        self.pos += n;
        return n;
    }

    fn discardFn(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *CountingReader = @fieldParentPtr("interface", r);
        const n = try self.inner.discard(limit);
        self.pos += n;
        return n;
    }

    pub fn logicalPos(self: *const CountingReader) u64 {
        return self.pos - self.interface.bufferedLen();
    }
};

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

    const header_copy = self.allocator.dupe(u8, response.head.bytes) catch return error.CopyResponseHeadFailed;
    errdefer self.allocator.free(header_copy);
    var resp_head_copy = http.Client.Response.Head.parse(header_copy) catch return error.ParseResponseHeadFailed;
    var head_iter = resp_head_copy.iterateHeaders();

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
        .http_head = resp_head_copy,
        .body = response_body,
        .allocator = self.allocator,
        .s3_head = try .parse(self.allocator, &head_iter),
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
            if (std.mem.find(u8, header.value, "SignedHeaders=")) |idx| {
                const tail = header.value[idx..];
                if (std.mem.find(u8, tail, "x-amz-meta-color") != null) {
                    saw_signed = true;
                }
            }
        }
    }

    try std.testing.expect(saw_meta);
    try std.testing.expect(saw_signed);
}

test "prepareRequest signs custom headers" {
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

    const custom_headers = [_]http.Header{
        .{ .name = "X-Amz-Checksum-Mode", .value = "ENABLED" },
    };

    var req = try prepareRequest(&client, .GET, "bucket", "key", .{
        .options = .{ .custom_header = &custom_headers },
    });
    defer req.deinit();

    var saw_custom = false;
    var saw_signed = false;
    for (req.headers) |header| {
        if (std.mem.eql(u8, header.name, "x-amz-checksum-mode") and std.mem.eql(u8, header.value, "ENABLED")) {
            saw_custom = true;
        }
        if (std.mem.eql(u8, header.name, "Authorization")) {
            if (std.mem.find(u8, header.value, "SignedHeaders=")) |idx| {
                const tail = header.value[idx..];
                if (std.mem.find(u8, tail, "x-amz-checksum-mode") != null) {
                    saw_signed = true;
                }
            }
        }
    }

    try std.testing.expect(saw_custom);
    try std.testing.expect(saw_signed);
}

test "prepareRequest signs session token" {
    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .session_token = "token",
            .region = "us-east-1",
            .endpoint = "https://example.com",
        },
    };

    var req = try prepareRequest(&client, .GET, "bucket", "key", .{});
    defer req.deinit();

    var saw_token = false;
    var saw_signed = false;
    for (req.headers) |header| {
        if (std.mem.eql(u8, header.name, "X-Amz-Security-Token") and std.mem.eql(u8, header.value, "token")) {
            saw_token = true;
        }
        if (std.mem.eql(u8, header.name, "Authorization")) {
            if (std.mem.find(u8, header.value, "SignedHeaders=")) |idx| {
                const tail = header.value[idx..];
                if (std.mem.find(u8, tail, "x-amz-security-token") != null) {
                    saw_signed = true;
                }
            }
        }
    }

    try std.testing.expect(saw_token);
    try std.testing.expect(saw_signed);
}

test "prepareRequest rejects conflicting custom headers" {
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

    const custom_headers = [_]http.Header{
        .{ .name = "Authorization", .value = "oops" },
    };

    try std.testing.expectError(error.ConflictingCustomHeader, prepareRequest(&client, .GET, "bucket", "key", .{
        .options = .{ .custom_header = &custom_headers },
    }));
}

fn checkPrepareRequestAllocationFailures(allocator: std.mem.Allocator) !void {
    var client = S3Client{
        .allocator = allocator,
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
    const custom_headers = [_]http.Header{
        .{ .name = "X-Amz-Checksum-Mode", .value = "ENABLED" },
    };

    var req = try prepareRequest(&client, .PUT, "bucket", "key", .{
        .body = "data",
        .copy_source = "/source-bucket/source-key",
        .content_type = "text/plain",
        .metadata = &metadata,
        .range = .{ .start = 1, .end = 2 },
        .options = .{ .custom_header = &custom_headers },
    });
    defer req.deinit();
}

test "prepareRequest cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPrepareRequestAllocationFailures, .{});
}

test "Parse custom S3 header" {
    const response_bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2000\r\nETag: ab3c265c99a353f103ea57cefa0acd7dbfbfce8f6a4b\r\nx-amz-version-id: 26b7e23aaabf5a80db01328e0b4ac735\r\nx-amz-server-side-encryption-customer-key-MD5: 8ddd8be4b179a529afa5f2ffae4b9858\r\n\r\n";
    const head = try http.Client.Response.Head.parse(response_bytes);

    try std.testing.expectEqual(http.Status.ok, head.status);
    try std.testing.expectEqual(head.content_length.?, 2000);

    var header_it = head.iterateHeaders();

    var s3_head: S3Client.S3Head = try .parse(std.testing.allocator, &header_it);
    defer s3_head.deinit();

    try std.testing.expectEqualStrings("ab3c265c99a353f103ea57cefa0acd7dbfbfce8f6a4b", s3_head.etag orelse "");

    try std.testing.expectEqualStrings("26b7e23aaabf5a80db01328e0b4ac735", try s3_head.getAmzValue("version-id") orelse "aaaaaah");
    try std.testing.expectEqualStrings("8ddd8be4b179a529afa5f2ffae4b9858", try s3_head.getAmzValue("x-aMZ-SERVER-SIDE-ENCRYPTION-customer-key-MD5") orelse "aaaaaah");
}
