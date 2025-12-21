//! Async S3 Client for Zig 0.16+
//! Built on std.http.Client with Io interface for async operations
//! Supports AWS S3, Cloudflare R2, MinIO, and other S3-compatible services
const std = @import("std");
const crypto = std.crypto;
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const types = @import("types.zig");

pub const S3Client = struct {
    allocator: Allocator,
    http_client: *http.Client,
    owns_http_client: bool,
    config: Config,

    pub const Config = struct {
        access_key_id: []const u8,
        secret_access_key: []const u8,
        region: []const u8 = "us-east-1",
        endpoint: ?[]const u8 = null,
    };

    pub const InitOptions = struct {
        http_client: ?*http.Client = null,
        io: ?Io = null,
    };

    pub const RequestOptions = struct {
        max_body_size: usize = 100 * 1024 * 1024,
    };

    pub const Response = struct {
        status: http.Status,
        body: []u8,
        allocator: Allocator,

        pub fn deinit(self: *Response) void {
            if (self.body.len > 0) {
                self.allocator.free(self.body);
            }
        }
    };

    pub const Error = error{
        RequestFailed,
        S3Error,
        IoRequired,
        KeyTooLong,
    };


    pub fn init(allocator: Allocator, config: Config, options: InitOptions) !S3Client {
        if (options.http_client) |client| {
            return .{
                .allocator = allocator,
                .http_client = client,
                .owns_http_client = false,
                .config = config,
            };
        }

        const client = try allocator.create(http.Client);
        client.* = .{ .allocator = allocator, .io = options.io orelse return error.IoRequired };
        return .{
            .allocator = allocator,
            .http_client = client,
            .owns_http_client = true,
            .config = config,
        };
    }

    pub fn deinit(self: *S3Client) void {
        if (self.owns_http_client) {
            self.http_client.deinit();
            self.allocator.destroy(self.http_client);
        }
    }

    /// GET object from S3
    pub fn getObject(self: *S3Client, bucket: []const u8, key: []const u8) !Response {
        return self.getObjectWithOptions(bucket, key, .{});
    }

    pub fn getObjectWithOptions(self: *S3Client, bucket: []const u8, key: []const u8, options: RequestOptions) !Response {
        var req = try self.prepareRequest(.GET, bucket, key, .{ .options = options });
        defer req.deinit();

        return self.executeRequest(&req);
    }

    /// PUT object to S3
    pub fn putObject(self: *S3Client, bucket: []const u8, key: []const u8, body: []const u8) !Response {
        return self.putObjectWithOptions(bucket, key, body, .{});
    }

    pub fn putObjectWithOptions(self: *S3Client, bucket: []const u8, key: []const u8, body: []const u8, options: RequestOptions) !Response {
        var req = try self.prepareRequest(.PUT, bucket, key, .{ .body = body, .options = options });
        defer req.deinit();

        return self.executeRequest(&req);
    }

    /// DELETE object from S3
    pub fn deleteObject(self: *S3Client, bucket: []const u8, key: []const u8) !Response {
        return self.deleteObjectWithOptions(bucket, key, .{});
    }

    pub fn deleteObjectWithOptions(self: *S3Client, bucket: []const u8, key: []const u8, options: RequestOptions) !Response {
        var req = try self.prepareRequest(.DELETE, bucket, key, .{ .options = options });
        defer req.deinit();

        return self.executeRequest(&req);
    }
    /// HEAD object (get metadata)
    pub fn headObject(self: *S3Client, bucket: []const u8, key: []const u8) !Response {
        var req = try self.prepareRequest(.HEAD, bucket, key, .{});
        defer req.deinit();

        return self.executeRequest(&req);
    }

    /// List objects in bucket
    pub fn listObjects(self: *S3Client, bucket: []const u8, prefix: ?[]const u8) !types.ListObjectsResult {
        // Build query string
        const query = if (prefix) |p|
            try std.fmt.allocPrint(self.allocator, "list-type=2&prefix={s}", .{p})
        else
            try self.allocator.dupe(u8, "list-type=2");
        defer self.allocator.free(query);

        var req = try self.prepareRequest(.GET, bucket, null, .{ .query = query, .options = .{ .max_body_size = 10 * 1024 * 1024 } });
        defer req.deinit();

        var response = try self.executeRequest(&req);
        defer response.deinit();

        if (response.status != .ok) {
            var s3_err = xml.parseS3Error(self.allocator, response.body) catch |err| {
                std.log.err("failed to parse s3 error: {s}", .{@errorName(err)});
                return error.RequestFailed;
            };
            defer s3_err.deinit();
            std.log.err("S3 error: {s} - {s}", .{ s3_err.code, s3_err.message });
            return error.S3Error;
        }

        return xml.parseListObjects(self.allocator, response.body);
    }

    /// Create a new bucket
    pub fn createBucket(self: *S3Client, bucket: []const u8) !Response {
        var req = try self.prepareRequest(.PUT, bucket, null, .{ .options = .{ .max_body_size = 64 * 1024 } });
        defer req.deinit();

        return self.executeRequest(&req);
    }

    /// Delete a bucket (must be empty)
    pub fn deleteBucket(self: *S3Client, bucket: []const u8) !Response {
        var req = try self.prepareRequest(.DELETE, bucket, null, .{ .options = .{ .max_body_size = 64 * 1024 } });
        defer req.deinit();

        return self.executeRequest(&req);
    }
    pub fn copyObject(self: *S3Client, src_bucket: []const u8, src_key: []const u8, dst_bucket: []const u8, dst_key: []const u8) !Response {
        const copy_source = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ src_bucket, src_key });
        defer self.allocator.free(copy_source);

        var req = try self.prepareRequest(.PUT, dst_bucket, dst_key, .{ .copy_source = copy_source, .options = .{ .max_body_size = 64 * 1024 } });
        defer req.deinit();

        return self.executeRequest(&req);
    }

    /// List all buckets
    pub fn listBuckets(self: *S3Client) !types.ListBucketsResult {
        var req = try self.prepareRequest(.GET, null, null, .{ .options = .{ .max_body_size = 1024 * 1024 } });
        defer req.deinit();

        var response = try self.executeRequest(&req);
        defer response.deinit();

        if (response.status != .ok) {
            var s3_err = xml.parseS3Error(self.allocator, response.body) catch |err| {
                std.log.err("failed to parse s3 error: {s}", .{@errorName(err)});
                return error.RequestFailed;
            };
            defer s3_err.deinit();
            std.log.err("S3 error: {s} - {s}", .{ s3_err.code, s3_err.message });
            return error.S3Error;
        }

        return xml.parseListBuckets(self.allocator, response.body);
    }

    // ============= Internal helpers =============

    const UnifiedRequest = struct {
        allocator: Allocator,
        http_method: http.Method,
        url: []u8,
        headers: []http.Header,
        body: []const u8,
        max_body_size: usize,
        is_bodiless: bool,

        fn deinit(self: *UnifiedRequest) void {
            self.allocator.free(self.url);
            for (self.headers) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            self.allocator.free(self.headers);
        }
    };

    const RequestParams = struct {
        query: ?[]const u8 = null,
        body: []const u8 = "",
        copy_source: ?[]const u8 = null,
        options: RequestOptions = .{

        },
    };

    fn prepareRequest(
        self: *S3Client,
        method: http.Method,
        bucket: ?[]const u8,
        key: ?[]const u8,
        params: RequestParams,
    ) !UnifiedRequest {
        const url = if (bucket) |b|
            if (key) |k|
                try self.buildUrl(b, k)
            else
                try self.buildBucketUrl(b, params.query)
        else
            try self.buildServiceUrl();
        errdefer self.allocator.free(url);

        const host = if (bucket) |b| try self.getHost(b) else try self.getServiceHost();
        defer self.allocator.free(host);

        const timestamp = getUnixTimestamp();
        var date_header_buf: [16]u8 = undefined;
        formatAmzDate(timestamp, &date_header_buf);
        const date_header = &date_header_buf;

        var content_hash_buf: [64]u8 = undefined;
        sha256Hex(params.body, &content_hash_buf);
        const content_hash = &content_hash_buf;

        const auth_header = try self.signRequest(
            @tagName(method),
            bucket,
            key,
            params.query,
            host,
            date_header,
            content_hash,
            params.copy_source,
        );
        errdefer self.allocator.free(auth_header);

        var temp_headers = std.ArrayListUnmanaged(http.Header){};
        defer temp_headers.deinit(self.allocator);

        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Date"), .value = try self.allocator.dupe(u8, date_header) });
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Content-Sha256"), .value = try self.allocator.dupe(u8, content_hash) });
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Authorization"), .value = auth_header });
        try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Accept-Encoding"), .value = try self.allocator.dupe(u8, "identity") });

        if (params.copy_source) |src| {
            try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "X-Amz-Copy-Source"), .value = try self.allocator.dupe(u8, src) });
        }

        if (method == .PUT and params.body.len > 0) {
            try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Content-Type"), .value = try self.allocator.dupe(u8, "application/octet-stream") });
        }

        // Add Content-Length: 0 and Connection: close for DELETE to work around TLS+async Io issue
        if (method == .DELETE) {
            try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Content-Length"), .value = try self.allocator.dupe(u8, "0") });
            try temp_headers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, "Connection"), .value = try self.allocator.dupe(u8, "close") });
        }

        const owned_headers = try temp_headers.toOwnedSlice(self.allocator);

        return UnifiedRequest{
            .allocator = self.allocator,
            .http_method = method,
            .url = url,
            .headers = owned_headers,
            .body = params.body,
            .max_body_size = params.options.max_body_size,
            .is_bodiless = params.body.len == 0 and method != .PUT and params.copy_source == null,
        };
    }

    fn executeRequest(self: *S3Client, req: *UnifiedRequest) !Response {
        const uri = std.Uri.parse(req.url) catch return error.InvalidUri;

        var http_req = self.http_client.request(req.http_method, uri, .{
            .extra_headers = req.headers,
        }) catch return error.ConnectionFailed;
        defer http_req.deinit();

        if (req.is_bodiless) {
            http_req.sendBodiless() catch return error.SendFailed;
            // Extra flush to ensure data is fully sent before waiting for response
            // (workaround for TLS+async Io buffering issue with bodiless requests)
            http_req.connection.?.flush() catch return error.FlushFailed;
        } else {
            http_req.transfer_encoding = .{ .content_length = req.body.len };
            var body_writer = http_req.sendBody(&.{}) catch return error.SendFailed;
            body_writer.writer.writeAll(req.body) catch return error.WriteFailed;
            body_writer.end() catch return error.WriteFailed;
            http_req.connection.?.flush() catch return error.FlushFailed;
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = http_req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

        const response_body: []u8 = if (response.head.status == .no_content or req.http_method == .HEAD or req.http_method == .DELETE)
            ""
        else blk: {
            var transfer_buffer: [64]u8 = undefined;
            var decompress: http.Decompress = undefined;
            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
            break :blk reader.allocRemaining(self.allocator, Io.Limit.limited(req.max_body_size)) catch return error.ReadFailed;
        };

        return Response{
            .status = response.head.status,
            .body = response_body,
            .allocator = self.allocator,
        };
    }

    fn signRequest(
        self: *S3Client,
        method: []const u8,
        bucket: ?[]const u8,
        key: ?[]const u8,
        query: ?[]const u8,
        host: []const u8,
        amz_date: []const u8,
        content_hash: []const u8,
        copy_source: ?[]const u8,
    ) ![]u8 {
        const date_stamp = amz_date[0..8];

        var uri_buf: [2048]u8 = undefined;
        const canonical_uri = if (bucket) |b|
            if (key) |k|
                if (self.config.endpoint != null)
                    try std.fmt.bufPrint(&uri_buf, "/{s}/{s}", .{ b, k })
                else
                    try std.fmt.bufPrint(&uri_buf, "/{s}", .{k})
            else if (self.config.endpoint != null)
                try std.fmt.bufPrint(&uri_buf, "/{s}", .{b})
            else
                "/"
        else
            "/";

        var headers_buf: [1024]u8 = undefined;
        const canonical_headers: []const u8 = if (copy_source) |src| blk: {
            const written = std.fmt.bufPrint(&headers_buf, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-copy-source:{s}\nx-amz-date:{s}", .{ host, content_hash, src, amz_date }) catch break :blk "";
            break :blk written;
        } else blk: {
            const written = std.fmt.bufPrint(&headers_buf, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}", .{ host, content_hash, amz_date }) catch break :blk "";
            break :blk written;
        };
        const signed_headers = if (copy_source != null)
            "host;x-amz-content-sha256;x-amz-copy-source;x-amz-date"
        else
            "host;x-amz-content-sha256;x-amz-date";

        var canonical_buf: [4096]u8 = undefined;
        const canonical_request = std.fmt.bufPrint(&canonical_buf, "{s}\n{s}\n{s}\n{s}\n\n{s}\n{s}", .{method, canonical_uri, query orelse "", canonical_headers, signed_headers, content_hash,}) catch return error.RequestTooLong;

        var canonical_hash_buf: [64]u8 = undefined;
        sha256Hex(canonical_request, &canonical_hash_buf);
        const canonical_hash = &canonical_hash_buf;

        var sts_buf: [512]u8 = undefined;
        const string_to_sign = std.fmt.bufPrint(&sts_buf, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/s3/aws4_request\n{s}", .{ amz_date, date_stamp, self.config.region, canonical_hash }) catch return error.StringToSignTooLong;

        const sig_hex = try self.computeSignature(date_stamp, string_to_sign);

        return std.fmt.allocPrint(self.allocator, "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/s3/aws4_request, SignedHeaders={s}, Signature={s}", .{ self.config.access_key_id, date_stamp, self.config.region, signed_headers, &sig_hex });
    }

    fn buildUrl(self: *S3Client, bucket: []const u8, key: []const u8) ![]u8 {
        if (self.config.endpoint) |endpoint| {
            if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
                const clean_endpoint = std.mem.trimRight(u8, endpoint, "/");
                return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ clean_endpoint, bucket, key });
            } else {
                return std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}", .{ endpoint, bucket, key });
            }
        }
        return std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com/{s}", .{ bucket, self.config.region, key });
    }

    fn buildBucketUrl(self: *S3Client, bucket: []const u8, query: ?[]const u8) ![]u8 {
        const query_part = if (query) |q| try std.fmt.allocPrint(self.allocator, "?{s}", .{q}) else "";
        defer if (query != null) self.allocator.free(query_part);

        if (self.config.endpoint) |endpoint| {
            if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
                const clean_endpoint = std.mem.trimRight(u8, endpoint, "/");
                return std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ clean_endpoint, bucket, query_part });
            } else {
                return std.fmt.allocPrint(self.allocator, "https://{s}/{s}{s}", .{ endpoint, bucket, query_part });
            }
        }
        return std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com{s}", .{ bucket, self.config.region, query_part });
    }

    fn buildServiceUrl(self: *S3Client) ![]u8 {
        if (self.config.endpoint) |endpoint| {
            if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
                return self.allocator.dupe(u8, std.mem.trimRight(u8, endpoint, "/"));
            } else {
                return std.fmt.allocPrint(self.allocator, "https://{s}", .{endpoint});
            }
        }
        return std.fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
    }

    fn getHost(self: *S3Client, bucket: []const u8) ![]u8 {
        if (self.config.endpoint) |endpoint| {
            var host = endpoint;
            if (std.mem.startsWith(u8, host, "https://")) {
                host = host[8..];
            } else if (std.mem.startsWith(u8, host, "http://")) {
                host = host[7..];
            }
            host = std.mem.trimRight(u8, host, "/");
            return self.allocator.dupe(u8, host);
        }
        return std.fmt.allocPrint(self.allocator, "{s}.s3.{s}.amazonaws.com", .{ bucket, self.config.region });
    }

    fn getServiceHost(self: *S3Client) ![]u8 {
        if (self.config.endpoint) |endpoint| {
            var host = endpoint;
            if (std.mem.startsWith(u8, host, "https://")) {
                host = host[8..];
            } else if (std.mem.startsWith(u8, host, "http://")) {
                host = host[7..];
            }
            return self.allocator.dupe(u8, std.mem.trimRight(u8, host, "/"));
        }
        return std.fmt.allocPrint(self.allocator, "s3.{s}.amazonaws.com", .{self.config.region});
    }

    fn getUnixTimestamp() i64 {
        var tv: std.posix.timeval = undefined;
        std.posix.gettimeofday(&tv, null);
        return tv.sec;
    }

    fn formatAmzDate(timestamp: i64, buf: *[16]u8) void {
        const epoch_seconds: u64 = @intCast(timestamp);
        const epoch_day = epoch_seconds / 86400;
        const day_seconds = epoch_seconds % 86400;

        var year: u32 = 1970;
        var remaining_days: u64 = epoch_day;

        while (true) {
            const days_in_year: u32 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }

        const month_days = if (isLeapYear(year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u32 = 1;
        for (month_days) |days| {
            if (remaining_days < days) break;
            remaining_days -= days;
            month += 1;
        }
        const day: u32 = @intCast(remaining_days + 1);

        const hour: u32 = @intCast(day_seconds / 3600);
        const minute: u32 = @intCast(@mod(day_seconds, 3600) / 60);
        const second: u32 = @intCast(day_seconds % 60);

        _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            year, month, day, hour, minute, second,
        }) catch unreachable;
    }

    fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    fn sha256Hex(data: []const u8, out: *[64]u8) void {
        var hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        const charset = "0123456789abcdef";
        for (hash, 0..) |byte, i| {
            out[i * 2] = charset[byte >> 4];
            out[i * 2 + 1] = charset[byte & 0x0f];
        }
    }

    fn computeSignature(self: *S3Client, date_stamp: []const u8, string_to_sign: []const u8) ![64]u8 {
        var key_buf: [256]u8 = undefined;
        const key_str = std.fmt.bufPrint(&key_buf, "AWS4{s}", .{self.config.secret_access_key}) catch return error.KeyTooLong;

        var k_date: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_stamp, key_str);

        var k_region: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&k_region, self.config.region, &k_date);

        var k_service: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&k_service, "s3", &k_region);

        var k_signing: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&k_signing, "aws4_request", &k_service);

        var signature: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign, &k_signing);

        var sig_hex: [64]u8 = undefined;
        const charset = "0123456789abcdef";
        for (signature, 0..) |byte, i| {
            sig_hex[i * 2] = charset[byte >> 4];
            sig_hex[i * 2 + 1] = charset[byte & 0x0f];
        }
        return sig_hex;
    }
};
