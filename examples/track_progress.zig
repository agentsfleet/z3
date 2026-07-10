const std = @import("std");
const builtin = @import("builtin");
const z3 = @import("s3");
const linux = std.os.linux;
const CustomStreams = z3.S3Client.CustomStreams;
const RequestWriter = z3.RequestWriter;
const RequestReader = z3.RequestReader;
const RequestOptions = z3.S3Client.RequestOptions;
const ProgressState = z3.ProgressState;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 2) {
        std.log.err("Need file path as first positional argument", .{});
        return error.WrongArgumentCount;
    }

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

    var client = try z3.S3Client.init(gpa, .{
        .access_key_id = access_key,
        .secret_access_key = secret_key,
        .endpoint = endpoint,
        .virtual_host_style = false,
        .region = region,
    }, .{ .io = io });
    defer client.deinit();

    const file = try std.Io.Dir.cwd().readFileAlloc(io, argv[1], gpa, .unlimited);
    defer gpa.free(file);

    // Set progress tracking struct for PUT request
    var progress_state_write: ProgressState = .{
        .content_length = .init(file.len),
    };

    // Spaws thread which reads the progress parallel to request execution
    const progress_thread_write: std.Thread = try .spawn(.{}, trackProgress, .{ io, &progress_state_write, argv[1], .PUT });

    // Send request
    var put_resp = try client.putObject(bucket, key, file, .{
        .request = .{
            .req_drain_fn = drainFnCustom,
            .req_progress = &progress_state_write,
        },
    });
    defer put_resp.deinit();
    // Join progress tracking thread before continuing
    progress_thread_write.join();

    var progress_state_read: ProgressState = .{
        // .content_length = 1000,
    };

    var name_buf: [64]u8 = undefined;
    const progress_thread_read: std.Thread = try .spawn(.{}, trackProgress, .{ io, &progress_state_read, try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ bucket, key }), .GET });

    var get_resp = try client.getObject(bucket, key, .{
        .request = .{
            .req_stream_fn = streamFnCustom,
            .req_discard_fn = discardFnCustom,
            .req_progress = &progress_state_read,
        },
    });
    defer get_resp.deinit();
    progress_thread_read.join();

    // Write received bytes to file
    var download_file = try std.Io.Dir.cwd().createFile(io, argv[1], .{});
    try download_file.writePositionalAll(io, get_resp.body, 0);
}

const CURSOR_INVISIBLE = "\x1b[?25l";
const CURSOR_VISIBLE = "\x1b[?25h";
const TO_LINE_START = "\x1b[0G";
const RESET = "\x1b[0m";

const Action = enum {
    PUT,
    GET,
};

// A progress tracking implementation with a simple progress bar. Needs a terminal
// width of at least 60 cols + name.len to be properly rendered
fn trackProgress(
    io: std.Io,
    progress: *ProgressState,
    name: []const u8,
    action: Action,
) void {
    // Loop which waits until the content_length value is set. Either directly by the
    // user or through the ContentLength header by a GET request.
    while (true) {
        const len = progress.content_length.load(.acquire);
        if (len != ProgressState.unknown_content_length) break;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }

    const win_width: usize = switch (builtin.os.tag) {
        .linux => blk: {
            var winsize: std.posix.winsize = undefined;
            switch (linux.errno(getTermWinsize(&winsize))) {
                .SUCCESS => break :blk @intCast(winsize.col),
                else => break :blk 80,
            }
        },
        else => 80,
    };

    const color = switch (action) {
        .GET => "\x1b[36m",
        .PUT => "\x1b[35m",
    };
    std.debug.print("Start {t} object request with progress tracking\n", .{action});
    std.debug.print("{s}", .{CURSOR_INVISIBLE});
    const total: f64 = @floatFromInt(progress.content_length.load(.monotonic));
    const bar_width = win_width - (name.len + 11);
    while (true) {
        const cur: f64 = @floatFromInt(progress.bytes_written.load(.monotonic));
        const percent = cur / total * 100.0;
        const fill: usize = @intFromFloat(percent / 100.0 * @as(f64, @floatFromInt(bar_width)));

        std.debug.print("{s}[{s}", .{ TO_LINE_START, color });

        var idx: usize = 0;

        while (idx < fill) : (idx += 1) {
            std.debug.print("#", .{});
        }

        std.debug.print("{s}", .{RESET});

        while (idx < bar_width) : (idx += 1) {
            std.debug.print("-", .{});
        }
        std.debug.print("] {d:>5.1}% {s}", .{ percent, name });

        if (progress.bytes_written.load(.monotonic) >= progress.content_length.load(.monotonic)) break;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print("{s}\n", .{CURSOR_VISIBLE});
    std.debug.print("Ended {t} request. 'progress_state': {d} bytes transferred\n", .{ action, progress.bytes_written.load(.monotonic) });
}

// These functions only show the content of the default ones for `RequestWriter`
// and `RequestReader`. If necessary, they can be edited to accomplish more complex
// tracking tasks etc. However, the functions signature and args can't be altered
// since they're required by the respective vtable.

fn drainFnCustom(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *RequestWriter = @fieldParentPtr("interface", w);
    const n = try self.inner.vtable.drain(self.inner, data, splat);
    if (self.progress_state) |ps| {
        _ = ps.bytes_written.fetchAdd(n, .monotonic);
    }
    return n;
}

fn streamFnCustom(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *RequestReader = @fieldParentPtr("interface", r);
    const n = try self.inner.stream(w, limit);
    if (self.progress_state) |ps| {
        _ = ps.bytes_written.fetchAdd(n, .monotonic);
    }
    return n;
}

fn discardFnCustom(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    const self: *RequestReader = @fieldParentPtr("interface", r);
    const n = try self.inner.discard(limit);
    if (self.progress_state) |ps| {
        _ = ps.bytes_written.fetchAdd(n, .monotonic);
    }
    return n;
}

// Function for getting terminal size
fn getTermWinsize(winsize: *std.posix.winsize) usize {
    return linux.ioctl(linux.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(winsize));
}
