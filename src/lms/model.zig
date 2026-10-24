//! Moodle replies turned into the records the commands use. Only fields the CLI reads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const j = @import("json.zig");
const text = @import("../text.zig");

pub const CourseRef = struct {
    id: i64,
    code: []const u8,
    title: []const u8,
    full_name: []const u8,

    pub fn fromName(id: i64, full_name: []const u8) CourseRef {
        const p = parseCourseName(full_name);
        return .{ .id = id, .code = p[0], .title = p[1], .full_name = full_name };
    }

    pub fn label(c: CourseRef, gpa: Allocator) []const u8 {
        if (c.code.len == 0) return c.title;
        return std.fmt.allocPrint(gpa, "{s} {s}", .{ c.code, c.title }) catch c.title;
    }
};

/// `CS-405-Deep Learning - 2K23-BESE-14` -> (`CS-405`, `Deep Learning`). Names that do not
/// follow the NUST pattern come back as an empty code and the whole name as the title.
pub fn parseCourseName(full: []const u8) [2][]const u8 {
    var i: usize = 0;
    while (i < full.len and std.ascii.isUpper(full[i])) i += 1;
    if (i < 2 or i > 5 or i >= full.len or full[i] != '-') return .{ "", full };
    const ds = i + 1;
    var k = ds;
    while (k < full.len and std.ascii.isDigit(full[k])) k += 1;
    if (k - ds < 2 or k - ds > 4 or k >= full.len or full[k] != '-') return .{ "", full };
    const code = full[0..k];
    const rest = full[k + 1 ..];
    var end = rest.len;
    var at: usize = 0;
    while (at < rest.len) : (at += 1) {
        if (std.ascii.isWhitespace(rest[at]) and isBatchSuffix(rest[at..])) {
            end = at;
            break;
        }
    }
    const title = std.mem.trim(u8, rest[0..end], " \t");
    if (title.len == 0) return .{ "", full };
    return .{ code, title };
}

/// Whitespace, an optional 1-3 letter section (`AB`), an optional dash, then a `2Kyy` batch tag.
fn isBatchSuffix(s_in: []const u8) bool {
    var s = std.mem.trimStart(u8, s_in, " \t");
    var n: usize = 0;
    while (n < s.len and std.ascii.isUpper(s[n])) n += 1;
    if (n >= 1 and n <= 3 and n < s.len and std.ascii.isWhitespace(s[n])) s = std.mem.trimStart(u8, s[n..], " \t");
    if (s.len > 0 and s[0] == '-') s = std.mem.trimStart(u8, s[1..], " \t");
    if (!std.mem.startsWith(u8, s, "2K")) return false;
    const y = s[2..];
    if (y.len < 2 or !std.ascii.isDigit(y[0]) or !std.ascii.isDigit(y[1])) return false;
    return y.len == 2 or !(std.ascii.isAlphanumeric(y[2]) or y[2] == '_');
}

pub const Course = struct {
    id: i64,
    code: []const u8,
    title: []const u8,
    full_name: []const u8,
    favourite: bool,
    last_access: ?i64,
    visible: bool,

    pub fn ref(c: Course) CourseRef {
        return .{ .id = c.id, .code = c.code, .title = c.title, .full_name = c.full_name };
    }
};

pub fn courses(gpa: Allocator, v: Value) []const Course {
    if (v != .array) return &.{};
    var out: std.ArrayList(Course) = .empty;
    for (v.array.items) |c| {
        const full = j.str(c, "fullname");
        const p = parseCourseName(full);
        const item: Course = .{
            .id = j.int(c, "id") orelse continue,
            .code = p[0],
            .title = p[1],
            .full_name = full,
            .favourite = j.flag(c, "isfavourite", false),
            .last_access = j.time(c, "lastaccess"),
            .visible = j.flag(c, "visible", true) and !j.flag(c, "hidden", false),
        };
        if (item.visible) out.append(gpa, item) catch {};
    }
    // Favourites first, then most recently used.
    std.mem.sort(Course, out.items, {}, struct {
        fn lt(_: void, a: Course, b: Course) bool {
            if (a.favourite != b.favourite) return a.favourite;
            return (a.last_access orelse 0) > (b.last_access orelse 0);
        }
    }.lt);
    return out.items;
}

pub const Deadline = struct {
    id: i64,
    activity: []const u8,
    kind: []const u8,
    due: i64,
    overdue: bool,
    url: []const u8,
    course: CourseRef,
    action: ?[]const u8,
};

pub fn deadlines(gpa: Allocator, v: Value) []const Deadline {
    var out: std.ArrayList(Deadline) = .empty;
    for (j.arr(v, "events")) |e| {
        const course = j.get(e, "course") orelse continue;
        const activity = j.str(e, "activityname");
        const kind = j.str(e, "modulename");
        var action: ?[]const u8 = null;
        var url = j.str(e, "url");
        if (j.get(e, "action")) |a| {
            if (j.flag(a, "actionable", false)) {
                action = j.str(a, "name");
                if (j.str(a, "url").len > 0) url = j.str(a, "url");
            }
        }
        out.append(gpa, .{
            .id = j.int(e, "id") orelse 0,
            .activity = if (activity.len > 0) activity else j.str(e, "name"),
            .kind = if (kind.len > 0) kind else j.str(e, "eventtype"),
            .due = j.int(e, "timesort") orelse 0,
            .overdue = j.flag(e, "overdue", false),
            .url = url,
            .course = CourseRef.fromName(j.int(course, "id") orelse 0, j.str(course, "fullname")),
            .action = action,
        }) catch {};
    }
    return out.items;
}

pub const Notification = struct {
    id: i64,
    subject: []const u8,
    body: []const u8,
    url: ?[]const u8,
    read: bool,
    created: i64,
};

pub const NotificationPage = struct { items: []const Notification, unread: i64 };

pub fn notifications(gpa: Allocator, v: Value) NotificationPage {
    var out: std.ArrayList(Notification) = .empty;
    for (j.arr(v, "notifications")) |n| {
        var body: []const u8 = "";
        for ([_][]const u8{ "fullmessagehtml", "text" }) |k| {
            if (body.len == 0 and j.str(n, k).len > 0) body = text.htmlToText(gpa, j.str(n, k));
        }
        if (body.len == 0) body = j.str(n, "fullmessage");
        const url = j.str(n, "contexturl");
        out.append(gpa, .{
            .id = j.int(n, "id") orelse 0,
            .subject = j.str(n, "subject"),
            .body = body,
            .url = if (url.len > 0) url else null,
            .read = j.flag(n, "read", false),
            .created = j.int(n, "timecreated") orelse 0,
        }) catch {};
    }
    return .{ .items = out.items, .unread = j.int(v, "unreadcount") orelse 0 };
}

pub const FileLimits = struct {
    max_files: u32,
    max_bytes: u64,
    /// Empty means any type.
    allowed_types: []const []const u8,
};

pub const Assignment = struct {
    id: i64,
    cmid: i64,
    course: CourseRef,
    name: []const u8,
    /// When false, saving a submission finalizes it: there is no separate submit step.
    drafts: bool,
    due: ?i64,
    allow_from: ?i64,
    cutoff: ?i64,
    requires_statement: bool,
    statement: []const u8,
    team: bool,
    raw: Value,

    fn config(a: Assignment, plugin: []const u8, name: []const u8) ?[]const u8 {
        for (j.arr(a.raw, "configs")) |c| {
            if (std.mem.eql(u8, j.str(c, "subtype"), "assignsubmission") and std.mem.eql(u8, j.str(c, "plugin"), plugin) and
                std.mem.eql(u8, j.str(c, "name"), name)) return j.str(c, "value");
        }
        return null;
    }

    pub fn onlineTextEnabled(a: Assignment) bool {
        return std.mem.eql(u8, a.config("onlinetext", "enabled") orelse "", "1");
    }

    /// Null when the assignment does not take file submissions.
    pub fn fileLimits(a: Assignment, gpa: Allocator) ?FileLimits {
        if (!std.mem.eql(u8, a.config("file", "enabled") orelse "", "1")) return null;
        var types: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, a.config("file", "filetypeslist") orelse "", ",; ");
        while (it.next()) |t| {
            if (!std.mem.eql(u8, t, "*")) types.append(gpa, t) catch {};
        }
        return .{
            .max_files = std.fmt.parseInt(u32, a.config("file", "maxfilesubmissions") orelse "0", 10) catch 0,
            .max_bytes = std.fmt.parseInt(u64, a.config("file", "maxsubmissionsizebytes") orelse "0", 10) catch 0,
            .allowed_types = types.items,
        };
    }
};

pub fn assignments(gpa: Allocator, v: Value) []const Assignment {
    var out: std.ArrayList(Assignment) = .empty;
    for (j.arr(v, "courses")) |g| {
        const course = CourseRef.fromName(j.int(g, "id") orelse 0, j.str(g, "fullname"));
        for (j.arr(g, "assignments")) |a| {
            out.append(gpa, .{
                .id = j.int(a, "id") orelse continue,
                .cmid = j.int(a, "cmid") orelse 0,
                .course = course,
                .name = j.str(a, "name"),
                .drafts = j.flag(a, "submissiondrafts", false),
                .due = j.time(a, "duedate"),
                .allow_from = j.time(a, "allowsubmissionsfromdate"),
                .cutoff = j.time(a, "cutoffdate"),
                .requires_statement = j.flag(a, "requiresubmissionstatement", false),
                .statement = j.str(a, "submissionstatement"),
                .team = j.flag(a, "teamsubmission", false),
                .raw = a,
            }) catch {};
        }
    }
    return out.items;
}

pub const RemoteFile = struct {
    name: []const u8,
    size: u64,
    url: []const u8,
    modified: ?i64,

    pub fn from(f: Value) RemoteFile {
        const sz = j.int(f, "filesize") orelse 0;
        return .{ .name = j.str(f, "filename"), .size = if (sz > 0) @intCast(sz) else 0, .url = j.str(f, "fileurl"), .modified = j.time(f, "timemodified") };
    }
};

pub const State = enum {
    new,
    draft,
    submitted,
    reopened,

    pub fn parse(s: []const u8) State {
        if (std.mem.eql(u8, s, "draft")) return .draft;
        if (std.mem.eql(u8, s, "submitted")) return .submitted;
        if (std.mem.eql(u8, s, "reopened")) return .reopened;
        return .new;
    }
};

pub const OnlineText = struct { text: []const u8, format: i64 };

/// `mod_assign_get_submission_status`.
pub const Status = struct {
    raw: Value,

    fn attempt(s: Status) ?Value {
        return j.get(s.raw, "lastattempt");
    }

    fn submission(s: Status) ?Value {
        const a = s.attempt() orelse return null;
        return j.get(a, "submission");
    }

    /// No attempt or no submission object means the student never touched it.
    pub fn state(s: Status) State {
        const sub = s.submission() orelse return .new;
        return State.parse(j.str(sub, "status"));
    }

    pub fn files(s: Status, gpa: Allocator) []const RemoteFile {
        const sub = s.submission() orelse return &.{};
        var out: std.ArrayList(RemoteFile) = .empty;
        for (j.arr(sub, "plugins")) |p| {
            if (!std.mem.eql(u8, j.str(p, "type"), "file")) continue;
            for (j.arr(p, "fileareas")) |area| {
                if (!std.mem.eql(u8, j.str(area, "area"), "submission_files")) continue;
                for (j.arr(area, "files")) |f| out.append(gpa, RemoteFile.from(f)) catch {};
            }
        }
        return out.items;
    }

    pub fn onlineText(s: Status) ?OnlineText {
        const sub = s.submission() orelse return null;
        for (j.arr(sub, "plugins")) |p| {
            if (!std.mem.eql(u8, j.str(p, "type"), "onlinetext")) continue;
            for (j.arr(p, "editorfields")) |f| {
                if (std.mem.eql(u8, j.str(f, "name"), "onlinetext")) return .{ .text = j.str(f, "text"), .format = j.int(f, "format") orelse 1 };
            }
        }
        return null;
    }

    /// `lastattempt.submission.timemodified`; every save moves it forward.
    pub fn modified(s: Status) ?i64 {
        const sub = s.submission() orelse return null;
        return j.time(sub, "timemodified");
    }

    pub fn flag(s: Status, key: []const u8) bool {
        const a = s.attempt() orelse return false;
        return j.flag(a, key, false);
    }

    pub fn extensionDue(s: Status) ?i64 {
        const a = s.attempt() orelse return null;
        return j.time(a, "extensionduedate");
    }

    pub fn gradingStatus(s: Status) []const u8 {
        const a = s.attempt() orelse return "not graded";
        const g = j.str(a, "gradingstatus");
        if (g.len == 0 or std.mem.eql(u8, g, "notgraded")) return "not graded";
        return g;
    }

    pub fn teacherFiles(s: Status, gpa: Allocator) []const RemoteFile {
        const data = j.get(s.raw, "assignmentdata") orelse return &.{};
        const att = j.get(data, "attachments") orelse return &.{};
        var out: std.ArrayList(RemoteFile) = .empty;
        for (j.arr(att, "intro")) |f| out.append(gpa, RemoteFile.from(f)) catch {};
        return out.items;
    }
};

pub const Closed = enum {
    submissions_disabled,
    locked,
    not_open_yet,
    past_cutoff,
    not_editable,

    pub fn describe(c: Closed) []const u8 {
        return switch (c) {
            .submissions_disabled => "submissions are disabled",
            .locked => "submissions are locked",
            .not_open_yet => "it is not open for submissions yet",
            .past_cutoff => "the cut-off date has passed",
            .not_editable => "the LMS does not allow editing it",
        };
    }
};

pub const Editability = union(enum) {
    /// Seconds past the due date (0 when on time); Moodle still accepts it.
    open: i64,
    closed: Closed,
};

fn maxOpt(a: ?i64, b: ?i64) ?i64 {
    if (a != null and b != null) return @max(a.?, b.?);
    return a orelse b;
}

/// What the student may do right now. Conservative: if the clock says closed, it is closed,
/// even when the server's `canedit` is still true.
pub fn editability(a: Assignment, s: Status, now: i64) Editability {
    if (s.attempt() == null) return .{ .closed = .not_editable };
    if (!s.flag("submissionsenabled")) return .{ .closed = .submissions_disabled };
    if (s.flag("locked")) return .{ .closed = .locked };
    if (a.allow_from) |from| if (now < from) return .{ .closed = .not_open_yet };
    // An extension can move the last moment either way, as in Moodle's `submissions_open`.
    if (maxOpt(a.cutoff, s.extensionDue())) |last| if (now > last) return .{ .closed = .past_cutoff };
    if (!s.flag("canedit")) return .{ .closed = .not_editable };
    if (maxOpt(a.due, s.extensionDue())) |due| if (now > due) return .{ .open = now - due };
    return .{ .open = 0 };
}

// ---- tests over captured real replies ----

pub const fixture_now: i64 = 1_791_665_417;

fn loadFixture(gpa: Allocator, name: []const u8) !Value {
    const path = try std.fmt.allocPrint(gpa, "tests/fixtures/lms/{s}", .{name});
    // Real captured replies are kept local (they hold personal data); skip without them.
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4 << 20)) catch return error.SkipZigTest;
    return std.json.parseFromSliceLeaky(Value, gpa, data, .{});
}

test "course names" {
    const p = parseCourseName("CS-405-Deep Learning - 2K23-BESE-14");
    try std.testing.expectEqualStrings("CS-405", p[0]);
    try std.testing.expectEqualStrings("Deep Learning", p[1]);
    try std.testing.expectEqualStrings("Engineering Economics", parseCourseName("ECO-130-Engineering Economics AB 2K23-BESE-14")[1]);
    try std.testing.expectEqualStrings("", parseCourseName("Orientation 2026")[0]);
    try std.testing.expectEqualStrings("C-1-Foo", parseCourseName("C-1-Foo")[1]);
    try std.testing.expectEqualStrings("Calculus I", parseCourseName("MATH-101-Calculus I")[1]);
}

test "fixture models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = courses(a, try loadFixture(a, "courses.json"));
    try std.testing.expectEqual(@as(usize, 4), cs.len);
    const ds = deadlines(a, try loadFixture(a, "calendar_events.json"));
    try std.testing.expectEqual(@as(usize, 6), ds.len);
    try std.testing.expectEqualStrings("Class Activity-Section A", ds[0].activity);
    try std.testing.expectEqualStrings("CS-335", ds[0].course.code);
    try std.testing.expectEqualStrings("Add submission", ds[0].action.?);
    const np = notifications(a, try loadFixture(a, "notifications.json"));
    try std.testing.expectEqual(@as(usize, 10), np.items.len);
    try std.testing.expectEqual(@as(i64, 21), np.unread);
    try std.testing.expect(np.items[0].body.len > 0 and std.mem.findScalar(u8, np.items[0].body, '<') == null);
    const as = assignments(a, try loadFixture(a, "assignments.json"));
    try std.testing.expectEqual(@as(usize, 11), as.len);
    const a1930 = for (as) |x| {
        if (x.id == 1930) break x;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("CS-484", a1930.course.code);
    try std.testing.expect(a1930.requires_statement);
    const lim = a1930.fileLimits(a).?;
    try std.testing.expectEqual(@as(u32, 10), lim.max_files);
    try std.testing.expectEqual(@as(u64, 52_428_800), lim.max_bytes);
    for (as) |x| try std.testing.expect(!x.drafts);
}
