# z3 - Async S3 Client for Zig

`z3` is a lightweight, high-performance, and asynchronous S3 client for Zig. It is built directly on `std.http.Client` and utilizes the `std.Io` interface for efficient parallel operations. It has been primarily tested with Cloudflare R2 but is designed to work with any S3-compatible service.

## Expect breaking changes until zig 0.16 is released

## Features

- **Async & Parallel**: Leverages Zig's `std.Io` for non-blocking, parallel S3 operations.
- **Pure Zig**: Zero external dependencies beyond the Zig standard library.
- **S3 Compatible**: Works with AWS S3, Cloudflare R2, MinIO, and other S3-compatible storage services.
- **Comprehensive API**: Supports GET, PUT, DELETE, HEAD, Copy, Bucket management, and file-based uploads/downloads.
- **Streaming**: Includes streaming APIs for object downloads and direct-to-file transfers.
- **XML Parsing**: Built-in support for parsing S3 XML responses for object listings and error handling.
- **Virtual-Host-Style Requests** Supports both: legacy path-style requests, as well as virtual-host-style requests.

## Prerequisites

- **Zig 0.16+**: This library uses modern Zig features and the latest `std.http` and `std.Io` APIs.

## Installation

Add `z3` to your `build.zig.zon`:

```bash
zig fetch --save git+https://codeberg.org/fellowtraveler/z3.git
```

Then in your `build.zig`:

```zig
const s3 = b.dependency("z3", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("s3", s3.module("s3"));
```

## Quick Start

Here is a simple example of fetching objects in parallel:

```zig
const std = @import("std");
const S3Client = @import("s3").S3Client;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Initialize async IO
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Configure the client
    var client = try S3Client.init(allocator, .{
        .access_key_id = "YOUR_ACCESS_KEY",
        .secret_access_key = "YOUR_SECRET_KEY",
        .region = "auto",
        .endpoint = "https://<accountid>.r2.cloudflarestorage.com",
        .virtual_host_style = false, // default
    }, .{.io = io });
    defer client.deinit();

    // Fetch objects in parallel
    const keys = [_][]const u8{ "file1.txt", "file2.txt" };
    const Future = std.Io.Future(S3Client.RequestError!S3Client.Response);
    var futures: [keys.len]Future = undefined;

    for (keys, 0..) |key, i| {
        futures[i] = io.async(S3Client.getObject, .{ &client, "my-bucket", key, .{} });
    }

    // Await results
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

## Supported Operations

### Object Operations
- `getObject(bucket, key, options)`
- `getObjectStream(bucket, key, options)`
- `getFile(bucket, key, dest_path, options)`
- `putObject(bucket, key, body, options)`
- `putFile(bucket, key, src_path, options)`
- `deleteObject(bucket, key, options)`
- `headObject(bucket, key)`
- `copyObject(src_bucket, src_key, dst_bucket, dst_key)`
- `listObjects(bucket, options)`

### Bucket Operations
- `listBuckets()`
- `createBucket(bucket)`
- `deleteBucket(bucket)`

## Custom Metadata

Attach `x-amz-meta-*` headers on PUT requests:

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

Metadata is also supported on `putFile` via `PutFileOptions.metadata`.

## ListObjects Pagination

Use `listObjects` with continuation tokens:

```zig
var first = try client.listObjects("my-bucket", .{
    .max_keys = 100,
});
defer first.deinit();

if (first.is_truncated and first.next_continuation_token != null) {
    var next = try client.listObjects("my-bucket", .{
        .continuation_token = first.next_continuation_token.?,
        .max_keys = 100,
    });
    defer next.deinit();
}
```

## Current Limitations & Roadmap

`z3` is currently a work-in-progress. The following features are not yet implemented:

- **Multipart Upload**: Essential for uploading files larger than 5GB or for better reliability with large files.
- **Streaming Upload Signatures**: `putFile` requires a seekable file to compute content length and SHA-256; chunked signing is not yet implemented.
- **Presigned URLs**: Support for generating temporary GET/PUT URLs.
- **Advanced Authentication**: Support for IAM roles, environment variables, and AWS profile-based credential discovery.
- **Automatic Retries**: Built-in exponential backoff for transient network or S3 errors.

## Running Examples

The repository includes runnable examples in `examples/`:

- `examples/put_fetch_async.zig`
- `examples/get_object_multipart.zig`

Run them with:

```bash
zig build example-put-fetch-async
zig build example-get-multipart
```

## License

MIT
