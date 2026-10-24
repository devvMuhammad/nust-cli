//! Small text helpers shared by the LMS and Qalam code.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Collapses runs of whitespace (including newlines) into single spaces and trims.
pub fn collapse(gpa: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0b\x0c");
    while (it.next()) |word| {
        if (out.items.len > 0) out.append(gpa, ' ') catch return s;
        out.appendSlice(gpa, word) catch return s;
    }
    // Non-breaking spaces from &nbsp; count as whitespace too.
    return std.mem.trim(u8, replaceAll(gpa, out.items, "\u{a0}", " "), " ");
}

pub fn replaceAll(gpa: Allocator, s: []const u8, needle: []const u8, with: []const u8) []const u8 {
    if (std.mem.find(u8, s, needle) == null) return s;
    return std.mem.replaceOwned(u8, gpa, s, needle, with) catch s;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

/// Decodes the HTML entities the portals actually use, plus numeric references.
pub fn decodeEntities(gpa: Allocator, s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.findScalarPos(u8, s, i, ';')) |end| {
                if (end - i <= 10) {
                    if (entity(s[i + 1 .. end])) |cp| {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                        out.appendSlice(gpa, buf[0..n]) catch return s;
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        out.append(gpa, s[i]) catch return s;
        i += 1;
    }
    return out.items;
}

fn entity(name: []const u8) ?u21 {
    if (name.len > 1 and name[0] == '#') {
        const code = if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16) catch return null
        else
            std.fmt.parseInt(u21, name[1..], 10) catch return null;
        return if (std.unicode.utf8ValidCodepoint(code)) code else null;
    }
    const table = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },        .{ "lt", '<' },         .{ "gt", '>' },         .{ "quot", '"' },
        .{ "apos", '\'' },      .{ "nbsp", ' ' },       .{ "ndash", 0x2013 },   .{ "mdash", 0x2014 },
        .{ "hellip", 0x2026 },  .{ "lsquo", 0x2018 },   .{ "rsquo", 0x2019 },   .{ "ldquo", 0x201c },
        .{ "rdquo", 0x201d },   .{ "copy", 0xa9 },      .{ "reg", 0xae },       .{ "times", 0xd7 },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

/// Terminal-friendly plain text from an HTML fragment (Moodle messages, online text).
pub fn htmlToText(gpa: Allocator, html: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        const open = std.mem.findScalarPos(u8, html, i, '<') orelse {
            out.appendSlice(gpa, html[i..]) catch {};
            break;
        };
        out.appendSlice(gpa, html[i..open]) catch {};
        const close = std.mem.findScalarPos(u8, html, open, '>') orelse break;
        var tag = html[open + 1 .. close];
        const closing = tag.len > 0 and tag[0] == '/';
        if (closing) tag = tag[1..];
        var name_end: usize = 0;
        while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
        const name = tag[0..name_end];
        i = close + 1;
        if (!closing and (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style"))) {
            const end_tag = if (std.ascii.eqlIgnoreCase(name, "script")) "</script" else "</style";
            const at = std.ascii.findIgnoreCasePos(html, i, end_tag) orelse html.len;
            i = if (std.mem.findScalarPos(u8, html, at, '>')) |gt| gt + 1 else html.len;
            continue;
        }
        const breaks = [_][]const u8{ "br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6" };
        for (breaks) |b| if (std.ascii.eqlIgnoreCase(name, b)) {
            out.append(gpa, '\n') catch {};
            break;
        };
    }
    const decoded = decodeEntities(gpa, out.items);
    var lines: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, decoded, '\n');
    var last_blank = true;
    while (it.next()) |line| {
        const l = collapse(gpa, line);
        if (l.len == 0) {
            if (!last_blank) lines.append(gpa, '\n') catch {};
            last_blank = true;
            continue;
        }
        if (lines.items.len > 0 and !last_blank) lines.append(gpa, '\n') catch {};
        lines.appendSlice(gpa, l) catch {};
        last_blank = false;
    }
    return std.mem.trim(u8, lines.items, "\n ");
}

/// Makes a server-provided name safe as one path component.
pub fn sanitizeFilename(gpa: Allocator, name: []const u8) []const u8 {
    const buf = gpa.dupe(u8, name) catch return "_";
    for (buf) |*c| {
        if (c.* < 0x20 or c.* == 0x7f or std.mem.findScalar(u8, "/\\:*?\"<>|", c.*) != null) c.* = '_';
    }
    const t = std.mem.trim(u8, buf, ". \t");
    return if (t.len == 0) "_" else t;
}

/// Space-separated words, for comparing text as typed with text as the server renders it.
pub fn words(gpa: Allocator, s: []const u8) []const u8 {
    return collapse(gpa, s);
}

test "html to text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Hi Ali,\nDue &now <soon>", htmlToText(a, "<p>Hi   Ali,</p><script>x()</script><p>Due &amp;now &lt;soon&gt;</p>"));
    try std.testing.expectEqualStrings("a b", collapse(a, "  a \n\t b "));
    try std.testing.expectEqualStrings("lab_1.c", sanitizeFilename(a, "lab/1.c"));
    try std.testing.expectEqualStrings("Calculus & Geometry", decodeEntities(a, "Calculus &amp; Geometry"));
}
