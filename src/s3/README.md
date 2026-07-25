# s3 — Async S3 client

Module of [aws_zig](../../README.md). Import as `@import("s3")`.

Async S3 client built on `std.http.Client` and `std.Io`. Primarily tested with Cloudflare R2; works with AWS S3, MinIO, and other S3-compatible services.

## Features

- **Async & Parallel**: Zig `std.Io` for non-blocking, parallel operations
- **S3 Compatible**: AWS S3, Cloudflare R2, MinIO, …
- **AWS Environment Credentials** and **STS** `AssumeRoleWithWebIdentity` (`s3.sts`)
- GET, PUT, DELETE, HEAD, Copy, bucket management, file upload/download
- Streaming downloads, multipart upload, progress tracking
- Path-style and virtual-host-style requests
- Built-in S3 XML parsing for listings and error bodies

## Quick start

```zig
const std = @import("std");
const S3Client = @import("s3").S3Client;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var config = try S3Client.Config.fromEnvMap(env);
    config.region = "auto";
    config.endpoint = "https://<accountid>.r2.cloudflarestorage.com";
    config.virtual_host_style = false; // default

    var client = try S3Client.init(allocator, config, .{ .io = io });
    defer client.deinit();

    const keys = [_][]const u8{ "file1.txt", "file2.txt" };
    const Future = Io.Future(S3Client.RequestError!S3Client.Response);
    var futures: [keys.len]Future = undefined;

    for (keys, 0..) |key, i| {
        futures[i] = io.async(S3Client.getObject, .{ &client, "my-bucket", key, .{} });
    }

    for (&futures, 0..) |*future, i| {
        if (future.await(io)) |res| {
            var response = res;
            defer response.deinit();
            std.debug.print("Fetched {s}: {s}\n", .{ keys[i], response.body });
        } else |err| {
            std.debug.print("Error fetching {s}: {}\n", .{ keys[i], err });
        }
    }
}
```

## Authentication

Use `S3Client.Config.fromEnvMap` for standard AWS env credentials. For web identity, use `s3.sts.assumeRoleWithWebIdentity`, then `S3Client.Config.fromStsCredentials`.

## Response errors

```zig
response.expectSuccess() catch |err| {
    std.debug.print("{s}: {s}\n", .{
        response.s3ErrorCode() orelse @errorName(err),
        response.s3ErrorMessage() orelse "request failed",
    });
    return err;
};
```

## Supported operations

### Object
- `getObject`, `getObjectStream`, `getFile`
- `putObject`, `putFile`, `deleteObject`, `headObject`, `copyObject`
- `listObjects`
- `createMultipartUpload`, `uploadPart`, `completeMultipartUpload`, `abortMultipartUpload`

### Bucket
- `listBuckets`, `headBucket`, `createBucket`, `deleteBucket`

## Custom metadata

```zig
const metadata = [_]S3Client.Metadata{
    .{ .name = "color", .value = "blue" },
    .{ .name = "owner", .value = "zig-test" },
};

var response = try client.putObject("my-bucket", "meta.txt", "hello", .{
    .metadata = &metadata,
});
defer response.deinit();
```

Also on `putFile` via `PutFileOptions.metadata`.

## ListObjects pagination

```zig
var first = try client.listObjects("my-bucket", .{ .max_keys = 100 });
defer first.deinit();

if (first.is_truncated and first.next_continuation_token != null) {
    var next = try client.listObjects("my-bucket", .{
        .continuation_token = first.next_continuation_token.?,
        .max_keys = 100,
    });
    defer next.deinit();
}
```

## Limitations

- **Streaming upload signatures**: `putFile` needs a seekable file for content length and SHA-256; chunked signing not implemented
- **Presigned URLs**: not yet
- **Advanced auth**: no ECS/EC2 IAM role or profile discovery yet

## Examples

From the package root:

```bash
zig build example-put-fetch-async
zig build example-get-multipart
zig build example-put-multipart
zig build example-track-progress -- <FILE>
```

Sources: [`examples/s3/`](../../examples/s3/).

## Tests

```bash
zig build test
zig build integration-test-s3
```
