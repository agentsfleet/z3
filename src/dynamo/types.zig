const std = @import("std");
const Allocator = std.mem.Allocator;
const attr = @import("attr.zig");

pub const RequestOptions = struct {
    max_body_size: usize = 16 * 1024 * 1024,
    /// Max attempts for the whole request (connect, send, receive, and
    /// retryable DynamoDB/HTTP failures such as throttling and 5xx).
    max_attempts: usize = 3,
    /// Base backoff in milliseconds before the first retry; doubles each
    /// attempt with random jitter. Non-negative; multiplied with saturation
    /// so extreme values cannot overflow into a negative sleep.
    initial_retry_time: u64 = 100,
};

pub const GetOptions = struct {
    request: RequestOptions = .{},
    consistent_read: bool = false,
};

pub const PutOptions = struct {
    request: RequestOptions = .{},
};

pub const DeleteOptions = struct {
    request: RequestOptions = .{},
};

/// One entry for DynamoDB `ExpressionAttributeNames` (`#placeholder` → name).
pub const ExpressionName = struct {
    /// Placeholder including the leading `#`, e.g. `#pk`.
    key: []const u8,
    /// Real attribute name, e.g. `customer_id`.
    name: []const u8,
};

/// One entry for DynamoDB `ExpressionAttributeValues` (`:placeholder` → AttributeValue).
pub const ExpressionValue = struct {
    /// Placeholder including the leading `:`, e.g. `:pk`.
    key: []const u8,
    /// Pre-encoded AttributeValue JSON fragment, e.g. `{"S":"acme"}`.
    /// Build with `attr.encodeValue` / `zdb.encodeValue`.
    value_json: []const u8,
};

pub const QueryOptions = struct {
    request: RequestOptions = .{},
    /// Full KeyConditionExpression, e.g. `"#pk = :pk AND begins_with(#sk, :sk)"`.
    /// Required for `Client.query`. Unused by `queryHash`.
    key_condition: ?[]const u8 = null,
    /// ExpressionAttributeNames for `#…` placeholders in `key_condition`
    /// (and any future filter expressions).
    expression_attribute_names: []const ExpressionName = &.{},
    /// ExpressionAttributeValues for `:…` placeholders. Each `value_json`
    /// must be a full AttributeValue object JSON (see `ExpressionValue`).
    expression_attribute_values: []const ExpressionValue = &.{},
    /// ExclusiveStartKey as already-encoded item JSON object (without outer wrapper)
    exclusive_start_key_json: ?[]const u8 = null,
    limit: ?u32 = null,
    scan_index_forward: bool = true,
    index_name: ?[]const u8 = null,
    consistent_read: bool = false,
};

pub fn ResultsPage(comptime T: type) type {
    return struct {
        items: []T,
        /// Raw JSON object for LastEvaluatedKey, or null if no more pages.
        last_evaluated_key_json: ?[]u8,
        allocator: Allocator,

        pub fn deinit(self: *@This()) void {
            for (self.items) |*item| {
                attr.free(self.allocator, item);
            }
            self.allocator.free(self.items);
            if (self.last_evaluated_key_json) |lek| {
                self.allocator.free(lek);
            }
        }
    };
}

pub const ServiceError = error{
    ResourceNotFound,
    ResourceInUse,
    ConditionalCheckFailed,
    ValidationException,
    AccessDenied,
    ProvisionedThroughputExceeded,
    RequestLimitExceeded,
    InternalServerError,
    DynamoDbError,
};
