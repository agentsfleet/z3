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

    // Some dumb blind text
    const content =
        \\Far far away, behind the word mountains, far from the countries Vokalia and
        \\Consonantia, there live the blind texts. Separated they live in Bookmarksgrove
        \\right at the coast of the Semantics, a large language ocean. A small river named
        \\Duden flows by their place and supplies it with the necessary regelialia. It is
        \\a paradisematic country, in which roasted parts of sentences fly into your
        \\mouth. Even the all-powerful Pointing has no control about the blind texts it is
    ;

    const part_size: usize = 50; // Size of upload part in bytes

    const file_size = content.len;

    // Calculate parts count
    var part_count = (file_size / part_size) + 1;
    var last_part_size = file_size % part_size;
    if (last_part_size == 0) {
        last_part_size = part_size;
        part_count -= 1;
    }

    // Create array of part ranges
    var ranges = std.ArrayList(S3Client.ContentRange).empty;
    defer ranges.clearAndFree(allocator);

    // Add ranges to array
    for (0..part_count) |part| {
        const start = part * part_size;
        // INFO: Remember the "end" index of a http request rangesis inclusive,
        // in contrast to byte/string slice indices where the "end" index is exclusive
        const end = if (part == part_count - 1)
            start + last_part_size - 1
        else
            (part + 1) * part_size - 1;
        try ranges.append(allocator, .{ .start = start, .end = end });
    }

    // TODO: CreateMultipartUpload here
    var create_response = try client.createMultipartUpload(bucket, key, .{});
    defer create_response.deinit();

    // Save upload ID to constant
    const upload_id = create_response.upload_id;

    // Set a value for max parallel downloads
    const max_concurrency_count = 3;

    // Create a semaphore to control the max count
    var semaphore: Io.Semaphore = .{ .permits = max_concurrency_count };

    // Create a group which takes the part upload functions
    var futures: std.Io.Group = .init;
    errdefer futures.cancel(io);

    // Create a timestamp just for making timeintervals visible
    const start_t = std.Io.Timestamp.now(io, .awake);
    std.log.info("Starting download process", .{});
}

// helper function for downloading parts and interacting with the semaphore
fn downloadAndWrite(
    io: Io,
    sema: *Io.Semaphore,
    file: *std.Io.File,
    client: *S3Client,
    bucket: []const u8,
    key: []const u8,
    range: S3Client.ContentRange,
    start_t: Io.Timestamp,
) !void {
    // We need to always return `Io.Cancelable.Canceled`. Otherwise `Group`
    // processing wont work.
    sema.wait(io) catch return Io.Cancelable.Canceled;
    defer sema.post(io);

    std.log.debug("{d}ms: Start download of range {d}-{d}", .{ start_t.untilNow(io, .awake).toMilliseconds(), range.start, range.end });

    // TODO: UploadPart here and push to list holding CompletedPart items
    //
    std.log.debug("{d}ms: Successfully written range {d}-{d}", .{ start_t.untilNow(io, .awake).toMilliseconds(), range.start, range.end });
}
