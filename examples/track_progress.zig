const std = @import("std");
const z3 = @import("s3");
const CustomStreams = z3.S3Client.CustomStreams;
const RequestWriter = z3.RequestWriter;
const RequestOptions = z3.S3Client.RequestOptions;
const ProgressState = z3.ProgressState;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2) {
        std.log.err("Need file path as first positional argument", .{});
        return error.NoFilePathFound;
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

    var progress_state: ProgressState = .{ .total_bytes = file.len };

    std.debug.print("{s}", .{CURSOR_INVISIBLE});
    const progress_thread: std.Thread = try .spawn(.{}, trackProgress, .{ io, &progress_state, argv[1] });

    var resp = try client.putObject(bucket, key, file, .{
        .request = .{
            .req_drain_fn = drainFnCustom,
            .req_progress = &progress_state,
        },
    });
    defer resp.deinit();
    progress_thread.join();

    if (resp.http_head.status != .ok) std.log.err("Something went wrong", .{});
}

pub const CURSOR_INVISIBLE = "\x1b[?25l";
pub const CURSOR_VISIBLE = "\x1b[?25h";
pub const TO_LINE_START = "\x1b[0G";

fn trackProgress(io: std.Io, progress: *ProgressState, name: []const u8) void {
    while (true) {
        if (progress.bytes_written > 0) {
            const total: f64 = @floatFromInt(progress.total_bytes);
            const cur: f64 = @floatFromInt(progress.bytes_written);
            const percent = cur / total * 100.0;
            const fill: usize = @intFromFloat(percent / 100.0 * 50);

            std.debug.print("{s}[", .{TO_LINE_START});

            var idx: usize = 0;

            while (idx < fill) : (idx += 1) {
                std.debug.print("#", .{});
            }

            while (idx < 50) : (idx += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("] {d:.1}% {s}", .{ percent, name });

            if (progress.bytes_written == progress.total_bytes) break;
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }
    std.debug.print("{s}\n", .{CURSOR_VISIBLE});
    std.log.info("Ended. 'progress_state': {d} bytes transferred", .{progress.bytes_written});
}

fn drainFnCustom(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *RequestWriter = @fieldParentPtr("interface", w);
    const n = try self.inner.vtable.drain(self.inner, data, splat);
    if (self.progress_state) |ps| {
        ps.bytes_written += n;
    }
    return n;
}
