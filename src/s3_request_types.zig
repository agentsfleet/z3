const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const ProgressState = @import("s3_request.zig").ProgressState;

pub const UnifiedRequest = struct {
    allocator: Allocator,
    http_method: http.Method,
    url: []u8,
    headers: []http.Header,
    body: []const u8,
    content_length: usize,
    max_body_size: usize,
    is_bodiless: bool,
    max_attempts: usize,
    initial_retry_time: i64,
    req_progress: ?*ProgressState,
    req_drain_fn: ?*const fn (w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize = null,

    pub fn deinit(self: *UnifiedRequest) void {
        self.allocator.free(self.url);
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
    }
};
