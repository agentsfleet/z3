//! AWS Signature Version 4 (service and URI parameterized).
const std = @import("std");
const crypto = std.crypto;
const internal = @import("internal.zig");

pub const HeaderToSign = struct {
    name: []const u8,
    value: []const u8,
};

pub fn signRequest(
    allocator: std.mem.Allocator,
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8,
    service: []const u8,
    method: []const u8,
    canonical_uri: []const u8,
    query: []const u8,
    headers: []const HeaderToSign,
) ![]u8 {
    const amz_date = findHeaderValue(headers, "x-amz-date") orelse return error.RequestTooLong;
    const date_stamp = amz_date[0..8];

    const headers_sorted = try allocator.alloc(HeaderToSign, headers.len);
    defer allocator.free(headers_sorted);
    @memcpy(headers_sorted, headers);

    std.sort.heap(HeaderToSign, headers_sorted, {}, struct {
        fn lessThan(_: void, a: HeaderToSign, b: HeaderToSign) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var canonical_headers = std.ArrayList(u8).empty;
    defer canonical_headers.deinit(allocator);
    var signed_headers = std.ArrayList(u8).empty;
    defer signed_headers.deinit(allocator);

    for (headers_sorted, 0..) |header, i| {
        if (i > 0) {
            try signed_headers.append(allocator, ';');
            try canonical_headers.append(allocator, '\n');
        }
        try signed_headers.appendSlice(allocator, header.name);
        try canonical_headers.appendSlice(allocator, header.name);
        try canonical_headers.append(allocator, ':');
        try canonical_headers.appendSlice(allocator, header.value);
    }

    var canonical_buf: [8192]u8 = undefined;
    const content_hash = findHeaderValue(headers_sorted, "x-amz-content-sha256") orelse return error.RequestTooLong;
    const canonical_request = std.fmt.bufPrint(
        &canonical_buf,
        "{s}\n{s}\n{s}\n{s}\n\n{s}\n{s}",
        .{
            method,
            canonical_uri,
            query,
            canonical_headers.items,
            signed_headers.items,
            content_hash,
        },
    ) catch return error.RequestTooLong;

    var canonical_hash_buf: [64]u8 = undefined;
    internal.sha256Hex(canonical_request, &canonical_hash_buf);

    var sts_buf: [512]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(
        &sts_buf,
        "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}",
        .{ amz_date, date_stamp, region, service, &canonical_hash_buf },
    ) catch return error.StringToSignTooLong;

    const sig_hex = try computeSignature(secret_access_key, region, service, date_stamp, string_to_sign);

    return std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders={s}, Signature={s}",
        .{ access_key_id, date_stamp, region, service, signed_headers.items, &sig_hex },
    );
}

fn computeSignature(
    secret_access_key: []const u8,
    region: []const u8,
    service: []const u8,
    date_stamp: []const u8,
    string_to_sign: []const u8,
) ![64]u8 {
    var key_buf: [256]u8 = undefined;
    const key_str = std.fmt.bufPrint(&key_buf, "AWS4{s}", .{secret_access_key}) catch return error.KeyTooLong;

    var k_date: [32]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_stamp, key_str);

    var k_region: [32]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_region, region, &k_date);

    var k_service: [32]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_service, service, &k_region);

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

test "signRequest produces credential scope for dynamodb" {
    const amz_date = "20240101T000000Z";
    const headers = [_]HeaderToSign{
        .{ .name = "content-type", .value = "application/x-amz-json-1.0" },
        .{ .name = "host", .value = "dynamodb.us-east-1.amazonaws.com" },
        .{ .name = "x-amz-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .name = "x-amz-date", .value = amz_date },
        .{ .name = "x-amz-target", .value = "DynamoDB_20120810.GetItem" },
    };

    const auth = try signRequest(
        std.testing.allocator,
        "AKIDEXAMPLE",
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "us-east-1",
        "dynamodb",
        "POST",
        "/",
        "",
        &headers,
    );
    defer std.testing.allocator.free(auth);

    try std.testing.expect(std.mem.indexOf(u8, auth, "Credential=AKIDEXAMPLE/20240101/us-east-1/dynamodb/aws4_request") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "Signature=") != null);
}
