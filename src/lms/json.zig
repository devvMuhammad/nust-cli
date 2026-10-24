//! Lenient readers over `std.json.Value`: Moodle sends flags as 0/1 or true/false, ids as
//! numbers or strings, and omits fields freely.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}

pub fn str(v: Value, key: []const u8) []const u8 {
    const x = get(v, key) orelse return "";
    return if (x == .string) x.string else "";
}

pub fn int(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .bool => |b| @intFromBool(b),
        else => null,
    };
}

/// A Unix time; Moodle uses 0 for "no date".
pub fn time(v: Value, key: []const u8) ?i64 {
    const t = int(v, key) orelse return null;
    return if (t > 0) t else null;
}

pub fn flag(v: Value, key: []const u8, default: bool) bool {
    const x = get(v, key) orelse return default;
    return switch (x) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| !(std.mem.eql(u8, s, "0") or s.len == 0),
        else => default,
    };
}

pub fn arr(v: Value, key: []const u8) []const Value {
    const x = get(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}
