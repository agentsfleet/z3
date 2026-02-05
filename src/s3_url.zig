const std = @import("std");
const internal = @import("s3_internal.zig");
const S3Client = @import("s3_client.zig").S3Client;

fn endpointHostSlice(endpoint: []const u8) []const u8 {
    var host = endpoint;
    if (std.mem.startsWith(u8, host, "https://")) {
        host = host[8..];
    } else if (std.mem.startsWith(u8, host, "http://")) {
        host = host[7..];
    }

    const cut = std.mem.indexOfAny(u8, host, "/?#") orelse host.len;
    host = host[0..cut];

    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| {
        host = host[at + 1 ..];
    }

    return std.mem.trim(u8, host, "/");
}

pub fn buildUrl(self: *S3Client, bucket: []const u8, key: []const u8) ![]u8 {
    const encoded_key = try internal.encodePath(self.allocator, key);
    defer self.allocator.free(encoded_key);
    if (self.config.endpoint) |endpoint| {
        if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
            const clean_endpoint = std.mem.trimEnd(u8, endpoint, "/");
            return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ clean_endpoint, bucket, encoded_key });
        } else {
            return std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}", .{ endpoint, bucket, encoded_key });
        }
    }
    return std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com/{s}", .{ bucket, self.config.region, encoded_key });
}

pub fn buildBucketUrl(self: *S3Client, bucket: []const u8, query: ?[]const u8) ![]u8 {
    const query_part = if (query) |q| try std.fmt.allocPrint(self.allocator, "?{s}", .{q}) else "";
    defer if (query != null) self.allocator.free(query_part);

    if (self.config.endpoint) |endpoint| {
        if (std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://")) {
            const clean_endpoint = std.mem.trimEnd(u8, endpoint, "/");
            return std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ clean_endpoint, bucket, query_part });
        } else {
            return std.fmt.allocPrint(self.allocator, "https://{s}/{s}{s}", .{ endpoint, bucket, query_part });
        }
    }
    return std.fmt.allocPrint(self.allocator, "https://{s}.s3.{s}.amazonaws.com{s}", .{ bucket, self.config.region, query_part });
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
        return self.allocator.dupe(u8, endpointHostSlice(endpoint));
    }
    return std.fmt.allocPrint(self.allocator, "{s}.s3.{s}.amazonaws.com", .{ bucket, self.config.region });
}

pub fn getServiceHost(self: *S3Client) ![]u8 {
    if (self.config.endpoint) |endpoint| {
        return self.allocator.dupe(u8, endpointHostSlice(endpoint));
    }
    return std.fmt.allocPrint(self.allocator, "s3.{s}.amazonaws.com", .{self.config.region});
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

    const url_value = try buildUrl(&client, "my-bucket", "path with space?.txt");
    defer std.testing.allocator.free(url_value);
    try std.testing.expectEqualStrings("https://example.com/my-bucket/path%20with%20space%3F.txt", url_value);
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
