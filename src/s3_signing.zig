const std = @import("std");
const crypto = std.crypto;
const internal = @import("s3_internal.zig");
const S3Client = @import("s3_client.zig").S3Client;

pub const HeaderToSign = struct {
    name: []const u8,
    value: []const u8,
};

pub fn signRequest(
    self: *S3Client,
    method: []const u8,
    bucket: ?[]const u8,
    key: ?[]const u8,
    query: ?[]const u8,
    headers: []const HeaderToSign,
) ![]u8 {
    const amz_date = findHeaderValue(headers, "x-amz-date") orelse return error.RequestTooLong;
    const date_stamp = amz_date[0..8];

    var encoded_key: ?[]const u8 = null;
    if (key) |k| {
        encoded_key = try internal.encodePath(self.allocator, k);
    }
    defer if (encoded_key) |ek| self.allocator.free(ek);

    var uri_buf: [2048]u8 = undefined;
    const canonical_uri = if (bucket) |b|
        if (key) |k|
            if (self.config.endpoint != null and !self.config.virtual_host_style)
                std.fmt.bufPrint(&uri_buf, "/{s}/{s}", .{ b, encoded_key orelse k }) catch return error.RequestTooLong
            else
                std.fmt.bufPrint(&uri_buf, "/{s}", .{encoded_key orelse k}) catch return error.RequestTooLong
        else if (self.config.endpoint != null and !self.config.virtual_host_style)
            std.fmt.bufPrint(&uri_buf, "/{s}", .{b}) catch return error.RequestTooLong
        else
            "/"
    else
        "/";

    const headers_sorted = try self.allocator.alloc(HeaderToSign, headers.len);
    defer self.allocator.free(headers_sorted);
    std.mem.copyForwards(HeaderToSign, headers_sorted, headers);

    std.sort.heap(HeaderToSign, headers_sorted, {}, struct {
        fn lessThan(_: void, a: HeaderToSign, b: HeaderToSign) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var canonical_headers = std.ArrayListUnmanaged(u8).empty;
    defer canonical_headers.deinit(self.allocator);
    var signed_headers = std.ArrayListUnmanaged(u8).empty;
    defer signed_headers.deinit(self.allocator);

    for (headers_sorted, 0..) |header, i| {
        if (i > 0) {
            try signed_headers.append(self.allocator, ';');
            try canonical_headers.append(self.allocator, '\n');
        }
        try signed_headers.appendSlice(self.allocator, header.name);

        try canonical_headers.appendSlice(self.allocator, header.name);
        try canonical_headers.append(self.allocator, ':');
        try canonical_headers.appendSlice(self.allocator, header.value);
    }

    var canonical_buf: [4096]u8 = undefined;
    const content_hash = findHeaderValue(headers_sorted, "x-amz-content-sha256") orelse return error.RequestTooLong;
    const canonical_request = std.fmt.bufPrint(
        &canonical_buf,
        "{s}\n{s}\n{s}\n{s}\n\n{s}\n{s}",
        .{
            method,
            canonical_uri,
            query orelse "",
            canonical_headers.items,
            signed_headers.items,
            content_hash,
        },
    ) catch return error.RequestTooLong;

    var canonical_hash_buf: [64]u8 = undefined;
    internal.sha256Hex(canonical_request, &canonical_hash_buf);
    const canonical_hash = &canonical_hash_buf;

    var sts_buf: [512]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(&sts_buf, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/s3/aws4_request\n{s}", .{ amz_date, date_stamp, self.config.region, canonical_hash }) catch return error.StringToSignTooLong;

    const sig_hex = try computeSignature(self, date_stamp, string_to_sign);

    return std.fmt.allocPrint(self.allocator, "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/s3/aws4_request, SignedHeaders={s}, Signature={s}", .{ self.config.access_key_id, date_stamp, self.config.region, signed_headers.items, &sig_hex });
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
    internal.bytesToHex(&signature, &sig_hex);
    return sig_hex;
}

fn findHeaderValue(headers: []const HeaderToSign, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header.value;
    }
    return null;
}

test "unsigned payload request" {
    const url = @import("s3_url.zig");
    const bucket = "my-bucket";
    const key = "my-key";

    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .region = "us-east-1",
            .endpoint = "https://example.com",
            .unsigned_payload = true,
        },
    };

    const host = try url.getHost(&client, bucket);
    defer client.allocator.free(host);

    const auth = try signRequest(
        &client,
        "GET",
        bucket,
        key,
        null,
        &[_]HeaderToSign{
            .{ .name = "host", .value = host },
            .{ .name = "x-amz-date", .value = "20250101T000000Z" },
            .{ .name = "x-amz-content-sha256", .value = "UNSIGNED-PAYLOAD" },
        },
    );
    defer std.testing.allocator.free(auth);
    try std.testing.expect(auth.len > 0);
}

test "signRequest includes large host headers" {
    const host = try std.testing.allocator.alloc(u8, 2000);
    defer std.testing.allocator.free(host);
    @memset(host, 'a');

    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .region = "us-east-1",
            .endpoint = null,
        },
    };

    const auth = try signRequest(
        &client,
        "GET",
        null,
        null,
        null,
        &[_]HeaderToSign{
            .{ .name = "host", .value = host },
            .{ .name = "x-amz-date", .value = "20250101T000000Z" },
            .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        },
    );
    defer std.testing.allocator.free(auth);
    try std.testing.expect(auth.len > 0);
}
