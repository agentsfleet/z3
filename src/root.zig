//! Zig S3 Client Library
//! Async S3 client built on std.http.Client with Io interface
const std = @import("std");

pub const S3Client = @import("client.zig").S3Client;
pub const types = @import("types.zig");
const request = @import("http/request.zig");

// Re-export commonly used types
pub const BucketInfo = types.BucketInfo;
pub const ObjectInfo = types.ObjectInfo;
pub const ListObjectsResult = types.ListObjectsResult;
pub const ListBucketsResult = types.ListBucketsResult;
pub const S3Error = types.S3Error;
pub const RequestWriter = request.RequestWriter;
pub const RequestReader = request.RequestReader;
pub const ProgressState = request.ProgressState;

test {
    _ = @import("client.zig");
    _ = @import("types.zig");
    _ = @import("xml.zig");
}
