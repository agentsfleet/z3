//! Minimal async DynamoDB client for Zig 0.17+.
//!
//! Types and options live here; operation implementations are in `ops.zig`.
const std = @import("std");
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const attr = @import("attr.zig");
const types = @import("types.zig");
const request = @import("http/request.zig");
const sts = @import("auth/sts.zig");
const ops = @import("ops.zig");

pub const Client = @This();

pub const Config = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
    region: []const u8 = "us-east-1",
    /// Custom endpoint (DynamoDB Local, LocalStack, etc.)
    endpoint: ?[]const u8 = null,

    pub fn fromEnvMap(env_map: *const std.process.Environ.Map) error{MissingAwsCredentials}!Config {
        const access_key_id = env_map.get("AWS_ACCESS_KEY_ID") orelse return error.MissingAwsCredentials;
        const secret_access_key = env_map.get("AWS_SECRET_ACCESS_KEY") orelse return error.MissingAwsCredentials;

        return .{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .session_token = env_map.get("AWS_SESSION_TOKEN"),
            .region = env_map.get("AWS_REGION") orelse env_map.get("AWS_DEFAULT_REGION") orelse "us-east-1",
            // Prefer DynamoDB-specific, then floci/LocalStack-style global endpoint.
            .endpoint = env_map.get("DYNAMODB_ENDPOINT") orelse
                env_map.get("AWS_ENDPOINT_URL_DYNAMODB") orelse
                env_map.get("AWS_ENDPOINT_URL"),
        };
    }

    pub fn fromStsCredentials(credentials: *const sts.Credentials, region: []const u8) Config {
        return .{
            .access_key_id = credentials.access_key_id,
            .secret_access_key = credentials.secret_access_key,
            .session_token = credentials.session_token,
            .region = region,
        };
    }

    pub fn toRequestConfig(self: Config) request.ClientConfig {
        return .{
            .access_key_id = self.access_key_id,
            .secret_access_key = self.secret_access_key,
            .session_token = self.session_token,
            .region = self.region,
            .endpoint = self.endpoint,
        };
    }
};

pub const InitOptions = struct {
    http_client: ?*http.Client = null,
    io: ?Io = null,
};

pub const Error = error{
    IoRequired,
    DynamoDbError,
};

pub const RequestError = Error || request.RequestError || attr.EncodeError || attr.DecodeError || types.ServiceError || error{
    InvalidResponse,
    MissingKeyCondition,
};

pub const KeyAttribute = struct {
    name: []const u8,
    /// DynamoDB scalar type: "S", "N", or "B".
    attr_type: []const u8 = "S",
};

pub const ProjectionType = enum {
    all,
    keys_only,
    include,

    pub fn asJson(self: ProjectionType) []const u8 {
        return switch (self) {
            .all => "ALL",
            .keys_only => "KEYS_ONLY",
            .include => "INCLUDE",
        };
    }
};

/// Global or local secondary index definition for `createTable`.
///
/// - **GSI**: `hash_key` may be any attribute; optional `range_key`.
/// - **LSI**: DynamoDB requires the hash key to match the table hash key;
///   only the range key differs. Pass the table hash as `hash_key`.
pub const SecondaryIndex = struct {
    name: []const u8,
    hash_key: KeyAttribute,
    range_key: ?KeyAttribute = null,
    projection: ProjectionType = .all,
    /// Only used when `projection == .include`.
    non_key_attributes: []const []const u8 = &.{},
};

pub const CreateTableOptions = struct {
    request: types.RequestOptions = .{},
    hash_key: KeyAttribute,
    range_key: ?KeyAttribute = null,
    billing_mode: []const u8 = "PAY_PER_REQUEST",
    global_secondary_indexes: []const SecondaryIndex = &.{},
    local_secondary_indexes: []const SecondaryIndex = &.{},
    /// When true (default), existing table is not an error.
    ignore_if_exists: bool = true,
};

pub const DeleteTableOptions = struct {
    request: types.RequestOptions = .{},
    /// When true (default), missing table is not an error.
    ignore_if_missing: bool = true,
};

// ── operations (implemented in ops.zig) ──────────────────────────────

pub const init = ops.init;
pub const deinit = ops.deinit;
pub const createTable = ops.createTable;
pub const deleteTable = ops.deleteTable;
pub const put = ops.put;
pub const get = ops.get;
pub const delete = ops.delete;
pub const queryHash = ops.queryHash;
pub const query = ops.query;

allocator: Allocator,
http_client: *http.Client,
owns_http_client: bool,
config: Config,

test {
    _ = @import("ops.zig");
    _ = @import("http/request.zig");
    _ = @import("auth/signing.zig");
    _ = @import("internal.zig");
    _ = @import("attr.zig");
}

test "Config.fromEnvMap reads credentials and optional endpoint" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "ak");
    try env.put("AWS_SECRET_ACCESS_KEY", "sk");
    try env.put("AWS_SESSION_TOKEN", "tok");
    try env.put("AWS_REGION", "eu-west-1");
    try env.put("DYNAMODB_ENDPOINT", "http://localhost:8000");

    const config = try Config.fromEnvMap(&env);
    try std.testing.expectEqualStrings("ak", config.access_key_id);
    try std.testing.expectEqualStrings("sk", config.secret_access_key);
    try std.testing.expectEqualStrings("tok", config.session_token.?);
    try std.testing.expectEqualStrings("eu-west-1", config.region);
    try std.testing.expectEqualStrings("http://localhost:8000", config.endpoint.?);
}

test "Config.fromEnvMap falls back to AWS_ENDPOINT_URL" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "test");
    try env.put("AWS_SECRET_ACCESS_KEY", "test");
    try env.put("AWS_ENDPOINT_URL", "http://localhost.floci.io:4566");

    const config = try Config.fromEnvMap(&env);
    try std.testing.expectEqualStrings("http://localhost.floci.io:4566", config.endpoint.?);
}

test "Config.fromEnvMap requires keys" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.MissingAwsCredentials, Config.fromEnvMap(&env));
}
