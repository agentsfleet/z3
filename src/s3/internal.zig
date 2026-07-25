const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

pub fn toLowerAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    for (input, 0..) |ch, i| {
        out[i] = std.ascii.toLower(ch);
    }
    return out;
}

fn isUnreserved(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or byte == '_' or byte == '.' or byte == '~';
}

fn percentEncode(allocator: Allocator, raw: []const u8, allow_slash: bool) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";

    for (raw) |byte| {
        if (isUnreserved(byte) or (allow_slash and byte == '/')) {
            try out.append(allocator, byte);
            continue;
        }
        try out.append(allocator, '%');
        try out.append(allocator, hex[byte >> 4]);
        try out.append(allocator, hex[byte & 0x0f]);
    }

    return out.toOwnedSlice(allocator);
}

pub fn encodePath(allocator: Allocator, raw: []const u8) ![]u8 {
    return percentEncode(allocator, raw, true);
}

pub fn encodeQueryValue(allocator: Allocator, raw: []const u8) ![]u8 {
    return percentEncode(allocator, raw, false);
}

pub fn getUnixTimestamp() i64 {
    var tv: std.posix.system.timeval = undefined;
    _ = std.posix.system.gettimeofday(&tv, null);
    return tv.sec;
}

pub fn formatAmzDate(timestamp: i64, buf: *[16]u8) void {
    const epoch_seconds: u64 = @intCast(timestamp);
    const epoch_day = epoch_seconds / 86400;
    const day_seconds = epoch_seconds % 86400;

    var year: u32 = 1970;
    var remaining_days: u64 = epoch_day;

    while (true) {
        const days_in_year: u32 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const month_days = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (month_days) |days| {
        if (remaining_days < days) break;
        remaining_days -= days;
        month += 1;
    }
    const day: u32 = @intCast(remaining_days + 1);

    const hour: u32 = @intCast(day_seconds / 3600);
    const minute: u32 = @intCast(@mod(day_seconds, 3600) / 60);
    const second: u32 = @intCast(day_seconds % 60);

    _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year, month, day, hour, minute, second,
    }) catch unreachable;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

pub fn sha256Hex(data: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    bytesToHex(&hash, out);
}

pub fn bytesToHex(bytes: []const u8, out: *[64]u8) void {
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = charset[byte >> 4];
        out[i * 2 + 1] = charset[byte & 0x0f];
    }
}

test "encodePath keeps slashes and encodes reserved bytes" {
    const encoded = try encodePath(std.testing.allocator, "a/b c?d");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a/b%20c%3Fd", encoded);
}

test "encodePath escapes percent" {
    const encoded = try encodePath(std.testing.allocator, "a%b");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%25b", encoded);
}

test "encodeQueryValue escapes separators" {
    const encoded = try encodeQueryValue(std.testing.allocator, "a/b c&d");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%2Fb%20c%26d", encoded);
}

test "encodeQueryValue escapes percent" {
    const encoded = try encodeQueryValue(std.testing.allocator, "a%b");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%25b", encoded);
}
