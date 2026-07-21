//! S3 response types and XML parsing utilities
const std = @import("std");
const Allocator = std.mem.Allocator;
const S3Client = @import("client.zig").S3Client;

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

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Name");
        try jws.write(self.name);
        try jws.objectField("CreationDate");
        try jws.write(self.creation_date);
        try jws.endObject();
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

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Key");
        try jws.write(self.key);
        try jws.objectField("Size");
        try jws.write(self.size);
        try jws.objectField("LastModified");
        try jws.write(self.last_modified);
        try jws.objectField("ETag");
        try jws.write(self.etag);
        try jws.endObject();
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
        self.allocator.free(self.common_prefixes);
        self.allocator.free(self.objects);
        if (self.next_continuation_token) |token| {
            self.allocator.free(token);
        }
    }

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.beginArray();
        try jws.write(self.objects);
        try jws.endArray();
        try jws.endObject();
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

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Buckets");
        try jws.beginArray();
        try jws.write(self.buckets);
        try jws.endArray();
        try jws.objectField("Owner");
        try jws.beginObject();
        try jws.objectField("DisplayName");
        try jws.write(self.owner_display_name);
        try jws.objectField("Id");
        try jws.write(self.owner_id);
        try jws.endObject();
        try jws.endObject();
    }
};

pub const HeadObjectResult = struct {
    accept_ranges: ?[]const u8 = null,
    expiration: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    content_length: ?u64 = null,
    etag: ?[]const u8 = null,
    version_id: ?[]const u8 = null,
    delete_marker: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    allocator: Allocator,

    pub fn parseHeadObject(allocator: Allocator, response: *S3Client.Response) !HeadObjectResult {
        return .{
            .allocator = allocator,
            .accept_ranges = if (response.s3_head.accept_ranges) |val| try allocator.dupe(u8, val) else null,
            .etag = if (response.s3_head.etag) |val| try allocator.dupe(u8, val) else null,
            .last_modified = if (response.s3_head.last_modified) |val| try allocator.dupe(u8, val) else null,
            .content_type = if (response.http_head.content_type) |val| try allocator.dupe(u8, val) else null,
            .content_length = response.http_head.content_length,
            .version_id = if (try response.s3_head.getAmzValue("version-id")) |val| try allocator.dupe(u8, val) else null,
            .expiration = if (try response.s3_head.getAmzValue("expiration")) |val| try allocator.dupe(u8, val) else null,
            .delete_marker = if (try response.s3_head.getAmzValue("delete-marker")) |val| try allocator.dupe(u8, val) else null,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.accept_ranges) |val| self.allocator.free(val);
        if (self.expiration) |val| self.allocator.free(val);
        if (self.last_modified) |val| self.allocator.free(val);
        if (self.etag) |val| self.allocator.free(val);
        if (self.version_id) |val| self.allocator.free(val);
        if (self.delete_marker) |val| self.allocator.free(val);
        if (self.content_type) |val| self.allocator.free(val);
    }

    pub fn jsonStringify(self: *const HeadObjectResult, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("AcceptRanges");
        try jws.write(self.accept_ranges);
        try jws.objectField("Expiration");
        try jws.write(self.expiration);
        try jws.objectField("LastModified");
        try jws.write(self.last_modified);
        try jws.objectField("ContentLength");
        try jws.write(self.content_length);
        try jws.objectField("ETag");
        try jws.write(self.etag);
        try jws.objectField("VersionId");
        try jws.write(self.version_id);
        try jws.objectField("DeleteMarker");
        try jws.write(self.delete_marker);
        try jws.objectField("ContentType");
        try jws.write(self.content_type);
        try jws.endObject();
    }
};

pub const HeadBucketResult = struct {
    exists: bool = false,
    region: ?[]const u8 = null,
    allocator: Allocator,

    pub fn parseHeadBucket(allocator: Allocator, resp: *S3Client.Response) !HeadBucketResult {
        return .{
            .allocator = allocator,
            .exists = if (resp.http_head.status == .ok) true else false,
            .region = if (try resp.s3_head.getAmzValue("region")) |val| try allocator.dupe(u8, val) else null,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.region) |r| self.allocator.free(r);
    }

    pub fn jsonStringify(self: *const HeadBucketResult, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("Exists");
        try jws.write(self.exists);
        try jws.objectField("Region");
        try jws.write(self.region);
        try jws.endObject();
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
