//! Async S3 Client for Zig 0.16+
//! Built on std.http.Client with Io interface for async operations
//! Supports AWS S3, Cloudflare R2, MinIO, and other S3-compatible services
const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ops = @import("s3_ops.zig");
const request_types = @import("s3_request_types.zig");

pub const S3Client = @This();

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

pub const Metadata = struct {
    name: []const u8,
    value: []const u8,
};

pub const PutObjectOptions = struct {
    request: RequestOptions = .{},
    metadata: ?[]const Metadata = null,
    content_type: ?[]const u8 = null,
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
    ContentLengthRequired,
    BodyLengthMismatch,
};

pub const RequestError = Error || Allocator.Error || error{
    InvalidUri,
    ConnectionFailed,
    SendFailed,
    FlushFailed,
    ReceiveFailed,
    ReadFailed,
    WriteFailed,
    RequestTooLong,
    StringToSignTooLong,
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

    pub const Error = error{
        ReaderAlreadyRequested,
    };

    pub fn status(self: *const ObjectStream) http.Status {
        return self.response.head.status;
    }

    pub fn reader(self: *ObjectStream) ObjectStream.Error!*Io.Reader {
        if (self.reader_started) return error.ReaderAlreadyRequested;
        self.reader_started = true;
        return self.response.readerDecompressing(
            &self.transfer_buffer,
            &self.decompress,
            &self.decompress_buffer,
        );
    }

    pub fn deinit(self: *ObjectStream) void {
        self.request.deinit();
        self.allocator.destroy(self.request);
        self.request_data.deinit();
    }
};

pub const init = ops.init;
pub const deinit = ops.deinit;
pub const getObject = ops.getObject;
pub const getObjectStreamWithOptions = ops.getObjectStreamWithOptions;
pub const getFile = ops.getFile;
pub const getObjectWithOptions = ops.getObjectWithOptions;
pub const putObject = ops.putObject;
pub const putFile = ops.putFile;
pub const putObjectWithOptions = ops.putObjectWithOptions;
pub const putObjectWithMetadata = ops.putObjectWithMetadata;
pub const deleteObject = ops.deleteObject;
pub const deleteObjectWithOptions = ops.deleteObjectWithOptions;
pub const headObject = ops.headObject;
pub const ListObjectsOptions = ops.ListObjectsOptions;
pub const listObjects = ops.listObjects;
pub const listObjectsWithOptions = ops.listObjectsWithOptions;
pub const createBucket = ops.createBucket;
pub const deleteBucket = ops.deleteBucket;
pub const copyObject = ops.copyObject;
pub const listBuckets = ops.listBuckets;

pub const GetFileError =
    @typeInfo(@typeInfo(@TypeOf(getObjectStreamWithOptions)).@"fn".return_type.?).error_union.error_set ||
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
    _ = @import("s3_ops.zig");
    _ = @import("s3_request.zig");
    _ = @import("s3_signing.zig");
    _ = @import("s3_url.zig");
    _ = @import("s3_internal.zig");
}
