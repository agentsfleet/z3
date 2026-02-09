const std = @import("std");
const S3Client = @import("s3").S3Client;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded: Io.Threaded = .init(allocator, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const env = init.environ_map;

    const access_key = env.get("S3_ACCESS_KEY_ID") orelse {
        std.debug.print("S3_ACCESS_KEY_ID not set\n", .{});
        return;
    };
    const secret_key = env.get("S3_SECRET_ACCESS_KEY") orelse {
        std.debug.print("S3_SECRET_ACCESS_KEY not set\n", .{});
        return;
    };
    const region = env.get("S3_REGION") orelse "auto";
    const bucket = env.get("S3_BUCKET") orelse {
        std.debug.print("S3_BUCKET not set\n", .{});
        return;
    };
    const key = env.get("S3_KEY") orelse {
        std.debug.print("S3_KEY not set\n", .{});
        return;
    };
    const endpoint = env.get("S3_ENDPOINT") orelse {
        std.debug.print("S3_ENDPOINT not set\n", .{});
        return;
    };

    var client = try S3Client.init(allocator, .{
        .access_key_id = access_key,
        .secret_access_key = secret_key,
        .region = region,
        .endpoint = endpoint,
    }, .{ .io = io });
    defer client.deinit();

    var head_obj_resp = try client.headObject(bucket, key);
    defer head_obj_resp.deinit();

    var resp = try client.getObjectWithOptions(bucket, key, .{ .range = .{ .start = 2, .end = 4 } });
    defer resp.deinit();

    std.debug.print("Request status: {t}! Object range received: {s}\n", .{ resp.status, resp.body });
}
