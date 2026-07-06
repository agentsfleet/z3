const std = @import("std");
const z3 = @import("s3");
const CustomStreams = z3.S3Client.CustomStreams;

pub const custom_streams: CustomStreams = .{ .custom_stream_writer = CountingWriter };
var progress_state: usize = 0;

pub fn main(init: std.process.Init) !void {
    // std.debug.print("{any}\n", .{z3.S3Client.custom_streams});
    // std.process.exit(0);
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

    const progress_thread: std.Thread = try .spawn(.{}, trackProgress, .{ io, file.len, argv[1] });

    var resp = try client.putObject(bucket, key, file, .{});
    defer resp.deinit();
    progress_thread.join();

    if (resp.http_head.status != .ok) std.log.err("Something went wrong", .{});
}

fn trackProgress(io: std.Io, size: u64, name: []const u8) void {
    while (true) {
        if (progress_state > 0) {
            std.debug.print("\r{d}/{d}: {s}", .{ progress_state, size, name });
            if (progress_state == size) break;
            io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }
    std.debug.print("\n", .{});
    std.log.info("Ended. 'progress_state': {d}", .{progress_state});
    progress_state = 0;
}

const CountingWriter = struct {
    inner: *std.Io.Writer,
    interface: std.Io.Writer,
    pos: u64 = 0,

    pub fn init(inner: *std.Io.Writer, buffer: []u8) CountingWriter {
        return .{
            .inner = inner,
            .interface = .{
                .vtable = &.{
                    .drain = drainFn,
                },
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @fieldParentPtr("interface", w);
        const n = try self.inner.vtable.drain(self.inner, data, splat);
        progress_state += n;
        self.pos += n;
        return n;
    }

    pub fn logicalPos(self: *const CountingWriter) u64 {
        return self.pos;
    }
};
