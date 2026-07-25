//! Minimal DynamoDB client for Zig
const std = @import("std");
const lib = @import("lib");

pub const Client = @import("client.zig").Client;
pub const types = @import("types.zig");
pub const attr = @import("attr.zig");
pub const sts = lib.sts;

pub const free = attr.free;
pub const encodeItem = attr.encodeItem;
pub const encodeValue = attr.encodeValue;
pub const decodeItem = attr.decodeItem;

pub const RequestOptions = types.RequestOptions;
pub const GetOptions = types.GetOptions;
pub const PutOptions = types.PutOptions;
pub const DeleteOptions = types.DeleteOptions;
pub const QueryOptions = types.QueryOptions;
pub const ExpressionName = types.ExpressionName;
pub const ExpressionValue = types.ExpressionValue;
pub const ResultsPage = types.ResultsPage;

test {
    _ = @import("client.zig");
    _ = @import("ops.zig");
    _ = @import("attr.zig");
    _ = @import("types.zig");
    _ = @import("http/request.zig");
    _ = sts;
    _ = lib;
}
