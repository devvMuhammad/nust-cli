//! `nust lms ...`. Each command fetches, builds a view, then prints a table or `--json`.
const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Clients = @import("../clients.zig").Clients;
const model = @import("model.zig");
const resolve = @import("resolve.zig");
const j = @import("json.zig");
const tf = @import("../timefmt.zig");
const Table = @import("../table.zig").Table;
const orDash = @import("../table.zig").orDash;
const text = @import("../text.zig");
const Moodle = @import("moodle.zig").Moodle;

fn idStr(app: *App, id: i64) []const u8 {
    return std.fmt.allocPrint(app.gpa, "{d}", .{id}) catch "0";
}

pub fn fetchCourses(app: *App, m: *Moodle) Failed![]const model.Course {
    const uid = try m.userId();
    return model.courses(app.gpa, try m.call("core_enrol_get_users_courses", &.{.{ "userid", idStr(app, uid) }}));
}

fn fetchAssignments(app: *App, m: *Moodle, course_id: ?i64) Failed![]const model.Assignment {
    var args: std.ArrayList([2][]const u8) = .empty;
    if (course_id) |id| args.append(app.gpa, .{ "courseids[0]", idStr(app, id) }) catch {};
    return model.assignments(app.gpa, try m.call("mod_assign_get_assignments", args.items));
}

/// A status the server refuses (permissions, hidden activity) leaves the row blank instead of
/// failing the whole listing.
fn fetchStatus(app: *App, m: *Moodle, id: i64, tolerate: bool) Failed!?model.Status {
    const v = m.call("mod_assign_get_submission_status", &.{.{ "assignid", idStr(app, id) }}) catch |e| {
        if (tolerate and app.failure != null and !isTransport(app.failure.?.code)) {
            app.failure = null;
            return null;
        }
        return e;
    };
    return .{ .raw = v };
}

fn isTransport(code: []const u8) bool {
    inline for (.{ "NETWORK", "AUTH_REQUIRED", "LOGIN_FAILED", "NO_TERMINAL", "HTTP_ERROR", "BAD_RESPONSE" }) |c| if (std.mem.eql(u8, code, c)) return true;
    return false;
}

fn when(app: *App, t: i64) []const u8 {
    return tf.when(app.gpa, app.zone, t, app.now);
}

fn rel(app: *App, t: i64, overdue: bool) []const u8 {
    return tf.relative(app.gpa, t, app.now, overdue);
}

fn editText(app: *App, e: model.Editability) []const u8 {
    return switch (e) {
        .open => |late| if (late > 0) std.fmt.allocPrint(app.gpa, "yes (late {s})", .{tf.span(app.gpa, late)}) catch "yes" else "yes",
        .closed => |c| switch (c) {
            .past_cutoff => "no (closed)",
            .not_open_yet => "no (not open yet)",
            .locked => "no (locked)",
            .submissions_disabled => "no (disabled)",
            .not_editable => "no",
        },
    };
}

// ---- whoami ----

pub fn whoami(app: *App, c: *Clients) Failed!void {
    const m = try c.moodle();
    const info = try m.call("core_webservice_get_site_info", &.{});
    const View = struct { full_name: []const u8, username: []const u8, user_id: ?i64, site: []const u8, site_url: []const u8 };
    const v: View = .{ .full_name = j.str(info, "fullname"), .username = j.str(info, "username"), .user_id = j.int(info, "userid"), .site = j.str(info, "sitename"), .site_url = m.base };
    if (app.json) return app.emitJson(v);
    app.print("{s} ({s})\nUser id  {d}\nSite     {s} ({s})\n", .{ v.full_name, v.username, v.user_id orelse 0, v.site, v.site_url });
}

// ---- courses ----

pub fn courses(app: *App, c: *Clients) Failed!void {
    const list = try fetchCourses(app, try c.moodle());
    if (app.json) {
        const V = struct { id: i64, code: []const u8, title: []const u8, full_name: []const u8, favourite: bool, last_access: ?i64 };
        var out: std.ArrayList(V) = .empty;
        for (list) |x| out.append(app.gpa, .{ .id = x.id, .code = x.code, .title = x.title, .full_name = x.full_name, .favourite = x.favourite, .last_access = x.last_access }) catch {};
        return app.emitJson(out.items);
    }
    if (list.len == 0) return app.print("No courses.\n", .{});
    var t = Table.init(app.gpa, &.{ "ID", "CODE", "COURSE", "" });
    for (list) |x| t.row(&.{ idStr(app, x.id), orDash(x.code), x.title, if (x.favourite) "*" else "" });
    t.write(app.out, "");
}

// ---- deadlines ----

pub fn deadlines(app: *App, c: *Clients, all: bool) Failed!void {
    const m = try c.moodle();
    var args: std.ArrayList([2][]const u8) = .empty;
    args.appendSlice(app.gpa, &.{ .{ "limitnum", "50" }, .{ "limittononsuspendedevents", "1" } }) catch {};
    if (all) {
        args.append(app.gpa, .{ "timesortfrom", "0" }) catch {};
    } else {
        // Two weeks back so recently overdue work stays visible, three months ahead.
        args.append(app.gpa, .{ "timesortfrom", idStr(app, app.now - 14 * 86400) }) catch {};
        args.append(app.gpa, .{ "timesortto", idStr(app, app.now + 90 * 86400) }) catch {};
    }
    const list = model.deadlines(app.gpa, try m.call("core_calendar_get_action_events_by_timesort", args.items));
    if (app.json) return app.emitJson(list);
    if (list.len == 0) return app.print("No upcoming deadlines.\n", .{});
    var t = Table.init(app.gpa, &.{ "DUE", "IN", "COURSE", "ACTIVITY", "ACTION" });
    for (list) |d| t.row(&.{ when(app, d.due), rel(app, d.due, d.overdue), orDash(d.course.code), d.activity, d.action orelse "-" });
    t.write(app.out, "");
}

// ---- notifications ----

pub fn notifications(app: *App, c: *Clients, unread_only: bool) Failed!void {
    const m = try c.moodle();
    const uid = try m.userId();
    const page = model.notifications(app.gpa, try m.call("message_popup_get_popup_notifications", &.{
        .{ "useridto", idStr(app, uid) }, .{ "limit", "40" }, .{ "offset", "0" }, .{ "newestfirst", "1" },
    }));
    var shown: std.ArrayList(model.Notification) = .empty;
    for (page.items) |n| if (!unread_only or !n.read) shown.append(app.gpa, n) catch {};
    if (app.json) return app.emitJson(.{ .unread_total = page.unread, .notifications = shown.items });
    if (shown.items.len == 0) return app.print("{s}\n", .{if (unread_only) "No unread notifications." else "No notifications."});
    var t = Table.init(app.gpa, &.{ "NEW", "WHEN", "SUBJECT" });
    for (shown.items) |n| t.row(&.{ if (n.read) "" else "*", rel(app, n.created, false), n.subject });
    t.write(app.out, "");
    app.print("\n{d} unread in total\n", .{page.unread});
}

// ---- assignments ----

pub fn assignments(app: *App, c: *Clients, course_q: ?[]const u8) Failed!void {
    const m = try c.moodle();
    const course_id: ?i64 = if (course_q) |q| (try resolve.course(app, try fetchCourses(app, m), q)).id else null;
    const list = try fetchAssignments(app, m, course_id);
    const sorted = app.gpa.dupe(model.Assignment, list) catch return app.fail("OOM", .failure, "out of memory", .{});
    std.mem.sort(model.Assignment, sorted, {}, struct {
        fn lt(_: void, a: model.Assignment, b: model.Assignment) bool {
            return (a.due orelse std.math.maxInt(i64)) < (b.due orelse std.math.maxInt(i64));
        }
    }.lt);
    const Row = struct { id: i64, cmid: i64, name: []const u8, course: model.CourseRef, due: ?i64, state: ?model.State, open: ?bool, late_secs: ?i64 };
    var rows: std.ArrayList(Row) = .empty;
    var t = Table.init(app.gpa, &.{ "ID", "COURSE", "ASSIGNMENT", "STATE", "DUE", "IN", "OPEN" });
    for (sorted) |a| {
        const st = try fetchStatus(app, m, a.id, true);
        const state: ?model.State = if (st) |s| s.state() else null;
        const ed: ?model.Editability = if (st) |s| model.editability(a, s, app.now) else null;
        rows.append(app.gpa, .{
            .id = a.id,
            .cmid = a.cmid,
            .name = a.name,
            .course = a.course,
            .due = a.due,
            .state = state,
            .open = if (ed) |e| e == .open else null,
            .late_secs = if (ed) |e| (if (e == .open) e.open else null) else null,
        }) catch {};
        const unfinished = state == null or state.? != .submitted;
        t.row(&.{
            idStr(app, a.id),
            orDash(a.course.code),
            a.name,
            if (state) |s| @tagName(s) else "?",
            if (a.due) |d| when(app, d) else "-",
            if (a.due) |d| rel(app, d, unfinished) else "-",
            if (ed) |e| editText(app, e) else "?",
        });
    }
    if (app.json) return app.emitJson(rows.items);
    if (rows.items.len == 0) return app.print("No assignments.\n", .{});
    t.write(app.out, "");
}

// ---- status ----

pub fn status(app: *App, c: *Clients, query: []const u8) Failed!void {
    const m = try c.moodle();
    const a = try resolve.assignment(app, try fetchAssignments(app, m, null), query);
    const s = (try fetchStatus(app, m, a.id, false)).?;
    const ed = model.editability(a, s, app.now);
    const held = s.files(app.gpa);
    const teacher = s.teacherFiles(app.gpa);
    const limits = a.fileLimits(app.gpa);
    if (app.json) return app.emitJson(.{
        .id = a.id,
        .cmid = a.cmid,
        .name = a.name,
        .course = a.course,
        .state = s.state(),
        .grading = s.gradingStatus(),
        .open = ed == .open,
        .late_secs = if (ed == .open) ed.open else 0,
        .closed_reason = if (ed == .closed) @tagName(ed.closed) else null,
        .due = a.due,
        .cutoff = a.cutoff,
        .extension_due = s.extensionDue(),
        .requires_statement = a.requires_statement,
        .file_limits = limits,
        .online_text = a.onlineTextEnabled(),
        .last_saved = s.modified(),
        .files = held,
        .teacher_files = teacher,
    });
    app.print("{s}\n{s}  (assignment {d})\n\n", .{ a.name, a.course.label(app.gpa), a.id });
    var kv = Table.init(app.gpa, &.{ "", "" });
    kv.row(&.{ "State", @tagName(s.state()) });
    kv.row(&.{ "Grading", s.gradingStatus() });
    kv.row(&.{ "Open", switch (ed) {
        .open => editText(app, ed),
        .closed => |cl| std.fmt.allocPrint(app.gpa, "no: {s}", .{cl.describe()}) catch "no",
    } });
    const unfinished = s.state() != .submitted;
    kv.row(&.{ "Due", if (a.due) |d| std.fmt.allocPrint(app.gpa, "{s} ({s})", .{ when(app, d), rel(app, d, unfinished) }) catch "" else "-" });
    kv.row(&.{ "Cut-off", if (a.cutoff) |d| when(app, d) else "none" });
    if (s.extensionDue()) |d| kv.row(&.{ "Extension", when(app, d) });
    if (limits) |l| {
        const types = if (l.allowed_types.len == 0) "any type" else std.mem.join(app.gpa, ", ", l.allowed_types) catch "";
        kv.row(&.{ "Accepts", std.fmt.allocPrint(app.gpa, "up to {d} files, {s} each, {s}", .{ l.max_files, tf.size(app.gpa, l.max_bytes), types }) catch "" });
    }
    if (a.onlineTextEnabled()) kv.row(&.{ "Text", "online text box" });
    if (s.state() != .new) if (s.modified()) |t| kv.row(&.{ "Last saved", when(app, t) });
    for (kv.rows.items) |r| app.print("{s: <11} {s}\n", .{ r[0], r[1] });
    if (s.onlineText()) |ot| {
        const t = text.htmlToText(app.gpa, ot.text);
        if (t.len > 0) app.print("\nOnline text:\n  {s}\n", .{t});
    }
    printFiles(app, "Files on record", held);
    if (teacher.len > 0) printFiles(app, "Attached by the teacher", teacher);
}

fn printFiles(app: *App, title: []const u8, list: []const model.RemoteFile) void {
    if (list.len == 0) return app.print("\n{s}: none\n", .{title});
    app.print("\n{s}:\n", .{title});
    var t = Table.init(app.gpa, &.{ "FILE", "SIZE", "MODIFIED" });
    for (list) |f| t.row(&.{ f.name, tf.size(app.gpa, f.size), if (f.modified) |m| when(app, m) else "-" });
    t.write(app.out, "  ");
}

// ---- files ----

const Module = struct { name: []const u8, kind: []const u8, link: ?[]const u8, files: []const model.RemoteFile };
const Section = struct { id: i64, name: []const u8, modules: []const Module };

fn sections(app: *App, v: std.json.Value) []const Section {
    var out: std.ArrayList(Section) = .empty;
    if (v != .array) return &.{};
    for (v.array.items) |s| {
        if (!j.flag(s, "visible", true)) continue;
        var mods: std.ArrayList(Module) = .empty;
        for (j.arr(s, "modules")) |md| {
            const kind = j.str(md, "modname");
            if (!j.flag(md, "visible", true) or !j.flag(md, "uservisible", true)) continue;
            if (std.mem.eql(u8, kind, "label") or std.mem.eql(u8, kind, "enhancedlabel")) continue;
            var found: std.ArrayList(model.RemoteFile) = .empty;
            var link: ?[]const u8 = null;
            const contents = j.arr(md, "contents");
            if (std.mem.eql(u8, kind, "url")) {
                if (contents.len > 0 and j.str(contents[0], "fileurl").len > 0) link = j.str(contents[0], "fileurl");
            } else for (contents) |ct| {
                if (std.mem.eql(u8, j.str(ct, "type"), "file") and j.str(ct, "fileurl").len > 0) found.append(app.gpa, model.RemoteFile.from(ct)) catch {};
            }
            mods.append(app.gpa, .{ .name = j.str(md, "name"), .kind = kind, .link = link, .files = found.items }) catch {};
        }
        if (mods.items.len > 0) out.append(app.gpa, .{ .id = j.int(s, "id") orelse 0, .name = j.str(s, "name"), .modules = mods.items }) catch {};
    }
    return out.items;
}

pub fn files(app: *App, c: *Clients, course_q: []const u8, download_dir: ?[]const u8) Failed!void {
    const m = try c.moodle();
    const course = try resolve.course(app, try fetchCourses(app, m), course_q);
    const secs = sections(app, try m.call("core_course_get_contents", &.{.{ "courseid", idStr(app, course.id) }}));
    if (download_dir) |dir| return download(app, m, secs, dir);
    if (app.json) return app.emitJson(.{ .course = course.ref(), .sections = secs });
    app.print("{s}\n", .{course.ref().label(app.gpa)});
    if (secs.len == 0) return app.print("\nNo files.\n", .{});
    for (secs) |s| {
        app.print("\n{s}\n", .{orDash(s.name)});
        for (s.modules) |md| {
            app.print("  {s} [{s}]\n", .{ md.name, md.kind });
            if (md.link) |l| app.print("    {s}\n", .{l});
            for (md.files) |f| app.print("    {s}  {s}{s}{s}\n", .{ f.name, tf.size(app.gpa, f.size), if (f.modified != null) "  " else "", if (f.modified) |t| when(app, t) else "" });
        }
    }
}

fn download(app: *App, m: *Moodle, secs: []const Section, dir_path: []const u8) Failed!void {
    const io = app.io;
    Io.Dir.cwd().createDirPath(io, dir_path) catch |e| return app.fail("IO", .failure, "cannot create {s}: {s}", .{ dir_path, @errorName(e) });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch |e| return app.fail("IO", .failure, "cannot open {s}: {s}", .{ dir_path, @errorName(e) });
    defer dir.close(io);
    const Result = struct { path: []const u8, status: []const u8, bytes: u64 = 0, @"error": ?[]const u8 = null };
    var results: std.ArrayList(Result) = .empty;
    var planned: std.ArrayList([]const u8) = .empty;
    var n_ok: usize = 0;
    var n_skip: usize = 0;
    var n_fail: usize = 0;
    for (secs) |s| {
        const sec_name = if (s.name.len > 0) s.name else std.fmt.allocPrint(app.gpa, "section {d}", .{s.id}) catch "section";
        const sub = text.sanitizeFilename(app.gpa, sec_name);
        for (s.modules) |md| for (md.files) |f| {
            const base = text.sanitizeFilename(app.gpa, f.name);
            var rel_path = std.fs.path.join(app.gpa, &.{ sub, base }) catch continue;
            var n: u32 = 1;
            while (contains(planned.items, rel_path)) {
                n += 1;
                rel_path = std.fs.path.join(app.gpa, &.{ sub, numbered(app, base, n) }) catch break;
            }
            planned.append(app.gpa, rel_path) catch {};
            if (dir.statFile(io, rel_path, .{})) |st| {
                if (st.kind == .file and st.size == f.size) {
                    n_skip += 1;
                    results.append(app.gpa, .{ .path = rel_path, .status = "up_to_date" }) catch {};
                    if (!app.json) app.print("up to date  {s}\n", .{rel_path});
                    continue;
                }
            } else |_| {}
            if (m.download(f.url, dir, rel_path)) |bytes| {
                n_ok += 1;
                results.append(app.gpa, .{ .path = rel_path, .status = "downloaded", .bytes = bytes }) catch {};
                if (!app.json) app.print("downloaded  {s}  ({s})\n", .{ rel_path, tf.size(app.gpa, bytes) });
            } else |_| {
                const msg = if (app.failure) |fl| fl.message else "failed";
                if (app.failure) |fl| if (std.mem.eql(u8, fl.code, "AUTH_REQUIRED") or std.mem.eql(u8, fl.code, "NO_TERMINAL")) return error.Failed;
                app.failure = null;
                n_fail += 1;
                results.append(app.gpa, .{ .path = rel_path, .status = "failed", .@"error" = msg }) catch {};
                if (!app.json) app.print("FAILED      {s}  ({s})\n", .{ rel_path, msg });
            }
            app.out.flush() catch {};
        };
    }
    if (app.json) app.emitJson(results.items) else app.print("\n{d} downloaded, {d} up to date, {d} failed\n", .{ n_ok, n_skip, n_fail });
    if (n_fail > 0) return app.fail("DOWNLOADS_FAILED", .failure, "{d} of {d} downloads failed", .{ n_fail, results.items.len });
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn numbered(app: *App, name: []const u8, n: u32) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |dot| if (dot > 0)
        return std.fmt.allocPrint(app.gpa, "{s} ({d}){s}", .{ name[0..dot], n, name[dot..] }) catch name;
    return std.fmt.allocPrint(app.gpa, "{s} ({d})", .{ name, n }) catch name;
}

pub const submit = @import("submit.zig").run;
