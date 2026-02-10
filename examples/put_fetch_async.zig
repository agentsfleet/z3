//! S3 Client Example - Async parallel fetch
//! Fetches all objects in parallel using io.async futures
const std = @import("std");
const S3Client = @import("s3").S3Client;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var threaded: Io.Threaded = .init(gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    return runMain(gpa, io, init.environ_map);
}

fn runMain(allocator: Allocator, io: Io, env: *std.process.Environ.Map) !void {
    const access_key = env.get("AWS_ACCESS_KEY_ID") orelse {
        std.debug.print("AWS_ACCESS_KEY_ID not set\n", .{});
        return;
    };
    const secret_key = env.get("AWS_SECRET_ACCESS_KEY") orelse {
        std.debug.print("AWS_SECRET_ACCESS_KEY not set\n", .{});
        return;
    };
    const region = env.get("AWS_REGION") orelse "auto";
    const endpoint = env.get("S3_ENDPOINT") orelse "https://7ba9afa0682066b2986a17f41ead69ea.r2.cloudflarestorage.com";

    const bucket = env.get("S3_BUCKET") orelse {
        std.debug.print("S3_BUCKET not set\n", .{});
        return;
    };

    var client = try S3Client.init(allocator, .{
        .access_key_id = access_key,
        .secret_access_key = secret_key,
        .region = region,
        .endpoint = endpoint,
    }, .{ .io = io });
    defer client.deinit();

    // Create test objects with known keys
    const test_keys = [_][]const u8{ "afile-0.txt", "afile-1.txt", "afile-2.txt", "afile-3.txt", "afile-4.txt" };

    std.debug.print("Creating {d} test objects...\n", .{test_keys.len});
    const PutFuture = Io.Future(S3Client.RequestError!S3Client.Response);
    var futures_a: [test_keys.len]PutFuture = undefined;
    for (test_keys, 0..) |key, i| {
        futures_a[i] = io.async(S3Client.putObject, .{ &client, bucket, key, "THIS IS A TEST FILE" });
    }

    // Await results
    std.debug.print("\nResults:\n", .{});
    for (&futures_a, 0..) |*future, i| {
        if (future.await(io)) |res| {
            var response = res;
            defer response.deinit();
            std.debug.print("[{d}] {s}: {} - \"{s}\"\n", .{ i, test_keys[i], response.status, response.body });
        } else |_| {
            std.debug.print("[{d}] {s}: ERROR\n", .{ i, test_keys[i] });
        }
    }

    var list_res = try client.listObjects(bucket, "");
    defer list_res.deinit();
    std.debug.print("Listing all the files!!\n", .{});
    for (list_res.objects) |obj| {
        std.debug.print("{s}\n", .{obj.key});
    }

    // Fetch all objects in parallel using io.async
    std.debug.print("\nFetching {d} objects in parallel...\n", .{test_keys.len});

    const GetFuture = Io.Future(S3Client.RequestError!S3Client.Response);
    var futures: [test_keys.len]GetFuture = undefined;
    for (test_keys, 0..) |key, i| {
        futures[i] = io.async(S3Client.getObject, .{ &client, bucket, key });
    }

    // Await results
    std.debug.print("\nResults:\n", .{});
    var total_bytes: usize = 0;
    for (&futures, 0..) |*future, i| {
        if (future.await(io)) |res| {
            var response = res;
            defer response.deinit();
            std.debug.print("[{d}] {s}: {} - \"{s}\"\n", .{ i, test_keys[i], response.status, response.body });
            total_bytes += response.body.len;
        } else |_| {
            std.debug.print("[{d}] {s}: ERROR\n", .{ i, test_keys[i] });
        }
    }
    std.debug.print("\nTotal: {d} bytes from {d} objects (fetched in parallel)\n", .{ total_bytes, test_keys.len });
}
