//! Aligned plain-text tables. No colour, so pipes and NO_COLOR need nothing special.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    gpa: Allocator,
    headers: []const []const u8,
    rows: std.ArrayList([]const []const u8) = .empty,

    pub fn init(gpa: Allocator, headers: []const []const u8) Table {
        return .{ .gpa = gpa, .headers = headers };
    }

    pub fn row(t: *Table, cells: []const []const u8) void {
        const copy = t.gpa.alloc([]const u8, cells.len) catch return;
        for (cells, 0..) |c, i| copy[i] = oneLine(t.gpa, c);
        t.rows.append(t.gpa, copy) catch {};
    }

    pub fn write(t: *Table, w: *std.Io.Writer, indent: []const u8) void {
        const widths = t.gpa.alloc(usize, t.headers.len) catch return;
        for (t.headers, 0..) |h, i| widths[i] = width(h);
        for (t.rows.items) |r| for (r, 0..) |c, i| {
            if (i < widths.len) widths[i] = @max(widths[i], width(c));
        };
        line(t.gpa, w, indent, t.headers, widths);
        for (t.rows.items) |r| line(t.gpa, w, indent, r, widths);
    }

    fn line(a: Allocator, w: *std.Io.Writer, indent: []const u8, cells: []const []const u8, widths: []const usize) void {
        var buf: std.ArrayList(u8) = .empty;
        for (cells, 0..) |c, i| {
            if (i > 0) buf.appendSlice(a, "  ") catch {};
            buf.appendSlice(a, c) catch {};
            if (i + 1 < cells.len) buf.appendNTimes(a, ' ', widths[i] -| width(c)) catch {};
        }
        w.print("{s}{s}\n", .{ indent, std.mem.trimEnd(u8, buf.items, " ") }) catch {};
    }
};

fn oneLine(gpa: Allocator, s: []const u8) []const u8 {
    if (std.mem.findAny(u8, s, "\n\r\t") == null) return s;
    const c = gpa.dupe(u8, s) catch return s;
    for (c) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return c;
}

/// Display width, counting UTF-8 code points.
pub fn width(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

pub fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}
