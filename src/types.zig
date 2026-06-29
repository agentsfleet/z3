//! S3 response types and XML parsing utilities
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Information about a bucket
pub const BucketInfo = struct {
    /// Name of the bucket
    name: []const u8,
    /// Creation date as ISO-8601 string
    creation_date: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *BucketInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.creation_date);
    }
};

/// Information about an object
pub const ObjectInfo = struct {
    /// Key (path) of the object
    key: []const u8,
    /// Size in bytes
    size: u64,
    /// Last modified as ISO-8601 string
    last_modified: []const u8,
    /// ETag (usually MD5 hash)
    etag: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *ObjectInfo) void {
        self.allocator.free(self.key);
        self.allocator.free(self.last_modified);
        self.allocator.free(self.etag);
    }
};

/// Result of listing objects
pub const ListObjectsResult = struct {
    objects: []ObjectInfo,
    common_prefixes: []const []const u8,
    /// True if there are more results (pagination)
    is_truncated: bool,
    /// Token for next page (if truncated)
    next_continuation_token: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *ListObjectsResult) void {
        for (self.objects) |*obj| {
            obj.deinit();
        }
        for (self.common_prefixes) |prefix| {
            self.allocator.free(prefix);
        }
        self.allocator.free(self.objects);
        if (self.next_continuation_token) |token| {
            self.allocator.free(token);
        }
    }
};

/// Result of listing buckets
pub const ListBucketsResult = struct {
    buckets: []BucketInfo,
    owner_id: ?[]const u8,
    owner_display_name: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *ListBucketsResult) void {
        for (self.buckets) |*bucket| {
            bucket.deinit();
        }
        self.allocator.free(self.buckets);
        if (self.owner_id) |id| self.allocator.free(id);
        if (self.owner_display_name) |name| self.allocator.free(name);
    }
};

pub const CreateMultipartUploadResult = struct {
    bucket: []const u8,
    key: []const u8,
    upload_id: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *CreateMultipartUploadResult) void {
        self.allocator.free(self.bucket);
        self.allocator.free(self.key);
        self.allocator.free(self.upload_id);
    }
};

pub const CompleteMultipartUploadResult = struct {
    bucket: []const u8,
    key: []const u8,
    etag: []const u8,
    checksum_crc32: ?[]const u8,
    checksum_crc32c: ?[]const u8,
    checksum_crc64nvme: ?[]const u8,
    checksum_sha1: ?[]const u8,
    checksum_sha256: ?[]const u8,
    checksum_type: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *CompleteMultipartUploadResult) void {
        self.allocator.free(self.bucket);
        self.allocator.free(self.key);
        self.allocator.free(self.etag);
        if (self.checksum_crc32) |v| {
            self.allocator.free(v);
        }
        if (self.checksum_crc32c) |v| {
            self.allocator.free(v);
        }
        if (self.checksum_crc64nvme) |v| {
            self.allocator.free(v);
        }
        if (self.checksum_sha1) |v| {
            self.allocator.free(v);
        }
        if (self.checksum_sha256) |v| {
            self.allocator.free(v);
        }
        if (self.checksum_type) |v| {
            self.allocator.free(v);
        }
    }
};

/// S3 error parsed from XML response
pub const S3Error = struct {
    code: []const u8,
    message: []const u8,
    request_id: []const u8,
    resource: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *S3Error) void {
        self.allocator.free(self.code);
        self.allocator.free(self.message);
        self.allocator.free(self.request_id);
        self.allocator.free(self.resource);
    }
};
