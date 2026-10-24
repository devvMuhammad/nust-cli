//! Local time, relative spans and file sizes, formatted for a terminal.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// UTC offsets for the local zone. Pakistan (+05:00, no DST) when the system has no zone data.
pub const Zone = struct {
    /// Sorted by `at`; each entry's offset applies from `at` onwards.
    changes: []const Change = &.{},
    fallback: i32 = 5 * 3600,

    pub const Change = struct { at: i64, offset: i32 };

    pub fn offsetAt(z: Zone, t: i64) i32 {
        var off = z.fallback;
        for (z.changes) |c| {
            if (c.at > t) break;
            off = c.offset;
        }
        return off;
    }

    pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) Zone {
        if (builtin.os.tag == .windows) return .{ .fallback = windowsOffset() };
        var path: []const u8 = "/etc/localtime";
        if (env.get("TZ")) |tz| {
            const name = std.mem.trimStart(u8, tz, ":");
            if (name.len == 0 or std.mem.eql(u8, name, "UTC") or std.mem.eql(u8, name, "UTC0")) return .{ .fallback = 0 };
            path = if (name[0] == '/') name else std.fmt.allocPrint(gpa, "/usr/share/zoneinfo/{s}", .{name}) catch return .{};
        }
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return .{};
        var reader: Io.Reader = .fixed(data);
        const tz = std.tz.Tz.parse(gpa, &reader) catch return .{};
        var list: std.ArrayList(Change) = .empty;
        for (tz.transitions) |tr| list.append(gpa, .{ .at = tr.ts, .offset = tr.timetype.offset }) catch return .{};
        var fallback: i32 = 0;
        if (tz.transitions.len > 0) {
            fallback = tz.transitions[tz.transitions.len - 1].timetype.offset;
        } else if (tz.timetypes.len > 0) {
            fallback = tz.timetypes[0].offset;
        }
        // Before the first transition, the first time type applies.
        return .{ .changes = list.items, .fallback = if (tz.timetypes.len > 0 and tz.transitions.len > 0) tz.timetypes[0].offset else fallback };
    }
};

const TIME_ZONE_INFORMATION = extern struct {
    Bias: i32,
    StandardName: [32]u16,
    StandardDate: [8]u16,
    StandardBias: i32,
    DaylightName: [32]u16,
    DaylightDate: [8]u16,
    DaylightBias: i32,
};

fn windowsOffset() i32 {
    if (builtin.os.tag != .windows) return 5 * 3600;
    const k = struct {
        extern "kernel32" fn GetTimeZoneInformation(info: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;
    };
    var info: TIME_ZONE_INFORMATION = undefined;
    const rc = k.GetTimeZoneInformation(&info);
    if (rc == 0xFFFFFFFF) return 5 * 3600;
    const bias = info.Bias + if (rc == 2) info.DaylightBias else 0;
    return -bias * 60;
}

pub const Civil = struct { year: i64, month: u8, day: u8, hour: u8, minute: u8, weekday: u8 };

/// Days since 1970-01-01 to a proleptic Gregorian date (H. Hinnant's algorithm).
pub fn civil(t: i64) Civil {
    const days = @divFloor(t, 86400);
    const secs: u32 = @intCast(t - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{
        .year = y,
        .month = m,
        .day = d,
        .hour = @intCast(secs / 3600),
        .minute = @intCast(secs % 3600 / 60),
        .weekday = @intCast(@mod(days + 4, 7)), // 0 = Sunday
    };
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `Fri 31 Oct 23:59`, with the year when it is not the current one.
pub fn when(gpa: Allocator, zone: Zone, t: i64, now: i64) []const u8 {
    const c = civil(t + zone.offsetAt(t));
    const n = civil(now + zone.offsetAt(now));
    if (c.year == n.year)
        return std.fmt.allocPrint(gpa, "{s} {d} {s} {d:0>2}:{d:0>2}", .{ day_names[c.weekday], c.day, month_names[c.month - 1], c.hour, c.minute }) catch "";
    return std.fmt.allocPrint(gpa, "{s} {d} {s} {d} {d:0>2}:{d:0>2}", .{ day_names[c.weekday], c.day, month_names[c.month - 1], c.year, c.hour, c.minute }) catch "";
}

/// `2026-10-24 18:42` in local time, for JSON-free logs and verification lines.
pub fn stamp(gpa: Allocator, zone: Zone, t: i64) []const u8 {
    const c = civil(t + zone.offsetAt(t));
    return std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ c.year, c.month, c.day, c.hour, c.minute }) catch "";
}

/// `2d 4h`, `3h 5m`, `12m`, `<1m`. Two units at most, zero units dropped.
pub fn span(gpa: Allocator, secs_in: i64) []const u8 {
    const secs: u64 = @abs(secs_in);
    const days = secs / 86400;
    const hours = secs % 86400 / 3600;
    const mins = secs % 3600 / 60;
    if (days > 0) {
        if (hours > 0) return std.fmt.allocPrint(gpa, "{d}d {d}h", .{ days, hours }) catch "";
        return std.fmt.allocPrint(gpa, "{d}d", .{days}) catch "";
    }
    if (hours > 0) {
        if (mins > 0) return std.fmt.allocPrint(gpa, "{d}h {d}m", .{ hours, mins }) catch "";
        return std.fmt.allocPrint(gpa, "{d}h", .{hours}) catch "";
    }
    if (mins > 0) return std.fmt.allocPrint(gpa, "{d}m", .{mins}) catch "";
    return "<1m";
}

/// `in 2d 4h` for the future; `overdue 3h` or `3h ago` for the past.
pub fn relative(gpa: Allocator, t: i64, now: i64, overdue: bool) []const u8 {
    const d = span(gpa, t - now);
    if (t >= now) return std.fmt.allocPrint(gpa, "in {s}", .{d}) catch "";
    if (overdue) return std.fmt.allocPrint(gpa, "overdue {s}", .{d}) catch "";
    return std.fmt.allocPrint(gpa, "{s} ago", .{d}) catch "";
}

/// `1.2 MB`, `340 KB`, `12 B`.
pub fn size(gpa: Allocator, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.fmt.allocPrint(gpa, "{d} B", .{bytes}) catch "";
    if (b < 1024.0 * 1024.0) return std.fmt.allocPrint(gpa, "{d:.0} KB", .{b / 1024.0}) catch "";
    if (b < 1024.0 * 1024.0 * 1024.0) return std.fmt.allocPrint(gpa, "{d:.1} MB", .{b / (1024.0 * 1024.0)}) catch "";
    return std.fmt.allocPrint(gpa, "{d:.1} GB", .{b / (1024.0 * 1024.0 * 1024.0)}) catch "";
}

test "civil dates" {
    const c = civil(1_791_665_417); // 2026-10-10 20:50:17 UTC
    try std.testing.expectEqual(@as(i64, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 10), c.month);
    try std.testing.expectEqual(@as(u8, 10), c.day);
    try std.testing.expectEqual(@as(u8, 6), c.weekday);
    const e = civil(0);
    try std.testing.expectEqual(@as(u8, 4), e.weekday);
    try std.testing.expectEqual(@as(i64, 1970), e.year);
}

test "spans and sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2d 4h", span(a, 2 * 86400 + 4 * 3600 + 59));
    try std.testing.expectEqualStrings("3h 5m", span(a, 3 * 3600 + 5 * 60));
    try std.testing.expectEqualStrings("1d", span(a, 86400));
    try std.testing.expectEqualStrings("<1m", span(a, 59));
    try std.testing.expectEqualStrings("12 B", size(a, 12));
    try std.testing.expectEqualStrings("602 KB", size(a, 616_666));
    try std.testing.expectEqualStrings("50.0 MB", size(a, 52_428_800));
    const z: Zone = .{ .fallback = 5 * 3600 };
    try std.testing.expectEqualStrings("Sun 11 Oct 01:50", when(a, z, 1_791_665_417, 1_791_665_417));
}
