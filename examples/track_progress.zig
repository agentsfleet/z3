const std = @import("std");
const builtin = @import("builtin");
const z3 = @import("s3");
const linux = std.os.linux;
const ProgressState = z3.ProgressState;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len != 2) {
        std.log.err("Need file path as first positional argument", .{});
        return error.WrongArgumentCount;
    }

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

    // Set progress tracking struct for PUT request. For an upload we already
    // know the size, so declare it up front.
    var progress_state_write: ProgressState = .{};
    progress_state_write.setTotal(io, file.len);

    // Spaws thread which reads the progress parallel to request execution
    const progress_thread_write: std.Thread = try .spawn(.{}, trackProgress, .{ io, &progress_state_write, argv[1], .PUT });

    // Send request. The built-in writer keeps `progress_state_write` updated;
    // no custom drain/stream hooks are needed for a basic progress bar.
    var put_resp = try client.putObject(bucket, key, file, .{
        .request = .{
            .req_progress = &progress_state_write,
        },
    });
    defer put_resp.deinit();
    // Join progress tracking thread before continuing
    progress_thread_write.join();

    // For a download we don't know the size up front; the library resolves it
    // from the response's Content-Length header.
    var progress_state_read: ProgressState = .{};

    const read_name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bucket, key });
    defer gpa.free(read_name);
    const progress_thread_read: std.Thread = try .spawn(.{}, trackProgress, .{ io, &progress_state_read, read_name, .GET });

    var get_resp = try client.getObject(bucket, key, .{
        .request = .{
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
    // Block until the transfer size is known — either from `setTotal` (upload)
    // or the response's Content-Length (download). If there is no known size,
    // there is nothing to render, so bail out.
    const total = progress.waitTotal(io) orelse {
        std.log.warn("no content length for {s}, skipping progress bar", .{name});
        return;
    };

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
    const bar_width = win_width - (name.len + 11);
    while (true) {
        const cur: f64 = @floatFromInt(progress.transferred());
        const percent = if (total == 0) 0.0 else cur / @as(f64, @floatFromInt(total)) * 100.0;
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

        if (progress.transferred() >= total) break;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print("{s}\n", .{CURSOR_VISIBLE});
    std.debug.print("Ended {t} request. 'progress_state': {d} bytes transferred\n", .{ action, progress.transferred() });
}

// Function for getting terminal size
fn getTermWinsize(winsize: *std.posix.winsize) usize {
    return linux.ioctl(linux.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(winsize));
}
