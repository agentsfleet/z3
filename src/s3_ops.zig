const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const types = @import("types.zig");
const internal = @import("s3_internal.zig");
const request = @import("s3_request.zig");
const S3Client = @import("s3_client.zig").S3Client;

pub fn init(allocator: Allocator, config: S3Client.Config, options: S3Client.InitOptions) !S3Client {
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
pub fn getObject(self: *S3Client, bucket: []const u8, key: []const u8, options: S3Client.GetObjectOptions) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .GET, bucket, key, .{ .range = options.range, .options = options.request });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// GET object from S3 as a streaming response.
pub fn getObjectStream(self: *S3Client, bucket: []const u8, key: []const u8, options: S3Client.GetObjectOptions) S3Client.RequestError!S3Client.ObjectStream {
    const req = try request.prepareRequest(self, .GET, bucket, key, .{ .range = options.range, .options = options.request });
    return request.executeRequestStream(self, req);
}

/// GET object from S3 and stream it directly into a file.
pub fn getFile(
    self: *S3Client,
    bucket: []const u8,
    key: []const u8,
    dest_path: []const u8,
    options: S3Client.GetFileOptions,
) S3Client.GetFileError!S3Client.GetFileResult {
    var stream = try self.getObjectStream(bucket, key, .{});
    defer stream.deinit();

    if (stream.status() != .ok) {
        const reader = try stream.reader();
        const body = try reader.allocRemaining(self.allocator, Io.Limit.limited(options.max_body_size));
        defer self.allocator.free(body);
        var s3_err = xml.parseS3Error(self.allocator, body) catch return error.RequestFailed;
        defer s3_err.deinit();
        std.log.err("S3 error: {s} - {s}", .{ s3_err.code, s3_err.message });
        return error.S3Error;
    }

    const io = self.http_client.io;
    if (options.create_dirs) {
        if (std.fs.path.dirname(dest_path)) |dir_name| {
            try std.Io.Dir.createDirPath(.cwd(), io, dir_name);
        }
    }

    const file_flags: std.Io.File.CreateFlags = .{
        .truncate = true,
        .exclusive = !options.overwrite,
        .permissions = options.file_permissions,
    };

    const file = if (std.Io.Dir.path.isAbsolute(dest_path))
        try std.Io.Dir.createFileAbsolute(io, dest_path, file_flags)
    else
        try std.Io.Dir.createFile(.cwd(), io, dest_path, file_flags);
    defer file.close(io);

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.Writer.init(file, io, &file_buffer);

    const reader = try stream.reader();
    while (true) {
        const n = reader.stream(&file_writer.interface, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
    }
    try file_writer.interface.flush();

    return .{
        .status = stream.status(),
        .bytes_written = file_writer.logicalPos(),
    };
}

/// PUT object to S3
pub fn putObject(self: *S3Client, bucket: []const u8, key: []const u8, body: []const u8, options: S3Client.PutObjectOptions) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .PUT, bucket, key, .{
        .body = body,
        .metadata = options.metadata,
        .content_type = options.content_type,
        .options = options.request,
    });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// PUT object from a file path to S3.
pub fn putFile(
    self: *S3Client,
    bucket: []const u8,
    key: []const u8,
    src_path: []const u8,
    options: S3Client.PutFileOptions,
) !S3Client.Response {
    const io = self.http_client.io;
    const file = if (std.Io.Dir.path.isAbsolute(src_path))
        try std.Io.Dir.openFileAbsolute(io, src_path, .{ .mode = .read_only })
    else
        try std.Io.Dir.openFile(.cwd(), io, src_path, .{ .mode = .read_only });
    defer file.close(io);

    var reader_buffer: [16 * 1024]u8 = undefined;
    var file_reader = std.Io.File.Reader.init(file, io, &reader_buffer);

    const size = file_reader.getSize() catch |err| switch (err) {
        error.Streaming => return error.ContentLengthRequired,
        else => return err,
    };

    var discard_buffer: [1024]u8 = undefined;
    var hash_buffer: [1024]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buffer);
    var hashed = std.Io.Writer.hashed(
        &discarding.writer,
        std.crypto.hash.sha2.Sha256.init(.{}),
        &hash_buffer,
    );
    _ = try file_reader.interface.streamRemaining(&hashed.writer);
    try hashed.writer.flush();

    var digest: [32]u8 = undefined;
    hashed.hasher.final(&digest);
    var content_hash_buf: [64]u8 = undefined;
    internal.bytesToHex(&digest, &content_hash_buf);

    try file_reader.seekTo(0);

    var req = try request.prepareRequest(self, .PUT, bucket, key, .{
        .content_hash = &content_hash_buf,
        .body_len = @intCast(size),
        .content_type = options.content_type,
        .metadata = options.metadata,
        .options = .{ .max_body_size = options.max_response_body_size },
    });
    defer req.deinit();

    return request.executeRequestWithReader(self, &req, &file_reader.interface);
}

/// Initiate a multipart upload
pub fn createMultipartUpload(
    self: *S3Client,
    bucket: []const u8,
    key: []const u8,
    options: S3Client.CreateMultipartUploadOptions,
) S3Client.RequestError!types.CreateMultipartUploadResult {
    var req = try request.prepareRequest(self, .POST, bucket, key, .{
        .query = "uploads=",
        .options = options.request,
        .metadata = options.metadata,
        .content_type = options.content_type,
    });
    defer req.deinit();

    var response = try request.executeRequest(self, &req);
    defer response.deinit();

    if (response.http_head.status != .ok) {
        var s3_err = xml.parseS3Error(self.allocator, response.body) catch |err| {
            std.log.err("failed to parse s3 error: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        defer s3_err.deinit();
        std.log.err("S3 error: {s} - {s}", .{ s3_err.code, s3_err.message });
        return error.S3Error;
    }

    return xml.parseCreateMultipartUpload(self.allocator, response.body);
}

/// Uploading a single part of an initialized multipart upload
pub fn uploadPart(
    self: *S3Client,
    bucket: []const u8,
    key: []const u8,
    body: []const u8,
    upload_id: []const u8,
    part_number: u32,
    options: S3Client.RequestOptions,
) S3Client.RequestError!S3Client.Response {
    const query_string = try std.fmt.allocPrint(self.allocator, "partNumber={d}&uploadId={s}", .{ part_number, upload_id });
    defer self.allocator.free(query_string);

    var req = try request.prepareRequest(self, .PUT, bucket, key, .{
        .body = body,
        .query = query_string,
        .options = options,
    });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// Complete a multipart upload after all parts have been uploaded
pub fn completeMultipartUpload(
    self: *S3Client,
    bucket: []const u8,
    key: []const u8,
    options: S3Client.CompleteMultipartUploadOptions,
) S3Client.RequestError!types.CompleteMultipartUploadResult {
    const query_string = try std.fmt.allocPrint(self.allocator, "uploadId={s}", .{options.upload_id});
    defer self.allocator.free(query_string);

    var body = std.ArrayList(u8).empty;
    defer body.clearAndFree(self.allocator);

    const uploads_sorted = try self.allocator.alloc(S3Client.UploadedPart, options.uploaded_parts.len);
    defer self.allocator.free(uploads_sorted);

    @memmove(uploads_sorted, options.uploaded_parts);

    std.sort.heap(
        S3Client.UploadedPart,
        uploads_sorted,
        {},
        struct {
            fn lessThan(_: void, a: S3Client.UploadedPart, b: S3Client.UploadedPart) bool {
                return a.part_number < b.part_number;
            }
        }.lessThan,
    );

    try body.appendSlice(self.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");

    for (uploads_sorted) |part| {
        const xml_str = try part.buildXmlString(self.allocator);
        defer self.allocator.free(xml_str);
        try body.appendSlice(self.allocator, xml_str);
    }

    try body.appendSlice(self.allocator, "</CompleteMultipartUpload>");

    var req = try request.prepareRequest(self, .POST, bucket, key, .{
        .query = query_string,
        .options = options.request,
        .body = body.items,
        .content_type = "application/xml",
    });
    defer req.deinit();

    var resp = try request.executeRequest(self, &req);
    defer resp.deinit();

    if (resp.http_head.status != .ok) {
        var s3_err = xml.parseS3Error(self.allocator, resp.body) catch |err| {
            std.log.err("failed to parse s3 error: {s}", .{@errorName(err)});
            return error.RequestFailed;
        };
        defer s3_err.deinit();
        std.log.err("S3 error: {s} - {s}", .{ s3_err.code, s3_err.message });
        return error.S3Error;
    }

    return xml.parseCompleteMultipartUpload(self.allocator, resp.body);
}

/// DELETE object from S3
pub fn deleteObject(self: *S3Client, bucket: []const u8, key: []const u8, options: S3Client.RequestOptions) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .DELETE, bucket, key, .{ .options = options });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// HEAD object (get metadata)
pub fn headObject(self: *S3Client, bucket: []const u8, key: []const u8, options: S3Client.RequestOptions) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .HEAD, bucket, key, .{ .options = options });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// List objects in bucket
pub const ListObjectsOptions = struct {
    prefix: ?[]const u8 = null,
    continuation_token: ?[]const u8 = null,
    max_keys: ?u32 = null,
};

pub fn listObjects(self: *S3Client, bucket: []const u8, options: ListObjectsOptions) S3Client.RequestError!types.ListObjectsResult {
    // Build query string with RFC3986 encoding for query values.
    const query = try buildListObjectsQuery(self, options);
    defer self.allocator.free(query);

    var req = try request.prepareRequest(self, .GET, bucket, null, .{ .query = query, .options = .{ .max_body_size = 10 * 1024 * 1024 } });
    defer req.deinit();

    var response = try request.executeRequest(self, &req);
    defer response.deinit();

    if (response.http_head.status != .ok) {
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
pub fn createBucket(self: *S3Client, bucket: []const u8, options: S3Client.RequestOptions) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .PUT, bucket, null, .{ .options = options });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// Delete a bucket (must be empty)
pub fn deleteBucket(self: *S3Client, bucket: []const u8) S3Client.RequestError!S3Client.Response {
    var req = try request.prepareRequest(self, .DELETE, bucket, null, .{ .options = .{ .max_body_size = 64 * 1024 } });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

pub fn copyObject(self: *S3Client, src_bucket: []const u8, src_key: []const u8, dst_bucket: []const u8, dst_key: []const u8) S3Client.RequestError!S3Client.Response {
    const copy_source = try buildCopySource(self, src_bucket, src_key);
    defer self.allocator.free(copy_source);

    var req = try request.prepareRequest(self, .PUT, dst_bucket, dst_key, .{ .copy_source = copy_source, .options = .{ .max_body_size = 64 * 1024 } });
    defer req.deinit();

    return request.executeRequest(self, &req);
}

/// List all buckets
pub fn listBuckets(self: *S3Client) S3Client.RequestError!types.ListBucketsResult {
    var req = try request.prepareRequest(self, .GET, null, null, .{ .options = .{ .max_body_size = 1024 * 1024 } });
    defer req.deinit();

    var response = try request.executeRequest(self, &req);
    defer response.deinit();

    if (response.http_head.status != .ok) {
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

const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

fn buildListObjectsQuery(self: *S3Client, options: ListObjectsOptions) ![]u8 {
    var params = std.ArrayListUnmanaged(QueryParam){};
    errdefer {
        for (params.items) |item| {
            self.allocator.free(item.key);
            self.allocator.free(item.value);
        }
        params.deinit(self.allocator);
    }

    try params.append(self.allocator, .{
        .key = try internal.encodeQueryValue(self.allocator, "list-type"),
        .value = try internal.encodeQueryValue(self.allocator, "2"),
    });

    if (options.prefix) |p| {
        try params.append(self.allocator, .{
            .key = try internal.encodeQueryValue(self.allocator, "prefix"),
            .value = try internal.encodeQueryValue(self.allocator, p),
        });
    }

    if (options.continuation_token) |token| {
        try params.append(self.allocator, .{
            .key = try internal.encodeQueryValue(self.allocator, "continuation-token"),
            .value = try internal.encodeQueryValue(self.allocator, token),
        });
    }

    if (options.max_keys) |max| {
        var buf: [20]u8 = undefined;
        const max_str = std.fmt.bufPrint(&buf, "{d}", .{max}) catch return error.RequestTooLong;
        try params.append(self.allocator, .{
            .key = try internal.encodeQueryValue(self.allocator, "max-keys"),
            .value = try internal.encodeQueryValue(self.allocator, max_str),
        });
    }

    std.sort.heap(QueryParam, params.items, {}, struct {
        fn lessThan(_: void, a: QueryParam, b: QueryParam) bool {
            if (std.mem.eql(u8, a.key, b.key)) {
                return std.mem.lessThan(u8, a.value, b.value);
            }
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);

    var query = std.ArrayListUnmanaged(u8){};
    errdefer query.deinit(self.allocator);

    for (params.items, 0..) |item, i| {
        if (i > 0) try query.append(self.allocator, '&');
        try query.appendSlice(self.allocator, item.key);
        try query.append(self.allocator, '=');
        try query.appendSlice(self.allocator, item.value);
    }

    const out = try query.toOwnedSlice(self.allocator);
    for (params.items) |item| {
        self.allocator.free(item.key);
        self.allocator.free(item.value);
    }
    params.deinit(self.allocator);
    return out;
}

fn buildCopySource(self: *S3Client, src_bucket: []const u8, src_key: []const u8) ![]u8 {
    const encoded_key = try internal.encodePath(self.allocator, src_key);
    defer self.allocator.free(encoded_key);
    return std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ src_bucket, encoded_key });
}

test "buildListObjectsQuery supports prefix and continuation token" {
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

    const query = try buildListObjectsQuery(&client, .{
        .prefix = "a/b c",
        .continuation_token = "token+1",
        .max_keys = 50,
    });
    defer std.testing.allocator.free(query);
    try std.testing.expectEqualStrings("continuation-token=token%2B1&list-type=2&max-keys=50&prefix=a%2Fb%20c", query);
}
