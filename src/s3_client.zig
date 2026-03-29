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
    /// Set S3 request style to virtual host style. Otherwise, use the legacy
    /// path style request.
    ///
    /// See https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html
    /// for more information.
    virtual_host_style: bool = false,
    unsigned_payload: bool = false,
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
    _ = @import("s3_ops.zig");
    _ = @import("s3_request.zig");
    _ = @import("s3_signing.zig");
    _ = @import("s3_url.zig");
    _ = @import("s3_internal.zig");
}
