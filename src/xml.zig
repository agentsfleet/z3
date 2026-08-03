//! Simple XML parsing utilities for S3 responses
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const testing = std.testing;
const Response = @import("client.zig").S3Client.Response;

/// Extracts content between <tag ...> and </tag>.
/// Handles potential attributes in the start tag.
pub fn extractTag(content: []const u8, tag: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const s_start = std.fmt.bufPrint(&buf, "<{s}", .{tag}) catch return null;

    const s_idx = std.mem.find(u8, content, s_start) orelse return null;
    // Ensure we matched the full tag name and not a prefix (e.g. <Key matched in <KeyCount>)
    if (s_idx + s_start.len < content.len) {
        const next_char = content[s_idx + s_start.len];
        if (next_char != '>' and next_char != ' ' and next_char != '\t' and next_char != '\n' and next_char != '\r') {
            // Try again further in the string
            return extractTag(content[s_idx + s_start.len ..], tag);
        }
    }

    const open_tag_end = std.mem.findPos(u8, content, s_idx, ">") orelse return null;

    const e_tag = std.fmt.bufPrint(&buf, "</{s}>", .{tag}) catch return null;
    const e_idx = std.mem.findPos(u8, content, open_tag_end, e_tag) orelse return null;

    return content[open_tag_end + 1 .. e_idx];
}

fn extractTagDupe(allocator: Allocator, content: []const u8, tag: []const u8) ![]const u8 {
    if (extractTag(content, tag)) |val| {
        return try allocator.dupe(u8, val);
    }
    return try allocator.dupe(u8, "");
}

fn extractTagOptionalDupe(allocator: Allocator, content: []const u8, tag: []const u8) !?[]const u8 {
    if (extractTag(content, tag)) |val| {
        return try allocator.dupe(u8, val);
    }
    return null;
}

/// Parse S3 error response XML
pub fn parseS3Error(allocator: Allocator, body: []const u8) !types.S3Error {
    const code = try extractTagDupe(allocator, body, "Code");
    errdefer allocator.free(code);

    const message = try extractTagDupe(allocator, body, "Message");
    errdefer allocator.free(message);

    const request_id = try extractTagDupe(allocator, body, "RequestId");
    errdefer allocator.free(request_id);

    const resource = try extractTagDupe(allocator, body, "Resource");

    return types.S3Error{
        .allocator = allocator,
        .code = code,
        .message = message,
        .request_id = request_id,
        .resource = resource,
    };
}

/// Parse ListObjectsV2 response. Takes ownership of `response`.
pub fn parseListObjects(allocator: Allocator, response: *Response) !types.ListObjectsResult {
    var http_response = response.*;
    errdefer http_response.deinit();

    var objects = std.ArrayList(types.ObjectInfo).empty;
    errdefer {
        for (objects.items) |*obj| obj.deinit();
        objects.deinit(allocator);
    }

    const body = http_response.body;

    var it = std.mem.splitSequence(u8, body, "<Contents>");
    _ = it.first(); // skip part before first <Contents>

    while (it.next()) |obj_xml| {
        // Only process until </Contents> if it exists in this chunk
        var chunk = obj_xml;
        if (std.mem.find(u8, obj_xml, "</Contents>")) |end_idx| {
            chunk = obj_xml[0..end_idx];
        }

        const key = try extractTagDupe(allocator, chunk, "Key");
        errdefer allocator.free(key);

        const last_modified = try extractTagDupe(allocator, chunk, "LastModified");
        errdefer allocator.free(last_modified);

        const etag = try extractTagDupe(allocator, chunk, "ETag");
        errdefer allocator.free(etag);

        var size: u64 = 0;
        if (extractTag(chunk, "Size")) |size_str| {
            size = std.fmt.parseInt(u64, size_str, 10) catch 0;
        }

        try objects.append(allocator, .{
            .key = key,
            .last_modified = last_modified,
            .etag = etag,
            .size = size,
            .allocator = allocator,
        });
    }

    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |prefix| allocator.free(prefix);
        prefixes.deinit(allocator);
    }

    var prefix_it = std.mem.splitSequence(u8, body, "<CommonPrefixes>");
    _ = prefix_it.first();

    while (prefix_it.next()) |obj_xml| {
        var chunk = obj_xml;
        if (std.mem.indexOf(u8, obj_xml, "</CommonPrefixes>")) |end_idx| {
            chunk = obj_xml[0..end_idx];
        }

        const prefix = try extractTagDupe(allocator, chunk, "Prefix");
        errdefer allocator.free(prefix);

        try prefixes.append(allocator, prefix);
    }

    var is_truncated = false;
    if (extractTag(body, "IsTruncated")) |trunc| {
        is_truncated = std.mem.eql(u8, trunc, "true");
    }

    const next_continuation_token = try extractTagOptionalDupe(allocator, body, "NextContinuationToken");
    errdefer if (next_continuation_token) |t| allocator.free(t);

    const object_slice = try objects.toOwnedSlice(allocator);
    errdefer {
        for (object_slice) |*obj| obj.deinit();
        allocator.free(object_slice);
    }

    const prefix_slice = try prefixes.toOwnedSlice(allocator);

    return .{
        .objects = object_slice,
        .common_prefixes = prefix_slice,
        .is_truncated = is_truncated,
        .next_continuation_token = next_continuation_token,
        .http_response = http_response,
        .allocator = allocator,
    };
}

/// Parse ListBuckets response. Takes ownership of `response`.
pub fn parseListBuckets(allocator: Allocator, response: *Response) !types.ListBucketsResult {
    var http_response = response.*;
    errdefer http_response.deinit();

    var buckets = std.ArrayList(types.BucketInfo).empty;
    errdefer {
        for (buckets.items) |*b| b.deinit();
        buckets.deinit(allocator);
    }

    const body = http_response.body;

    var it = std.mem.splitSequence(u8, body, "<Bucket>");
    _ = it.first();

    while (it.next()) |bucket_xml| {
        var chunk = bucket_xml;
        if (std.mem.find(u8, bucket_xml, "</Bucket>")) |end_idx| {
            chunk = bucket_xml[0..end_idx];
        }

        const name = try extractTagDupe(allocator, chunk, "Name");
        errdefer allocator.free(name);

        const date = try extractTagDupe(allocator, chunk, "CreationDate");
        errdefer allocator.free(date);

        try buckets.append(allocator, .{
            .name = name,
            .creation_date = date,
            .allocator = allocator,
        });
    }

    const owner_id = try extractTagOptionalDupe(allocator, body, "ID");
    errdefer if (owner_id) |id| allocator.free(id);

    const owner_display_name = try extractTagOptionalDupe(allocator, body, "DisplayName");
    errdefer if (owner_display_name) |n| allocator.free(n);

    const bucket_slice = try buckets.toOwnedSlice(allocator);

    return .{
        .buckets = bucket_slice,
        .owner_id = owner_id,
        .owner_display_name = owner_display_name,
        .http_response = http_response,
        .allocator = allocator,
    };
}

pub fn parseCreateMultipartUpload(allocator: Allocator, body: []const u8) !types.CreateMultipartUploadResult {
    const bucket = try extractTagDupe(allocator, body, "Bucket");
    errdefer allocator.free(bucket);

    const key = try extractTagDupe(allocator, body, "Key");
    errdefer allocator.free(key);

    const upload_id = try extractTagDupe(allocator, body, "UploadId");

    return .{
        .bucket = bucket,
        .key = key,
        .upload_id = upload_id,
        .allocator = allocator,
    };
}

pub fn parseCompleteMultipartUpload(allocator: Allocator, body: []const u8) !types.CompleteMultipartUploadResult {
    const bucket = try extractTagDupe(allocator, body, "Bucket");
    errdefer allocator.free(bucket);

    const key = try extractTagDupe(allocator, body, "Key");
    errdefer allocator.free(key);

    const etag = try extractTagDupe(allocator, body, "ETag");
    errdefer allocator.free(etag);

    const checksum_crc32 = try extractTagOptionalDupe(allocator, body, "ChecksumCRC32");
    errdefer if (checksum_crc32) |v| allocator.free(v);

    const checksum_crc32c = try extractTagOptionalDupe(allocator, body, "ChecksumCRC32C");
    errdefer if (checksum_crc32c) |v| allocator.free(v);

    const checksum_crc64nvme = try extractTagOptionalDupe(allocator, body, "ChecksumCRC64NVME");
    errdefer if (checksum_crc64nvme) |v| allocator.free(v);

    const checksum_sha1 = try extractTagOptionalDupe(allocator, body, "ChecksumSHA1");
    errdefer if (checksum_sha1) |v| allocator.free(v);

    const checksum_sha256 = try extractTagOptionalDupe(allocator, body, "ChecksumSHA256");
    errdefer if (checksum_sha256) |v| allocator.free(v);

    const checksum_type = try extractTagOptionalDupe(allocator, body, "ChecksumType");

    return .{
        .allocator = allocator,
        .bucket = bucket,
        .key = key,
        .etag = etag,
        .checksum_crc32 = checksum_crc32,
        .checksum_crc32c = checksum_crc32c,
        .checksum_crc64nvme = checksum_crc64nvme,
        .checksum_sha1 = checksum_sha1,
        .checksum_sha256 = checksum_sha256,
        .checksum_type = checksum_type,
    };
}

fn makeTestResponse(allocator: Allocator, body: []const u8) !Response {
    return .{
        .allocator = allocator,
        .body = try allocator.dupe(u8, body),
        .http_head = .{
            .bytes = try allocator.dupe(u8, ""),
            .keep_alive = false,
            .reason = "",
            .status = .ok,
            .version = .@"HTTP/1.1",
        },
        .s3_head = .{ .x_amz_header = .init(allocator), .allocator = allocator },
    };
}

test "parseListObjects" {
    var resp = try makeTestResponse(
        testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Contents><Key>my-key-1</Key><LastModified>2025-12-21T01:43:47.314Z</LastModified><ETag>\"f0e633243609a75b2a4949cb431e333e\"</ETag><Size>12</Size></Contents><Contents><Key>my-key-2</Key><LastModified>2025-12-21T01:43:47.314Z</LastModified><ETag>\"d41d8cd98f00b204e9800998ecf8427e\"</ETag><Size>0</Size></Contents></ListBucketResult>",
    );
    var result = try parseListObjects(testing.allocator, &resp);
    defer result.deinit();
    try testing.expectEqual(result.objects.len, 2);
    try testing.expectEqualStrings(result.objects[0].key, "my-key-1");
    try testing.expectEqual(result.objects[0].size, 12);
}

test "parseListObjects with continuation token" {
    var resp = try makeTestResponse(
        testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>next-token</NextContinuationToken><Contents><Key>my-key-1</Key><LastModified>2025-12-21T01:43:47.314Z</LastModified><ETag>\"f0e633243609a75b2a4949cb431e333e\"</ETag><Size>12</Size></Contents></ListBucketResult>",
    );
    var result = try parseListObjects(testing.allocator, &resp);
    defer result.deinit();
    try testing.expect(result.is_truncated);
    try testing.expectEqualStrings(result.next_continuation_token.?, "next-token");
}

test "parseListBuckets" {
    var resp = try makeTestResponse(
        testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListAllMyBucketsResult><Owner><ID>12345</ID><DisplayName>my-user</DisplayName></Owner><Buckets><Bucket><Name>bucket-1</Name><CreationDate>2025-12-21T01:13:10.000Z</CreationDate></Bucket><Bucket><Name>bucket-2</Name><CreationDate>2025-12-21T01:13:10.000Z</CreationDate></Bucket></Buckets></ListAllMyBucketsResult>",
    );
    var result = try parseListBuckets(testing.allocator, &resp);
    defer result.deinit();
    try testing.expectEqual(result.buckets.len, 2);
    try testing.expectEqualStrings(result.buckets[0].name, "bucket-1");
}

test "parseListObjects frees response on allocation failure" {
    // First allocation builds the body/headers with the real testing allocator;
    // parse uses a failing allocator so owned fields fail and must not leak the response.
    var resp = try makeTestResponse(
        testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Contents><Key>my-key-1</Key><LastModified>2025-12-21T01:43:47.314Z</LastModified><ETag>\"abc\"</ETag><Size>1</Size></Contents></ListBucketResult>",
    );
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const result = parseListObjects(failing.allocator(), &resp);
    try testing.expectError(error.OutOfMemory, result);
}

test "parseListBuckets frees response on allocation failure" {
    var resp = try makeTestResponse(
        testing.allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListAllMyBucketsResult><Owner><ID>12345</ID><DisplayName>my-user</DisplayName></Owner><Buckets><Bucket><Name>bucket-1</Name><CreationDate>2025-12-21T01:13:10.000Z</CreationDate></Bucket></Buckets></ListAllMyBucketsResult>",
    );
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const result = parseListBuckets(failing.allocator(), &resp);
    try testing.expectError(error.OutOfMemory, result);
}

test "parseCreateMultipartUpload" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<InitiateMultipartUploadResult>
        \\   <Bucket>my_bucket</Bucket>
        \\   <Key>object_key</Key>
        \\   <UploadId>VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA</UploadId>
        \\</InitiateMultipartUploadResult>
    ;
    var result = try parseCreateMultipartUpload(testing.allocator, xml_data);
    defer result.deinit();
    try testing.expectEqualStrings(result.bucket, "my_bucket");
    try testing.expectEqualStrings(result.key, "object_key");
    try testing.expectEqualStrings(result.upload_id, "VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA");
}

test "parseCompleteMultipartUpload" {
    const xml_data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<CompleteMultipartUploadResult>
        \\   <Bucket>my_bucket</Bucket>
        \\   <Key>object_key</Key>
        \\   <ChecksumSHA256>jxQI5grOOHSfZQjolbPvz15pBrpsLhY+</ChecksumSHA256>
        \\   <ETag>39ce861709bb90c113178402381e3267d0d262487126abb4</ETag>
        \\</CompleteMultipartUploadResult>
    ;
    var result = try parseCompleteMultipartUpload(testing.allocator, xml_data);
    defer result.deinit();
    try testing.expectEqualStrings(result.bucket, "my_bucket");
    try testing.expectEqualStrings(result.etag, "39ce861709bb90c113178402381e3267d0d262487126abb4");
    try testing.expectEqualStrings(result.checksum_sha256.?, "jxQI5grOOHSfZQjolbPvz15pBrpsLhY+");
}

test "parseS3Error" {
    const xml_data = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>";
    var result = try parseS3Error(testing.allocator, xml_data);
    defer result.deinit();
    try testing.expectEqualStrings(result.code, "NoSuchKey");
}
