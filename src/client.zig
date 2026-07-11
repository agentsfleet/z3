//! Async S3 Client for Zig 0.16+
//! Built on std.http.Client with Io interface for async operations
//! Supports AWS S3, Cloudflare R2, MinIO, and other S3-compatible services
const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const request_types = @import("http/request_types.zig");
const request = @import("http/request.zig");
const sts = @import("auth/sts.zig");
const root = @import("root");

pub const S3Client = @This();

pub const Config = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
    region: []const u8 = "us-east-1",
    endpoint: ?[]const u8 = null,
    /// Set S3 request style to virtual host style. Otherwise, use the legacy
    /// path style request.
    ///
    /// See https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html
    /// for more information.
    virtual_host_style: bool = false,
    unsigned_payload: bool = false,

    pub fn fromEnvMap(env_map: *const std.process.Environ.Map) error{MissingAwsCredentials}!Config {
        const access_key_id = env_map.get("AWS_ACCESS_KEY_ID") orelse return error.MissingAwsCredentials;
        const secret_access_key = env_map.get("AWS_SECRET_ACCESS_KEY") orelse return error.MissingAwsCredentials;

        return .{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .session_token = env_map.get("AWS_SESSION_TOKEN"),
            .region = env_map.get("AWS_REGION") orelse env_map.get("AWS_DEFAULT_REGION") orelse "us-east-1",
        };
    }

    pub fn fromStsCredentials(credentials: *const sts.Credentials, region: []const u8) Config {
        return .{
            .access_key_id = credentials.access_key_id,
            .secret_access_key = credentials.secret_access_key,
            .session_token = credentials.session_token,
            .region = region,
        };
    }
};

pub const InitOptions = struct {
    http_client: ?*http.Client = null,
    io: ?Io = null,
};

pub const RequestOptions = struct {
    max_body_size: usize = 100 * 1024 * 1024,
    /// Max attempts to retry an unseccessful request
    max_attempts: usize = 3,
    /// Timeout to sleep in milliseconds before retrying to execute the request
    initial_retry_time: i64 = 100,
    /// Custom headers which are appended to the request
    custom_header: ?[]const http.Header = null,
    /// Struct for tracking the progress of a request with body byte transfer.
    /// Has to be a pointer so it can be passed to another thread or run async while
    /// the request is processed.
    ///
    /// If this is `null`, the progress won't/can't get tracked at all.
    req_progress: ?*request.ProgressState = null,
    /// Customizable function for write stream of http requests. This can be used e.g.
    /// for tracking the byte stream etc.
    ///
    /// The functions arguments can't be customized since the function is passed to
    /// the `std.Io.Writer.Vtable` which expects this format.
    ///
    /// To transfer the byte data, `inner.vtable.drain()` has to be called. An example
    /// implementation looks like the following:
    ///
    /// ```zig
    /// fn drainFnCustom(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    ///     // These two lines are necessary to transfer the bytes correctly
    ///     const self: *RequestWriter = @fieldParentPtr("interface", w);
    ///     const n = try self.inner.vtable.drain(self.inner, data, splat);
    ///     // write the streamed bytes to the `ProgressState` struct
    ///     if (self.progress_state) |ps| {
    ///         _ = ps.bytes_written.fetchAdd(n, .monotonic);
    ///     }
    ///     return n;
    /// }
    /// ```
    req_drain_fn: ?*const fn (w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize = null,
    /// Customizable function for read stream of http requests. This can be used e.g.
    /// for tracking the byte stream etc.
    ///
    /// The functions arguments can't be customized since the function is passed to
    /// the `std.Io.Reader.Vtable` which expects this format.
    ///
    /// To transfer the byte data, `inner.stream()` has to be called. An example
    /// implementation looks like the following:
    ///
    /// ```zig
    /// fn defaultStreamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    ///     const self: *RequestReader = @fieldParentPtr("interface", r);
    ///     const n = try self.inner.stream(w, limit);
    ///     // write the streamed bytes to the `ProgressState` struct
    ///     if (self.progress_state) |ps| {
    ///         _ = ps.bytes_written.fetchAdd(n, .monotonic);
    ///     }
    ///     return n;
    /// }
    /// ```
    req_stream_fn: ?*const fn (r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize = null,
    /// Customizable function for read discard of http requests. This can be used e.g.
    /// for tracking the byte stream etc.
    ///
    /// The functions arguments can't be customized since the function is passed to
    /// the `std.Io.Writer.Vtable` which expects this format.
    ///
    /// To transfer the byte data, `inner.discard()` has to be called. An example
    /// implementation looks like the following:
    ///
    /// ```zig
    /// fn defaultDiscardFn(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    ///     const self: *RequestReader = @fieldParentPtr("interface", r);
    ///     const n = try self.inner.discard(limit);
    ///     // write the streamed bytes to the `ProgressState` struct
    ///     if (self.progress_state) |ps| {
    ///         _ = ps.bytes_written.fetchAdd(n, .monotonic);
    ///     }
    ///     return n;
    /// }
    /// ```
    req_discard_fn: ?*const fn (r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize = null,
};

pub const Metadata = struct {
    name: []const u8,
    value: []const u8,
};

pub const PutObjectOptions = struct {
    request: RequestOptions = .{},
    metadata: ?[]const Metadata = null,
    content_type: ?[]const u8 = null,
};

pub const CreateMultipartUploadOptions = struct {
    request: RequestOptions = .{},
    metadata: ?[]const Metadata = null,
    content_type: ?[]const u8 = null,
};

/// Metadata of a completed part from a `MultipartUpload`.
/// An array of all such parts is necessary to complete the whole multipart
/// upload
pub const UploadedPart = struct {
    etag: []const u8,
    part_number: u32,
    crc32_checksum: ?[]const u8 = null,
    crc32c_checksum: ?[]const u8 = null,
    crc64nvme_checksum: ?[]const u8 = null,
    sha1_checksum: ?[]const u8 = null,
    sha256_checksum: ?[]const u8 = null,

    /// Build XML string needed to complete the multipart upload
    pub fn buildXmlString(self: UploadedPart, allocator: std.mem.Allocator) ![]const u8 {
        // TODO: add checks for used checksums and add them to XML string once
        // enhanced checksum handling is implemented
        return std.fmt.allocPrint(
            allocator,
            "<Part><ETag>{s}</ETag><PartNumber>{d}</PartNumber></Part>",
            .{
                self.etag,
                self.part_number,
            },
        );
    }
};

pub const CompleteMultipartUploadOptions = struct {
    request: RequestOptions = .{},
    upload_id: []const u8,
    uploaded_parts: []UploadedPart,
};

/// Options that can be passed to a `Get-Object` request.
pub const GetObjectOptions = struct {
    request: RequestOptions = .{},
    range: ?ContentRange = null,
};

/// Define a range of bytes to perform an `Object` action on
///
/// In contrast to regular byte slices, the end value of the content
/// range for an http request is *inclusive*
pub const ContentRange = struct {
    start: usize,
    end: usize,
};

pub const GetFileOptions = struct {
    max_body_size: usize = 100 * 1024 * 1024,
    overwrite: bool = true,
    create_dirs: bool = false,
    file_permissions: std.Io.File.Permissions = .default_file,
};

pub const GetFileResult = struct {
    status: http.Status,
    bytes_written: u64,
};

pub const PutFileOptions = struct {
    content_type: ?[]const u8 = "application/octet-stream",
    max_response_body_size: usize = 64 * 1024,
    metadata: ?[]const Metadata = null,
};

pub const Response = struct {
    /// Standard http header parsed by the `std.http.Client.receiveHead()` function
    http_head: http.Client.Response.Head,
    /// S3/Aws specific header
    s3_head: S3Head,
    body: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.http_head.bytes);
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
        self.s3_head.deinit();
    }
};

pub const Error = error{
    RequestFailed,
    S3Error,
    IoRequired,
    KeyTooLong,
    ContentLengthRequired,
    BodyLengthMismatch,
};

pub const RequestError = Error || Allocator.Error || error{
    ConflictingCustomHeader,
    InvalidMaxAttempts,
    InvalidUri,
    ConnectionFailed,
    SendFailed,
    FlushFailed,
    ReceiveFailed,
    ReadFailed,
    WriteFailed,
    RequestTooLong,
    StringToSignTooLong,
    CopyResponseHeadFailed,
    ParseResponseHeadFailed,
};

pub const ObjectStream = struct {
    allocator: Allocator,
    request: *http.Client.Request,
    response: http.Client.Response,
    request_data: request_types.UnifiedRequest,
    redirect_buffer: [8 * 1024]u8 = undefined,
    transfer_buffer: [64]u8 = undefined,
    decompress: http.Decompress = undefined,
    decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined,
    reader_started: bool = false,
    request_reader: request.RequestReader,

    pub const Error = error{
        ReaderAlreadyRequested,
    };

    pub fn status(self: *const ObjectStream) http.Status {
        return self.response.head.status;
    }

    pub fn reader(self: *ObjectStream) ObjectStream.Error!*Io.Reader {
        if (self.reader_started) return error.ReaderAlreadyRequested;
        self.reader_started = true;
        const response_reader = self.response.readerDecompressing(
            &self.transfer_buffer,
            &self.decompress,
            &self.decompress_buffer,
        );
        self.request_reader = .init(
            self.request_data.req_stream_fn,
            self.request_data.req_discard_fn,
            response_reader,
            &.{},
            self.request_data.req_progress,
        );
        return &self.request_reader.interface;
    }

    pub fn deinit(self: *ObjectStream) void {
        self.request.deinit();
        self.allocator.destroy(self.request);
        self.request_data.deinit();
    }
};

/// Struct holding S3/AWS specific header
pub const S3Head = struct {
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    x_amz_header: std.hash_map.StringHashMap([]const u8),
    allocator: Allocator,

    /// Parse the header key-value pairs from the iterator into the `S3Head` struct.
    ///
    /// All AWS header starting with `x-amz-` are collected into a hash map, while
    /// other AWS specific header with regular syntax ("Etag", "Last-Modified" etc.)
    /// are stored in named fields.
    pub fn parse(allocator: Allocator, head_iter: *http.HeaderIterator) !S3Head {
        var s3_head: S3Head = .{
            .allocator = allocator,
            .x_amz_header = .init(allocator),
        };
        errdefer s3_head.deinit();

        while (head_iter.next()) |header| {
            if (std.ascii.startsWithIgnoreCase(header.name, "x-amz")) {
                const amz_key = try std.ascii.allocLowerString(allocator, header.name);
                try s3_head.x_amz_header.put(amz_key, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                s3_head.etag = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                s3_head.last_modified = header.value;
            }
        }

        return s3_head;
    }

    /// Try to get a specified AWS header (those starting with `x-amz-`), otherwise
    /// return `null`.
    ///
    /// Its possible to use the full header key or only the part trailing the `x-amz-`
    /// substring. Headers are checked case-insesitive.
    ///
    /// I.e. for getting the value of the `x-amz-version-id` header both calls
    /// are possible: `getAmzValue("x-amz-version-id")` or `getAmzValue("version-id")`
    pub fn getAmzValue(self: *S3Head, key: []const u8) !?[]const u8 {
        const amz_key = if (std.ascii.startsWithIgnoreCase(key, "x-amz-"))
            try std.ascii.allocLowerString(self.allocator, key)
        else blk: {
            const low_key = try std.ascii.allocLowerString(self.allocator, key);
            defer self.allocator.free(low_key);
            const low_str = try std.fmt.allocPrint(self.allocator, "x-amz-{s}", .{low_key});
            break :blk low_str;
        };
        defer self.allocator.free(amz_key);

        return self.x_amz_header.get(amz_key);
    }

    pub fn deinit(self: *S3Head) void {
        if (self.x_amz_header.count() > 0) {
            var it = self.x_amz_header.iterator();
            while (it.next()) |v| {
                self.allocator.free(v.key_ptr.*);
            }
            self.x_amz_header.deinit();
        }
    }
};

pub const init = ops.init;
pub const deinit = ops.deinit;
pub const getObject = ops.getObject;
pub const getObjectStream = ops.getObjectStream;
pub const getFile = ops.getFile;
pub const putObject = ops.putObject;
pub const putFile = ops.putFile;
pub const deleteObject = ops.deleteObject;
pub const headObject = ops.headObject;
pub const ListObjectsOptions = ops.ListObjectsOptions;
pub const listObjects = ops.listObjects;
pub const createBucket = ops.createBucket;
pub const deleteBucket = ops.deleteBucket;
pub const headBucket = ops.headBucket;
pub const copyObject = ops.copyObject;
pub const listBuckets = ops.listBuckets;
pub const createMultipartUpload = ops.createMultipartUpload;
pub const uploadPart = ops.uploadPart;
pub const completeMultipartUpload = ops.completeMultipartUpload;

pub const GetFileError =
    @typeInfo(@typeInfo(@TypeOf(getObjectStream)).@"fn".return_type.?).error_union.error_set ||
    Error ||
    ObjectStream.Error ||
    std.Io.File.OpenError ||
    std.Io.File.Writer.Error ||
    std.Io.Dir.CreateDirPathError ||
    Io.Reader.StreamError ||
    Io.Reader.LimitedAllocError ||
    Allocator.Error;

allocator: Allocator,
http_client: *http.Client,
owns_http_client: bool,
config: Config,

test {
    _ = @import("ops.zig");
    _ = @import("http/request.zig");
    _ = @import("auth/signing.zig");
    _ = @import("http/url.zig");
    _ = @import("internal.zig");
}

test "Config.fromEnvMap reads credentials, session token, and region" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "ak");
    try env.put("AWS_SECRET_ACCESS_KEY", "sk");
    try env.put("AWS_SESSION_TOKEN", "tok");
    try env.put("AWS_REGION", "eu-west-1");

    const config = try S3Client.Config.fromEnvMap(&env);
    try std.testing.expectEqualStrings("ak", config.access_key_id);
    try std.testing.expectEqualStrings("sk", config.secret_access_key);
    try std.testing.expectEqualStrings("tok", config.session_token.?);
    try std.testing.expectEqualStrings("eu-west-1", config.region);
}

test "Config.fromEnvMap falls back to AWS_DEFAULT_REGION" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "ak");
    try env.put("AWS_SECRET_ACCESS_KEY", "sk");
    try env.put("AWS_DEFAULT_REGION", "us-west-2");

    const config = try S3Client.Config.fromEnvMap(&env);
    try std.testing.expect(config.session_token == null);
    try std.testing.expectEqualStrings("us-west-2", config.region);
}

test "Config.fromEnvMap requires access key and secret key" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.MissingAwsCredentials, S3Client.Config.fromEnvMap(&env));

    try env.put("AWS_ACCESS_KEY_ID", "ak");
    try std.testing.expectError(error.MissingAwsCredentials, S3Client.Config.fromEnvMap(&env));
}

test "Config.fromStsCredentials borrows STS credential fields" {
    var credentials = sts.Credentials{
        .access_key_id = try std.testing.allocator.dupe(u8, "ak"),
        .secret_access_key = try std.testing.allocator.dupe(u8, "sk"),
        .session_token = try std.testing.allocator.dupe(u8, "token"),
        .expiration = null,
        .allocator = std.testing.allocator,
    };
    defer credentials.deinit();

    const config = S3Client.Config.fromStsCredentials(&credentials, "us-east-1");
    try std.testing.expectEqualStrings("ak", config.access_key_id);
    try std.testing.expectEqualStrings("sk", config.secret_access_key);
    try std.testing.expectEqualStrings("token", config.session_token.?);
    try std.testing.expectEqualStrings("us-east-1", config.region);
}
