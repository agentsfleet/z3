const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const internal = @import("../internal.zig");

pub const Error = error{
    CredentialFetchFailed,
    InvalidStsResponse,
    InvalidUri,
    ConnectionFailed,
    SendFailed,
    FlushFailed,
    ReceiveFailed,
    ReadFailed,
    WriteFailed,
};

pub const AssumeRoleWithWebIdentityOptions = struct {
    role_arn: []const u8,
    web_identity_token_file: []const u8,
    role_session_name: []const u8 = "z3-session",
    region: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    max_body_size: usize = 1024 * 1024,
};

pub const Credentials = struct {
    access_key_id: []u8,
    secret_access_key: []u8,
    session_token: []u8,
    expiration: ?[]u8,
    allocator: Allocator,

    pub fn deinit(self: *Credentials) void {
        self.allocator.free(self.access_key_id);
        self.allocator.free(self.secret_access_key);
        self.allocator.free(self.session_token);
        if (self.expiration) |expiration| self.allocator.free(expiration);
    }
};

const ParsedCredentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: []const u8,
    expiration: ?[]const u8,
};

pub fn assumeRoleWithWebIdentity(
    allocator: Allocator,
    io: Io,
    options: AssumeRoleWithWebIdentityOptions,
) (Error || Allocator.Error)!Credentials {
    const token = try readFileTrimmed(allocator, io, options.web_identity_token_file);
    defer allocator.free(token);

    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    return assumeRoleWithWebIdentityToken(allocator, &client, options, token);
}

fn assumeRoleWithWebIdentityToken(
    allocator: Allocator,
    client: *http.Client,
    options: AssumeRoleWithWebIdentityOptions,
    token: []const u8,
) (Error || Allocator.Error)!Credentials {
    const endpoint = try stsEndpoint(allocator, options);
    defer if (options.endpoint == null and options.region != null) allocator.free(endpoint);

    const form = try assumeRoleWithWebIdentityForm(allocator, options, token);
    defer allocator.free(form);

    const uri = std.Uri.parse(endpoint) catch return error.InvalidUri;
    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/xml" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var req = client.request(.POST, uri, .{ .extra_headers = &headers }) catch return error.ConnectionFailed;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = form.len };
    var body_writer = req.sendBody(&.{}) catch return error.SendFailed;
    body_writer.writer.writeAll(form) catch return error.WriteFailed;
    body_writer.end() catch return error.WriteFailed;
    req.connection.?.flush() catch return error.FlushFailed;

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;
    if (response.head.status.class() != .success) return error.CredentialFetchFailed;

    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    const body = reader.allocRemaining(allocator, Io.Limit.limited(options.max_body_size)) catch return error.ReadFailed;
    defer allocator.free(body);

    return parseCredentialsOwned(allocator, body);
}

fn stsEndpoint(allocator: Allocator, options: AssumeRoleWithWebIdentityOptions) Allocator.Error![]const u8 {
    if (options.endpoint) |endpoint| return endpoint;
    if (options.region) |region| {
        return std.fmt.allocPrint(allocator, "https://sts.{s}.amazonaws.com/", .{region});
    }
    return "https://sts.amazonaws.com/";
}

fn assumeRoleWithWebIdentityForm(
    allocator: Allocator,
    options: AssumeRoleWithWebIdentityOptions,
    token: []const u8,
) Allocator.Error![]u8 {
    const role_arn = try internal.encodeQueryValue(allocator, options.role_arn);
    defer allocator.free(role_arn);
    const session_name = try internal.encodeQueryValue(allocator, options.role_session_name);
    defer allocator.free(session_name);
    const encoded_token = try internal.encodeQueryValue(allocator, token);
    defer allocator.free(encoded_token);

    return std.fmt.allocPrint(
        allocator,
        "Action=AssumeRoleWithWebIdentity&Version=2011-06-15&RoleArn={s}&RoleSessionName={s}&WebIdentityToken={s}",
        .{ role_arn, session_name, encoded_token },
    );
}

fn readFileTrimmed(allocator: Allocator, io: Io, path: []const u8) (Error || Allocator.Error)![]u8 {
    const file = (if (std.Io.Dir.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only })
    else
        std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only })) catch
        return error.CredentialFetchFailed;
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &buffer);
    const raw = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch
        return error.CredentialFetchFailed;
    errdefer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return raw;

    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return copy;
}

fn parseCredentialsOwned(allocator: Allocator, body: []const u8) (Error || Allocator.Error)!Credentials {
    const parsed = parseCredentials(body) orelse return error.InvalidStsResponse;

    const access_key_id = try allocator.dupe(u8, parsed.access_key_id);
    errdefer allocator.free(access_key_id);
    const secret_access_key = try allocator.dupe(u8, parsed.secret_access_key);
    errdefer allocator.free(secret_access_key);
    const session_token = try allocator.dupe(u8, parsed.session_token);
    errdefer allocator.free(session_token);
    const expiration = if (parsed.expiration) |value| try allocator.dupe(u8, value) else null;
    errdefer if (expiration) |value| allocator.free(value);

    return .{
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = session_token,
        .expiration = expiration,
        .allocator = allocator,
    };
}

fn parseCredentials(body: []const u8) ?ParsedCredentials {
    return .{
        .access_key_id = extractXmlTag(body, "AccessKeyId") orelse return null,
        .secret_access_key = extractXmlTag(body, "SecretAccessKey") orelse return null,
        .session_token = extractXmlTag(body, "SessionToken") orelse return null,
        .expiration = extractXmlTag(body, "Expiration"),
    };
}

fn extractXmlTag(body: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const start = (std.mem.indexOf(u8, body, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, body, start, close) orelse return null;
    return body[start..end];
}

test "assumeRoleWithWebIdentityForm encodes fields" {
    const form = try assumeRoleWithWebIdentityForm(std.testing.allocator, .{
        .role_arn = "arn:aws:iam::123456789012:role/a role",
        .web_identity_token_file = "unused",
        .role_session_name = "z3/session",
    }, "token+/=");
    defer std.testing.allocator.free(form);

    try std.testing.expect(std.mem.indexOf(u8, form, "Action=AssumeRoleWithWebIdentity") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "RoleArn=arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2Fa%20role") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "RoleSessionName=z3%2Fsession") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "WebIdentityToken=token%2B%2F%3D") != null);
}

test "parseCredentials extracts STS credential fields" {
    const body =
        "<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials>" ++
        "<AccessKeyId>AKIDEXAMPLE</AccessKeyId><SecretAccessKey>secret</SecretAccessKey>" ++
        "<SessionToken>token</SessionToken><Expiration>2030-01-01T00:00:00Z</Expiration>" ++
        "</Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>";

    var credentials = try parseCredentialsOwned(std.testing.allocator, body);
    defer credentials.deinit();

    try std.testing.expectEqualStrings("AKIDEXAMPLE", credentials.access_key_id);
    try std.testing.expectEqualStrings("secret", credentials.secret_access_key);
    try std.testing.expectEqualStrings("token", credentials.session_token);
    try std.testing.expectEqualStrings("2030-01-01T00:00:00Z", credentials.expiration.?);
}

test "parseCredentials rejects missing session token" {
    const body =
        "<Credentials><AccessKeyId>AKIDEXAMPLE</AccessKeyId>" ++
        "<SecretAccessKey>secret</SecretAccessKey></Credentials>";

    try std.testing.expectError(error.InvalidStsResponse, parseCredentialsOwned(std.testing.allocator, body));
}
