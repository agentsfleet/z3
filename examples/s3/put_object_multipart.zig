const std = @import("std");
const S3Client = @import("s3").S3Client;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
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
        .virtual_host_style = false,
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

    // WARN: Many providers restrict multipart uploads to min. 5MB per chunk.
    // Thus, this example might not run on your machine. Check if you get an
    // EntityToSmall error response and change the part_size.
    const part_size: usize = 100; // Size of upload part in bytes

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

    // Pre-allocate one slot per part. Each task writes to its own index
    // (part_number - 1), so no synchronization is needed.
    const uploaded_parts = try allocator.alloc(?S3Client.UploadedPart, part_count);
    defer allocator.free(uploaded_parts);
    defer for (uploaded_parts) |slot| {
        if (slot) |part| allocator.free(part.etag);
    };
    @memset(uploaded_parts, null);

    // TODO: CreateMultipartUpload here
    var create_response = try client.createMultipartUpload(bucket, key, .{});
    defer create_response.deinit();

    // Save upload ID to constant
    const upload_id = create_response.upload_id;
    std.log.debug("upload id: {s}", .{create_response.upload_id});
    if (upload_id.len == 0) return error.NoUploadId;

    // Set a value for max parallel downloads
    const max_concurrency_count = 3;

    // Create a semaphore to control the max count
    var semaphore: Io.Semaphore = .{ .permits = max_concurrency_count };

    // Create a group which takes the part upload functions
    var futures: std.Io.Group = .init;
    errdefer futures.cancel(io);

    // Create a timestamp just for making timeintervals visible
    const start_t = std.Io.Timestamp.now(io, .awake);
    std.log.info("Starting upload process", .{});

    for (ranges.items, 1..) |r, part_number| {
        // Here we need to add one to the end, because byte sclice end index is
        // exclusive
        const body = content[r.start .. r.end + 1];
        futures.async(io, uploadPart, .{
            io,
            allocator,
            &semaphore,
            &client,
            bucket,
            key,
            body,
            upload_id,
            @intCast(part_number),
            uploaded_parts,
            start_t,
        });
    }

    try futures.await(io);

    // Collect successful parts; log any slots that came back null (failed/cancelled).
    var completed = std.ArrayList(S3Client.UploadedPart).empty;
    defer completed.clearAndFree(allocator);
    for (uploaded_parts, 1..) |slot, n| {
        if (slot) |part| {
            try completed.append(allocator, part);
        } else {
            std.log.err("Part {d} did not complete successfully", .{n});
        }
    }

    if (completed.items.len != part_count) {
        std.log.err("Uploaded parts don't match original part count! {d} != {d}", .{ completed.items.len, part_count });
    }

    var complete_multipart_resp = try client.completeMultipartUpload(bucket, key, .{
        .upload_id = upload_id,
        .uploaded_parts = completed.items,
    });
    defer complete_multipart_resp.deinit();

    std.log.info("Successfully completed multipart upload. Etag of full object: {s}", .{complete_multipart_resp.etag});
}

// helper function for uploading parts and interacting with the semaphore
fn uploadPart(
    io: Io,
    allocator: std.mem.Allocator,
    sema: *Io.Semaphore,
    client: *S3Client,
    bucket: []const u8,
    key: []const u8,
    body: []const u8,
    upload_id: []const u8,
    part_number: u32,
    uploads: []?S3Client.UploadedPart,
    start_t: Io.Timestamp,
) !void {
    // We need to always return `Io.Cancelable.Canceled`. Otherwise `Group`
    // processing wont work.
    sema.wait(io) catch return Io.Cancelable.Canceled;
    defer sema.post(io);

    std.log.debug("{d}ms: Start upload of part {d}", .{ start_t.untilNow(io, .awake).toMilliseconds(), part_number });

    // Upload part of file
    var resp = client.uploadPart(
        bucket,
        key,
        body,
        upload_id,
        part_number,
        .{},
    ) catch return Io.Cancelable.Canceled;
    defer resp.deinit();

    // Copy Etag to heap to outlive the helper function (needs to be freed later!)
    const etag = allocator.dupe(u8, resp.s3_head.etag orelse {
        return Io.Cancelable.Canceled;
    }) catch return Io.Cancelable.Canceled;

    // Write to the pre-allocated slot for this part. Each task owns a unique
    // index so no synchronization is needed.
    uploads[part_number - 1] = .{
        .etag = etag,
        .part_number = part_number,
    };

    std.log.debug("{d}ms: Successfully uploaded part {d}; etag: {s}", .{ start_t.untilNow(io, .awake).toMilliseconds(), part_number, etag });
}
