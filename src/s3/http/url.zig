const std = @import("std");
const lib = @import("lib");
const internal = lib.internal;
const S3Client = @import("../client.zig").S3Client;

/// Split an URL into its parts and return scheme and host as single strings.
/// Everything following the host is cut off.
fn endpointHostSlice(endpoint: []const u8) struct { scheme: ?[]const u8, host: []const u8 } {
    var host = endpoint;
    var scheme: ?[]const u8 = null;
    if (std.mem.startsWith(u8, host, "https://")) {
        scheme = host[0..8];
        host = host[8..];
    } else if (std.mem.startsWith(u8, host, "http://")) {
        scheme = host[0..7];
        host = host[7..];
    }

    const cut = std.mem.findAny(u8, host, "/?#") orelse host.len;
    host = host[0..cut];

    if (std.mem.findScalarLast(u8, host, '@')) |at| {
        host = host[at + 1 ..];
    }

    return .{ .scheme = scheme, .host = host };
}

/// Build a request URL for a S3 API request call.
///
/// This combines scheme, endpoint, bucket, key and query string into the
/// correct URL to be processed by a S3 request depending on the used request style.
pub fn buildUrl(self: *S3Client, bucket: []const u8, key: ?[]const u8, query: ?[]const u8) ![]u8 {
    const query_part = if (query) |q| try std.fmt.allocPrint(self.allocator, "?{s}", .{q}) else "";
    defer if (query != null) self.allocator.free(query_part);

    const encoded_key = if (key) |k| blk: {
        const encoded_k = try internal.encodePath(self.allocator, k);
        defer self.allocator.free(encoded_k);
        const fmt_k = try std.fmt.allocPrint(self.allocator, "/{s}", .{encoded_k});
        break :blk fmt_k;
    } else "";
    defer if (key != null) self.allocator.free(encoded_key);

    if (self.config.endpoint) |endpoint| {
        const clean_endpoint = endpointHostSlice(endpoint);

        if (self.config.virtual_host_style) {
            return std.fmt.allocPrint(self.allocator, "{s}{s}.{s}{s}{s}", .{ clean_endpoint.scheme orelse "https://", bucket, clean_endpoint.host, encoded_key, query_part });
        } else {
            return std.fmt.allocPrint(self.allocator, "{s}{s}/{s}{s}{s}", .{ clean_endpoint.scheme orelse "https://", clean_endpoint.host, bucket, encoded_key, query_part });
        }
    }
    return std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com{s}{s}", .{ bucket, self.config.region, encoded_key, query_part });
}

pub fn buildServiceUrl(self: *S3Client) ![]u8 {
    if (self.config.endpoint) |endpoint| {
        if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
            return self.allocator.dupe(u8, std.mem.trimEnd(u8, endpoint, "/"));
        } else {
            return std.fmt.allocPrint(self.allocator, "https://{s}", .{endpoint});
        }
    }
    return std.fmt.allocPrint(self.allocator, "https://s3.{s}.amazonaws.com", .{self.config.region});
}

pub fn getHost(self: *S3Client, bucket: []const u8) ![]u8 {
    if (self.config.endpoint) |endpoint| {
        const host = endpointHostSlice(endpoint).host;
        if (self.config.virtual_host_style) {
            return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ bucket, host });
        } else {
            return self.allocator.dupe(u8, host);
        }
    }
    return std.fmt.allocPrint(self.allocator, "{s}.s3.{s}.amazonaws.com", .{ bucket, self.config.region });
}

pub fn getServiceHost(self: *S3Client) ![]u8 {
    if (self.config.endpoint) |endpoint| {
        return self.allocator.dupe(u8, endpointHostSlice(endpoint).host);
    }
    return std.fmt.allocPrint(self.allocator, "s3.{s}.amazonaws.com", .{self.config.region});
}

/// Canonical URI for SigV4 (path-style vs virtual-host-style).
/// Caller owns the returned slice.
pub fn canonicalUri(self: *S3Client, bucket: ?[]const u8, key: ?[]const u8) ![]u8 {
    const path_style = self.config.endpoint != null and !self.config.virtual_host_style;

    if (bucket) |b| {
        if (key) |k| {
            const encoded_key = try internal.encodePath(self.allocator, k);
            defer self.allocator.free(encoded_key);
            if (path_style) {
                return std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ b, encoded_key });
            }
            return std.fmt.allocPrint(self.allocator, "/{s}", .{encoded_key});
        }
        if (path_style) {
            return std.fmt.allocPrint(self.allocator, "/{s}", .{b});
        }
        return try self.allocator.dupe(u8, "/");
    }
    return try self.allocator.dupe(u8, "/");
}

test "buildUrl percent-encodes object keys" {
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

    const url_value = try buildUrl(&client, "my-bucket", "path with space?.txt", null);
    defer std.testing.allocator.free(url_value);
    try std.testing.expectEqualStrings("https://example.com/my-bucket/path%20with%20space%3F.txt", url_value);
}

test "buildUrl and getHost use virtual-host-style when enabled" {
    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .region = "us-east-1",
            .endpoint = "https://example.com",
            .virtual_host_style = true,
        },
    };

    const url_value = try buildUrl(&client, "my-bucket", "path with space?.txt", "x=1");
    defer std.testing.allocator.free(url_value);
    try std.testing.expectEqualStrings("https://my-bucket.example.com/path%20with%20space%3F.txt?x=1", url_value);

    const host = try getHost(&client, "my-bucket");
    defer std.testing.allocator.free(host);
    try std.testing.expectEqualStrings("my-bucket.example.com", host);
}

test "getHost strips endpoint path/query and userinfo" {
    var client = S3Client{
        .allocator = std.testing.allocator,
        .http_client = undefined,
        .owns_http_client = false,
        .config = .{
            .access_key_id = "ak",
            .secret_access_key = "sk",
            .region = "us-east-1",
            .endpoint = "https://user:pass@example.com:9000/minio?x=1",
        },
    };

    const host = try getHost(&client, "ignored");
    defer std.testing.allocator.free(host);
    try std.testing.expectEqualStrings("example.com:9000", host);
}
