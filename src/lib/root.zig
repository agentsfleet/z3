//! Shared AWS primitives for aws_zig service modules.
const std = @import("std");

pub const internal = @import("internal.zig");
pub const signing = @import("signing.zig");
pub const sts = @import("sts.zig");

test {
    _ = internal;
    _ = signing;
    _ = sts;
}
