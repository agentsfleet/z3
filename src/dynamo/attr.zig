//! Comptime AttributeValue encode/decode for DynamoDB items.
//! Field names on Zig structs become DynamoDB attribute names.
//! Targets Zig 0.17+ (`Type.Struct` uses field_names / field_types / field_attrs).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EncodeError = error{UnsupportedType} || Allocator.Error;

pub const DecodeError = error{
    MissingAttribute,
    InvalidAttributeValue,
    TypeMismatch,
    UnsupportedType,
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

/// Encode a Zig value as a DynamoDB AttributeValue JSON fragment
/// (e.g. `{"S":"hi"}`, `{"N":"1"}`, `{"M":{...}}`).
pub fn encodeValue(allocator: Allocator, value: anytype) EncodeError![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try writeValue(&list, allocator, value);
    return list.toOwnedSlice(allocator);
}

/// Encode a struct as a DynamoDB item attribute map JSON object:
/// `{"field":{"S":"..."},"n":{"N":"1"}}`.
/// Optional fields that are null are omitted.
pub fn encodeItem(allocator: Allocator, value: anytype) EncodeError![]u8 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("encodeItem expects a struct");
    if (info.@"struct".is_tuple) @compileError("encodeItem expects a named struct");

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '{');
    var first = true;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, FieldType| {
        const field_value = @field(value, field_name);
        const include = if (comptime isOptional(FieldType)) field_value != null else true;
        if (include) {
            if (!first) try list.append(allocator, ',');
            first = false;
            try writeJsonString(&list, allocator, field_name);
            try list.append(allocator, ':');
            if (comptime isOptional(FieldType)) {
                try writeValue(&list, allocator, field_value.?);
            } else {
                try writeValue(&list, allocator, field_value);
            }
        }
    }
    try list.append(allocator, '}');
    return list.toOwnedSlice(allocator);
}

/// Decode a DynamoDB item attribute map (JSON object of AttributeValues) into T.
/// String fields are allocated with `allocator`; call `free(allocator, &value)` when done.
pub fn decodeItem(allocator: Allocator, comptime T: type, item_obj: std.json.Value) DecodeError!T {
    if (item_obj != .object) return error.TypeMismatch;
    return decodeStruct(allocator, T, item_obj.object);
}

/// Free heap data owned by a value produced by `decodeItem` / client get/query.
///
/// Ownership contract: every pointer/slice field on a decoded value is
/// allocator-owned (including values that came from struct field defaults;
/// defaults are duplicated during decode). Call this exactly once per
/// successfully decoded item (or use `ResultsPage.deinit`).
pub fn free(allocator: Allocator, value: anytype) void {
    freeValue(allocator, value.*);
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn writeValue(list: *std.ArrayList(u8), allocator: Allocator, value: anytype) EncodeError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => {
            try list.appendSlice(allocator, if (value) "{\"BOOL\":true}" else "{\"BOOL\":false}");
        },
        .int, .comptime_int => {
            var buf: [64]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.UnsupportedType;
            try list.appendSlice(allocator, "{\"N\":\"");
            try list.appendSlice(allocator, n);
            try list.appendSlice(allocator, "\"}");
        },
        .float, .comptime_float => {
            var buf: [64]u8 = undefined;
            const n = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.UnsupportedType;
            try list.appendSlice(allocator, "{\"N\":\"");
            try list.appendSlice(allocator, n);
            try list.appendSlice(allocator, "\"}");
        },
        .@"enum" => {
            try list.appendSlice(allocator, "{\"S\":\"");
            try writeEscaped(list, allocator, @tagName(value));
            try list.appendSlice(allocator, "\"}");
        },
        .optional => {
            if (value) |inner| {
                try writeValue(list, allocator, inner);
            } else {
                try list.appendSlice(allocator, "{\"NULL\":true}");
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try list.appendSlice(allocator, "{\"S\":\"");
                try writeEscaped(list, allocator, value);
                try list.appendSlice(allocator, "\"}");
            } else if (ptr.size == .slice) {
                try list.appendSlice(allocator, "{\"L\":[");
                for (value, 0..) |elem, i| {
                    if (i > 0) try list.append(allocator, ',');
                    try writeValue(list, allocator, elem);
                }
                try list.appendSlice(allocator, "]}");
            } else if (ptr.size == .one) {
                // String literals are `*const [N:0]u8`
                const Child = ptr.child;
                if (@typeInfo(Child) == .array and @typeInfo(Child).array.child == u8) {
                    try list.appendSlice(allocator, "{\"S\":\"");
                    try writeEscaped(list, allocator, value);
                    try list.appendSlice(allocator, "\"}");
                } else {
                    try writeValue(list, allocator, value.*);
                }
            } else {
                return error.UnsupportedType;
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try list.appendSlice(allocator, "{\"S\":\"");
                try writeEscaped(list, allocator, &value);
                try list.appendSlice(allocator, "\"}");
            } else {
                try list.appendSlice(allocator, "{\"L\":[");
                for (value, 0..) |elem, i| {
                    if (i > 0) try list.append(allocator, ',');
                    try writeValue(list, allocator, elem);
                }
                try list.appendSlice(allocator, "]}");
            }
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                try list.appendSlice(allocator, "{\"L\":[");
                inline for (s.field_names, 0..) |field_name, i| {
                    if (i > 0) try list.append(allocator, ',');
                    try writeValue(list, allocator, @field(value, field_name));
                }
                try list.appendSlice(allocator, "]}");
            } else {
                try list.appendSlice(allocator, "{\"M\":");
                const nested = try encodeItem(allocator, value);
                defer allocator.free(nested);
                try list.appendSlice(allocator, nested);
                try list.append(allocator, '}');
            }
        },
        else => return error.UnsupportedType,
    }
}

fn writeJsonString(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try list.append(allocator, '"');
    try writeEscaped(list, allocator, s);
    try list.append(allocator, '"');
}

fn writeEscaped(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try list.appendSlice(allocator, hex);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

fn decodeStruct(allocator: Allocator, comptime T: type, obj: std.json.ObjectMap) DecodeError!T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("decodeItem expects a struct type");
    if (info.@"struct".is_tuple) @compileError("decodeItem expects a named struct");

    var result: T = undefined;
    // Only free fields that were successfully written (prefix of the field list).
    var fields_set: usize = 0;
    errdefer {
        inline for (info.@"struct".field_names, 0..) |field_name, i| {
            if (i < fields_set) freeValue(allocator, @field(result, field_name));
        }
    }

    inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs) |field_name, FieldType, field_attrs| {
        const maybe = obj.get(field_name);
        if (maybe) |av| {
            @field(result, field_name) = try decodeField(allocator, FieldType, av);
        } else if (comptime isOptional(FieldType)) {
            @field(result, field_name) = null;
        } else if (comptime field_attrs.defaultValue(FieldType)) |default| {
            // Duplicate pointer/slice defaults so free() never releases static memory.
            @field(result, field_name) = try cloneOwned(allocator, default);
        } else {
            return error.MissingAttribute;
        }
        fields_set += 1;
    }
    return result;
}

/// Deep-copy values that carry allocator-owned pointer/slice data so that
/// static defaults (e.g. `name: []const u8 = "unknown"`) become owned.
fn cloneOwned(allocator: Allocator, value: anytype) DecodeError!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| return try cloneOwned(allocator, inner);
            return null;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return try allocator.dupe(u8, value);
            } else if (ptr.size == .slice) {
                const out = try allocator.alloc(ptr.child, value.len);
                var initialized: usize = 0;
                errdefer {
                    for (out[0..initialized]) |*elem| freeValue(allocator, elem.*);
                    allocator.free(out);
                }
                for (value, 0..) |elem, i| {
                    out[i] = try cloneOwned(allocator, elem);
                    initialized = i + 1;
                }
                return out;
            } else if (ptr.size == .one) {
                // Always heap-allocate so freeValue's destroy never hits static memory
                // (e.g. `name: *const [7:0]u8 = "unknown"`).
                const Child = ptr.child;
                const heap = try allocator.create(Child);
                errdefer allocator.destroy(heap);
                if (comptime @typeInfo(Child) == .array) {
                    // Byte / element arrays: shallow copy of the array storage, then
                    // deep-clone any nested owned elements if needed via per-element clone.
                    if (comptime @typeInfo(Child).array.child == u8) {
                        heap.* = value.*;
                    } else {
                        heap.* = try cloneOwned(allocator, value.*);
                    }
                } else {
                    heap.* = try cloneOwned(allocator, value.*);
                }
                return heap;
            }
            return value;
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                var out: T = undefined;
                var fields_set: usize = 0;
                errdefer {
                    inline for (s.field_names, 0..) |field_name, i| {
                        if (i < fields_set) freeValue(allocator, @field(out, field_name));
                    }
                }
                inline for (s.field_names) |field_name| {
                    @field(out, field_name) = try cloneOwned(allocator, @field(value, field_name));
                    fields_set += 1;
                }
                return out;
            }
            var out: T = undefined;
            var fields_set: usize = 0;
            errdefer {
                inline for (s.field_names, 0..) |field_name, i| {
                    if (i < fields_set) freeValue(allocator, @field(out, field_name));
                }
            }
            inline for (s.field_names) |field_name| {
                @field(out, field_name) = try cloneOwned(allocator, @field(value, field_name));
                fields_set += 1;
            }
            return out;
        },
        .array => {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |*elem| freeValue(allocator, elem.*);
            }
            for (value, 0..) |elem, i| {
                out[i] = try cloneOwned(allocator, elem);
                initialized = i + 1;
            }
            return out;
        },
        else => return value,
    }
}

fn decodeField(allocator: Allocator, comptime T: type, av: std.json.Value) DecodeError!T {
    if (comptime isOptional(T)) {
        const Child = @typeInfo(T).optional.child;
        if (av == .object) {
            if (av.object.get("NULL")) |n| {
                if (n == .bool and n.bool) return null;
            }
        }
        return try decodeField(allocator, Child, av);
    }

    if (av != .object) return error.InvalidAttributeValue;
    const map = av.object;

    switch (@typeInfo(T)) {
        .bool => {
            const v = map.get("BOOL") orelse return error.TypeMismatch;
            if (v != .bool) return error.TypeMismatch;
            return v.bool;
        },
        .int => {
            const v = map.get("N") orelse return error.TypeMismatch;
            if (v != .string) return error.TypeMismatch;
            return std.fmt.parseInt(T, v.string, 10) catch return error.InvalidAttributeValue;
        },
        .float => {
            const v = map.get("N") orelse return error.TypeMismatch;
            if (v != .string) return error.TypeMismatch;
            return std.fmt.parseFloat(T, v.string) catch return error.InvalidAttributeValue;
        },
        .@"enum" => {
            const v = map.get("S") orelse return error.TypeMismatch;
            if (v != .string) return error.TypeMismatch;
            return std.meta.stringToEnum(T, v.string) orelse return error.InvalidAttributeValue;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const v = map.get("S") orelse return error.TypeMismatch;
                if (v != .string) return error.TypeMismatch;
                return try allocator.dupe(u8, v.string);
            } else if (ptr.size == .slice) {
                const v = map.get("L") orelse return error.TypeMismatch;
                if (v != .array) return error.TypeMismatch;
                const out = try allocator.alloc(ptr.child, v.array.items.len);
                // Only free elements that were successfully initialized (same
                // pattern as queryExecute / ResultsPage cleanup).
                var initialized: usize = 0;
                errdefer {
                    for (out[0..initialized]) |*elem| freeValue(allocator, elem.*);
                    allocator.free(out);
                }
                for (v.array.items, 0..) |elem, i| {
                    out[i] = try decodeField(allocator, ptr.child, elem);
                    initialized = i + 1;
                }
                return out;
            }
            return error.UnsupportedType;
        },
        .@"struct" => {
            const v = map.get("M") orelse return error.TypeMismatch;
            if (v != .object) return error.TypeMismatch;
            return try decodeStruct(allocator, T, v.object);
        },
        else => return error.UnsupportedType,
    }
}

fn freeValue(allocator: Allocator, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| freeValue(allocator, inner);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                allocator.free(value);
            } else if (ptr.size == .slice) {
                for (value) |elem| freeValue(allocator, elem);
                allocator.free(value);
            } else if (ptr.size == .one) {
                freeValue(allocator, value.*);
                allocator.destroy(value);
            }
        },
        .@"struct" => |s| {
            inline for (s.field_names) |field_name| {
                freeValue(allocator, @field(value, field_name));
            }
        },
        .array => {
            for (value) |elem| freeValue(allocator, elem);
        },
        else => {},
    }
}

// ── tests ────────────────────────────────────────────────────────────

test "encodeItem scalars and optional omit" {
    const Item = struct {
        pk: []const u8,
        total: i64,
        active: bool,
        note: ?[]const u8 = null,
    };

    const json = try encodeItem(std.testing.allocator, Item{
        .pk = "user#1",
        .total = 42,
        .active = true,
        .note = null,
    });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"pk\":{\"S\":\"user#1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":{\"N\":\"42\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\":{\"BOOL\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "note") == null);
}

test "encodeItem includes optional when set" {
    const Item = struct {
        pk: []const u8,
        note: ?[]const u8 = null,
    };
    const json = try encodeItem(std.testing.allocator, Item{ .pk = "a", .note = "hi\"there" });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"note\":{\"S\":\"hi\\\"there\"}") != null);
}

test "encodeItem nested map and list" {
    const Nested = struct { x: i32 };
    const Item = struct {
        tags: []const []const u8,
        meta: Nested,
    };
    const tags = [_][]const u8{ "a", "b" };
    const json = try encodeItem(std.testing.allocator, Item{
        .tags = &tags,
        .meta = .{ .x = 7 },
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tags\":{\"L\":[{\"S\":\"a\"},{\"S\":\"b\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"meta\":{\"M\":{\"x\":{\"N\":\"7\"}}}") != null);
}

test "decodeItem round trip" {
    const Item = struct {
        pk: []const u8,
        sk: []const u8,
        total: i64,
        active: bool,
        note: ?[]const u8 = null,
    };

    const encoded = try encodeItem(std.testing.allocator, Item{
        .pk = "p1",
        .sk = "s1",
        .total = 99,
        .active = false,
        .note = "n",
    });
    defer std.testing.allocator.free(encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    var item = try decodeItem(std.testing.allocator, Item, parsed.value);
    defer free(std.testing.allocator, &item);

    try std.testing.expectEqualStrings("p1", item.pk);
    try std.testing.expectEqualStrings("s1", item.sk);
    try std.testing.expectEqual(@as(i64, 99), item.total);
    try std.testing.expectEqual(false, item.active);
    try std.testing.expectEqualStrings("n", item.note.?);
}

test "decodeItem missing optional is null" {
    const Item = struct {
        pk: []const u8,
        note: ?[]const u8 = null,
    };
    const raw = "{\"pk\":{\"S\":\"only\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    var item = try decodeItem(std.testing.allocator, Item, parsed.value);
    defer free(std.testing.allocator, &item);
    try std.testing.expectEqualStrings("only", item.pk);
    try std.testing.expect(item.note == null);
}

test "encodeValue string" {
    const json = try encodeValue(std.testing.allocator, "hello");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"S\":\"hello\"}", json);
}

test "decodeItem applies and owns pointer field defaults" {
    const Item = struct {
        pk: []const u8,
        name: []const u8 = "unknown",
    };
    const raw = "{\"pk\":{\"S\":\"only\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    var item = try decodeItem(std.testing.allocator, Item, parsed.value);
    defer free(std.testing.allocator, &item);
    try std.testing.expectEqualStrings("only", item.pk);
    try std.testing.expectEqualStrings("unknown", item.name);
    // Must not share storage with the static default literal.
    try std.testing.expect(item.name.ptr != "unknown".ptr);
}

test "decodeItem owns single-pointer array string defaults" {
    const Item = struct {
        pk: []const u8,
        // String-literal field shape: *const [N:0]u8; must heap-copy for free().
        label: *const [7:0]u8 = "unknown",
    };
    const raw = "{\"pk\":{\"S\":\"only\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    var item = try decodeItem(std.testing.allocator, Item, parsed.value);
    defer free(std.testing.allocator, &item);
    try std.testing.expectEqualStrings("only", item.pk);
    try std.testing.expectEqualStrings("unknown", item.label);
    // Heap copy must not alias the static string-literal pointer.
    try std.testing.expect(@intFromPtr(item.label) != @intFromPtr("unknown"));
}

test "decodeItem frees partial struct on later field failure" {
    const Item = struct {
        pk: []const u8,
        total: i64,
    };
    // pk ok, total has wrong type → MissingAttribute/TypeMismatch after pk alloc
    const raw = "{\"pk\":{\"S\":\"p1\"},\"total\":{\"S\":\"not-a-number\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.TypeMismatch, decodeItem(std.testing.allocator, Item, parsed.value));
}

test "decodeItem slice list frees only initialized prefix on error" {
    const Item = struct {
        tags: []const []const u8,
    };
    // Second list element is wrong type → first string must be freed, not free(uninit).
    const raw = "{\"tags\":{\"L\":[{\"S\":\"a\"},{\"N\":\"1\"}]}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.TypeMismatch, decodeItem(std.testing.allocator, Item, parsed.value));
}

test "decodeItem missing required field after owned field does not leak" {
    const Item = struct {
        pk: []const u8,
        sk: []const u8,
    };
    const raw = "{\"pk\":{\"S\":\"p1\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.MissingAttribute, decodeItem(std.testing.allocator, Item, parsed.value));
}
