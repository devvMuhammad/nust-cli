//! What a submit would do to the server, or why it must not happen, decided with no IO: the
//! local files are already inspected and the status already fetched. `verify` then compares
//! the re-fetched status with what the plan said the server would hold.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const text = @import("../text.zig");
const timefmt = @import("../timefmt.zig");

pub const LocalFile = struct {
    name: []const u8,
    size: u64,
    path: []const u8,
    /// Whole seconds; compared with the server's `timemodified`.
    modified: ?i64,
};

pub const Candidate = union(enum) {
    file: LocalFile,
    missing: []const u8,
    not_a_file: []const u8,
    unreadable: struct { path: []const u8, cause: []const u8 },
};

pub const Record = struct {
    name: []const u8,
    size: u64,

    fn lessThan(_: void, a: Record, b: Record) bool {
        const o = std.mem.order(u8, a.name, b.name);
        return if (o == .eq) a.size < b.size else o == .lt;
    }
};

pub const Replaced = struct { name: []const u8, size: u64, overwritten: bool };

/// Online text already on the server, as the status call renders it (HTML).
pub const HeldText = struct { html: []const u8, format: i64, kept: bool };

pub const Plan = struct {
    assignment: model.Assignment,
    current_state: model.State,
    files: []const LocalFile,
    online_text: ?[]const u8,
    held_text: ?HeldText,
    /// Files on record the new file set replaces. Empty when no files are sent.
    replaces: []const Replaced,
    /// Files on record left alone because only text is sent.
    keeps: []const Record,
    /// The assignment keeps drafts, so the save is followed by a submit for grading.
    submit_for_grading: bool,
    /// Seconds past the due date; 0 when on time.
    late: i64,
    /// Accepted on the user's behalf when the assignment requires it.
    statement: ?[]const u8,
    modified_before: ?i64,
    /// The server already holds exactly this.
    up_to_date: bool = false,

    pub const Editor = struct { text: []const u8, format: i64 };

    /// What goes into `plugindata[onlinetext_editor]`: the typed text (plain), or the held text unchanged.
    pub fn editorText(p: Plan) ?Editor {
        if (p.online_text) |t| return .{ .text = t, .format = 2 };
        if (p.held_text) |h| if (h.kept) return .{ .text = h.html, .format = h.format };
        return null;
    }

    pub fn expected(p: Plan, gpa: Allocator) Expected {
        var files: std.ArrayList(Record) = .empty;
        if (p.files.len == 0) {
            files.appendSlice(gpa, p.keeps) catch {};
        } else for (p.files) |f| files.append(gpa, .{ .name = f.name, .size = f.size }) catch {};
        std.mem.sort(Record, files.items, {}, Record.lessThan);
        var want_text: ?[]const u8 = null;
        if (p.online_text) |t| {
            want_text = text.words(gpa, t);
        } else if (p.held_text) |h| {
            if (h.kept) want_text = text.words(gpa, text.htmlToText(gpa, h.html));
        }
        return .{ .files = files.items, .text = want_text, .modified_after = p.modified_before };
    }
};

pub const Expected = struct {
    files: []const Record,
    text: ?[]const u8,
    modified_after: ?i64,
};

pub const Result = union(enum) { plan: Plan, refused: []const u8 };

fn refuse(gpa: Allocator, comptime fmt: []const u8, args: anytype) Result {
    return .{ .refused = std.fmt.allocPrint(gpa, fmt, args) catch "refused" };
}

/// Every file on record, sorted: two files of one name stay two entries.
pub fn records(gpa: Allocator, s: model.Status) []const Record {
    var out: std.ArrayList(Record) = .empty;
    for (s.files(gpa)) |f| out.append(gpa, .{ .name = f.name, .size = f.size }) catch {};
    std.mem.sort(Record, out.items, {}, Record.lessThan);
    return out.items;
}

/// `upload.php` runs names through Moodle's PARAM_FILE, which deletes these characters.
const stripped = "&/\\:;'\"|<>?*";

fn nameProblem(name: []const u8) ?u8 {
    for (name) |c| {
        if (c < 0x20 or c == 0x7f or std.mem.findScalar(u8, stripped, c) != null) return c;
    }
    return null;
}

/// Only `.ext` entries can be checked locally; a list with group names is left to the server.
fn typeAllowed(name: []const u8, allowed: []const []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |t| if (t.len == 0 or t[0] != '.') return true;
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (allowed) |t| if (std.ascii.eqlIgnoreCase(t[1..], ext)) return true;
    return false;
}

fn embedsFiles(s: []const u8) bool {
    return std.mem.find(u8, s, "pluginfile.php") != null or std.mem.find(u8, s, "@@PLUGINFILE@@") != null;
}

/// Decides everything about a submit without touching the disk or network. Refusals go from
/// the most fundamental (closed) to the most local (one bad file).
pub fn build(gpa: Allocator, a: model.Assignment, s: model.Status, candidates: []const Candidate, typed_text: ?[]const u8, now: i64) Result {
    const late = switch (model.editability(a, s, now)) {
        .closed => |c| return refuse(gpa, "the assignment is closed: {s}", .{c.describe()}),
        .open => |l| l,
    };
    if (a.team) return refuse(gpa, "this is a group submission; submit it on the website", .{});
    const typed: ?[]const u8 = if (typed_text) |t| (if (std.mem.trim(u8, t, " \t\r\n").len > 0) std.mem.trim(u8, t, " \t\r\n") else null) else null;
    if (candidates.len == 0 and typed == null) return refuse(gpa, "nothing to submit: give one or more files, or --text", .{});
    if (typed != null and !a.onlineTextEnabled()) return refuse(gpa, "this assignment does not take online text", .{});

    var files: std.ArrayList(LocalFile) = .empty;
    if (candidates.len > 0) {
        const limits = a.fileLimits(gpa) orelse return refuse(gpa, "this assignment does not take file submissions", .{});
        for (candidates) |c| {
            const f = switch (c) {
                .file => |f| f,
                .missing => |p| return refuse(gpa, "{s}: file not found", .{p}),
                .not_a_file => |p| return refuse(gpa, "{s}: not a regular file", .{p}),
                .unreadable => |u| return refuse(gpa, "{s}: cannot read it ({s})", .{ u.path, u.cause }),
            };
            if (f.size == 0) return refuse(gpa, "{s} is empty", .{f.path});
            for (files.items) |prev| if (std.mem.eql(u8, prev.name, f.name))
                return refuse(gpa, "two files are both named {s}; a submission needs unique names", .{f.name});
            if (nameProblem(f.name)) |ch| {
                if (ch < 0x20 or ch == 0x7f) return refuse(gpa, "{s}: the name has a control character the LMS would strip; rename it first", .{f.name});
                return refuse(gpa, "{s}: the LMS strips '{c}' from file names; rename it first", .{ f.name, ch });
            }
            if (limits.max_bytes > 0 and f.size > limits.max_bytes)
                return refuse(gpa, "{s} is {s}, the limit is {s} per file", .{ f.name, timefmt.size(gpa, f.size), timefmt.size(gpa, limits.max_bytes) });
            if (!typeAllowed(f.name, limits.allowed_types)) {
                const list = std.mem.join(gpa, ", ", limits.allowed_types) catch "";
                return refuse(gpa, "{s}: type not allowed (accepts: {s})", .{ f.name, list });
            }
            files.append(gpa, f) catch {};
        }
        if (limits.max_files > 0 and files.items.len > limits.max_files)
            return refuse(gpa, "{d} files given, the assignment allows at most {d}", .{ files.items.len, limits.max_files });
    }

    var held: ?HeldText = null;
    if (s.onlineText()) |t| {
        if (a.onlineTextEnabled() and text.words(gpa, text.htmlToText(gpa, t.text)).len > 0)
            held = .{ .html = t.text, .format = t.format, .kept = typed == null };
    }
    // A files-only save must send the held text back, and itemid 0 cannot carry embedded files.
    if (held) |h| if (h.kept and embedsFiles(h.html))
        return refuse(gpa, "the online text on record embeds images or files, which a files-only save would lose; use --text to replace it, or the website", .{});

    const on_record = records(gpa, s);
    var replaces: std.ArrayList(Replaced) = .empty;
    var keeps: []const Record = &.{};
    if (files.items.len == 0) {
        keeps = on_record;
    } else for (on_record) |r| {
        var same = false;
        for (files.items) |f| if (std.mem.eql(u8, f.name, r.name)) {
            same = true;
        };
        replaces.append(gpa, .{ .name = r.name, .size = r.size, .overwritten = same }) catch {};
    }

    var plan: Plan = .{
        .assignment = a,
        .current_state = s.state(),
        .files = files.items,
        .online_text = typed,
        .held_text = held,
        .replaces = replaces.items,
        .keeps = keeps,
        .submit_for_grading = a.drafts,
        .late = late,
        .statement = if (a.requires_statement) a.statement else null,
        .modified_before = s.modified(),
    };
    plan.up_to_date = upToDate(gpa, plan, s);
    return .{ .plan = plan };
}

/// The server has no content hash, so a local file counts as uploaded only when a server file
/// has its name and size and was stored no earlier than the local file was last changed.
fn upToDate(gpa: Allocator, p: Plan, s: model.Status) bool {
    const want = p.expected(gpa);
    const held = records(gpa, s);
    if (held.len != want.files.len) return false;
    for (held, want.files) |h, w| if (!std.mem.eql(u8, h.name, w.name) or h.size != w.size) return false;
    if (s.state() != .submitted) return false;
    if (want.text) |t| {
        const on = s.onlineText() orelse return false;
        if (!std.mem.eql(u8, text.words(gpa, text.htmlToText(gpa, on.text)), t)) return false;
    }
    const remote = s.files(gpa);
    for (p.files) |local| {
        var ok = false;
        for (remote) |r| {
            if (std.mem.eql(u8, r.name, local.name) and r.size == local.size and local.modified != null and r.modified != null and local.modified.? <= r.modified.?) ok = true;
        }
        if (!ok) return false;
    }
    return true;
}

/// Differences between what was sent and what the server now holds. Empty means verified.
pub fn verify(gpa: Allocator, want: Expected, s: model.Status) []const []const u8 {
    var diffs: std.ArrayList([]const u8) = .empty;
    var held: std.ArrayList(Record) = .empty;
    held.appendSlice(gpa, records(gpa, s)) catch {};
    var unmatched: std.ArrayList(Record) = .empty;
    for (want.files) |w| {
        var found: ?usize = null;
        for (held.items, 0..) |h, i| if (std.mem.eql(u8, h.name, w.name) and h.size == w.size) {
            found = i;
            break;
        };
        if (found) |i| _ = held.orderedRemove(i) else unmatched.append(gpa, w) catch {};
    }
    for (unmatched.items) |w| {
        var found: ?usize = null;
        for (held.items, 0..) |h, i| if (std.mem.eql(u8, h.name, w.name)) {
            found = i;
            break;
        };
        if (found) |i| {
            const h = held.orderedRemove(i);
            diffs.append(gpa, std.fmt.allocPrint(gpa, "{s}: sent {s} but the LMS holds {s}", .{ w.name, timefmt.size(gpa, w.size), timefmt.size(gpa, h.size) }) catch "") catch {};
        } else diffs.append(gpa, std.fmt.allocPrint(gpa, "{s} ({s}) is not on the LMS", .{ w.name, timefmt.size(gpa, w.size) }) catch "") catch {};
    }
    for (held.items) |h| diffs.append(gpa, std.fmt.allocPrint(gpa, "{s} ({s}) is on the LMS but was not sent", .{ h.name, timefmt.size(gpa, h.size) }) catch "") catch {};
    if (s.state() != .submitted) diffs.append(gpa, std.fmt.allocPrint(gpa, "the state is {s}, expected submitted", .{@tagName(s.state())}) catch "") catch {};
    if (want.text) |t| {
        const on = s.onlineText();
        const got = if (on) |o| text.words(gpa, text.htmlToText(gpa, o.text)) else "";
        if (got.len == 0) {
            diffs.append(gpa, "the online text is not on the LMS") catch {};
        } else if (!std.mem.eql(u8, got, t)) diffs.append(gpa, std.fmt.allocPrint(gpa, "the online text differs; the LMS holds: {s}", .{got}) catch "") catch {};
    }
    const moved = if (s.modified()) |after| (if (want.modified_after) |before| after > before else true) else false;
    if (!moved) diffs.append(gpa, "the LMS shows no change: the submission's last-saved time did not move") catch {};
    return diffs.items;
}

// ---- tests over captured statuses ----

fn fixtureValue(gpa: Allocator, name: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(gpa, "tests/fixtures/lms/{s}", .{name});
    // Real captured replies are kept local (they hold personal data); skip without them.
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4 << 20)) catch return error.SkipZigTest;
    return std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{});
}

fn fixtureAssignment(gpa: Allocator, id: i64) !model.Assignment {
    for (model.assignments(gpa, try fixtureValue(gpa, "assignments.json"))) |a| if (a.id == id) return a;
    return error.TestUnexpectedResult;
}

test "plans over real statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g = arena.allocator();
    const now = model.fixture_now;
    const a = try fixtureAssignment(g, 1930);
    const s: model.Status = .{ .raw = try fixtureValue(g, "submission_status_1930.json") };
    const file: Candidate = .{ .file = .{ .name = "report.pdf", .size = 1200, .path = "report.pdf", .modified = now - 10 } };
    const p = switch (build(g, a, s, &.{file}, null, now)) {
        .plan => |p| p,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{r});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expect(!p.submit_for_grading);
    try std.testing.expectEqual(@as(i64, 0), p.late);
    try std.testing.expectEqual(@as(usize, 1), p.files.len);
    try std.testing.expect(p.statement != null);
    try std.testing.expect(!p.up_to_date);
    try std.testing.expectEqual(model.State.new, p.current_state);
    try std.testing.expect(build(g, a, s, &.{}, null, now) == .refused);
    // Past the cut-off: refused before anything else.
    const closed = build(g, try fixtureAssignment(g, 438), .{ .raw = try fixtureValue(g, "submission_status_438.json") }, &.{file}, null, now);
    try std.testing.expect(closed == .refused);
    try std.testing.expect(std.mem.find(u8, closed.refused, "cut-off") != null);
    // Verifying the untouched status against the plan finds the missing file and no save.
    const diffs = verify(g, p.expected(g), s);
    try std.testing.expect(diffs.len >= 2);
    const missing: Candidate = .{ .missing = "nope.pdf" };
    try std.testing.expect(build(g, a, s, &.{missing}, null, now) == .refused);
}

test "type and name checks" {
    try std.testing.expect(typeAllowed("a.PDF", &.{".pdf"}));
    try std.testing.expect(!typeAllowed("a.docx", &.{ ".pdf", ".zip" }));
    try std.testing.expect(typeAllowed("a.docx", &.{"document"}));
    try std.testing.expect(nameProblem("a:b.txt") != null);
    try std.testing.expect(nameProblem("lab 3 (final).c") == null);
}
