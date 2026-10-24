//! `nust lms submit <assignment> <file>... [--text "..."] [-y]`
//! Fetch, plan, show, confirm, upload, save, re-fetch, verify. Nothing is written to the LMS
//! before the user has seen the plan and said yes. The submission statement is accepted for
//! the user, and the submission is always final (sent for grading).
const std = @import("std");
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Clients = @import("../clients.zig").Clients;
const model = @import("model.zig");
const plan_mod = @import("plan.zig");
const Plan = plan_mod.Plan;
const resolve = @import("resolve.zig");
const j = @import("json.zig");
const tf = @import("../timefmt.zig");
const text = @import("../text.zig");
const Moodle = @import("moodle.zig").Moodle;

fn idStr(app: *App, id: i64) []const u8 {
    return std.fmt.allocPrint(app.gpa, "{d}", .{id}) catch "0";
}

fn inspect(app: *App, path: []const u8) plan_mod.Candidate {
    const st = Io.Dir.cwd().statFile(app.io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .{ .missing = path },
        else => return .{ .unreadable = .{ .path = path, .cause = @errorName(e) } },
    };
    if (st.kind != .file) return .{ .not_a_file = path };
    const name = std.fs.path.basename(path);
    if (name.len == 0) return .{ .not_a_file = path };
    return .{ .file = .{ .name = name, .size = st.size, .path = path, .modified = st.mtime.toSeconds() } };
}

pub fn run(app: *App, c: *Clients, query: []const u8, paths: []const []const u8, typed_text: ?[]const u8) Failed!void {
    const m = try c.moodle();
    const all = model.assignments(app.gpa, try m.call("mod_assign_get_assignments", &.{}));
    const a = try resolve.assignment(app, all, query);
    const before: model.Status = .{ .raw = try m.call("mod_assign_get_submission_status", &.{.{ "assignid", idStr(app, a.id) }}) };

    var candidates: std.ArrayList(plan_mod.Candidate) = .empty;
    for (paths) |p| candidates.append(app.gpa, inspect(app, p)) catch {};
    const p = switch (plan_mod.build(app.gpa, a, before, candidates.items, typed_text, app.now)) {
        .plan => |p| p,
        .refused => |why| {
            if (!app.json) {
                app.out.flush() catch {};
                header(app, app.err, a);
            }
            return app.fail("REFUSED", .refused, "Can't submit: {s}\nNothing sent.", .{why});
        },
    };

    // A person must see the plan before any prompt; in --json mode it goes to stderr then.
    const will_prompt = !app.yes and app.interactive;
    const w = if (app.json) app.err else app.out;
    const ref = .{ .id = a.id, .course = a.course.code, .name = a.name };
    if (p.up_to_date) {
        if (!app.json) {
            header(app, w, a);
            w.print("The LMS already has these exact files, unchanged since you uploaded them.\n", .{}) catch {};
        }
        const again = if (will_prompt) try app.confirm("Submit again anyway? [y/N] ") else false;
        if (!again) {
            if (app.json) return app.emitJson(.{ .submitted = false, .up_to_date = true, .assignment = ref });
            app.print("Nothing sent.\n", .{});
            return;
        }
    } else {
        if (!app.json or will_prompt) showPlan(app, w, p);
        if (!app.yes and !app.interactive) {
            if (app.json) app.emitJson(.{ .submitted = false, .plan = planView(app, p) });
            return app.fail("NO_TERMINAL", .usage, "Not sent: there is no terminal to confirm in. Add -y to submit without asking.", .{});
        }
        if (!(try app.confirm("Submit? [y/N] "))) {
            app.note("Nothing sent.", .{});
            if (app.json) app.emitJson(.{ .submitted = false, .assignment = ref });
            return;
        }
    }
    try execute(app, m, p);

    app.note("Checking what the LMS now holds...", .{});
    const after_v = m.call("mod_assign_get_submission_status", &.{.{ "assignid", idStr(app, a.id) }}) catch
        return app.fail("UNVERIFIED", .failure, "The LMS accepted the submission, but reloading it failed. Check it with: nust lms status {d}", .{a.id});
    const after: model.Status = .{ .raw = after_v };
    const diffs = plan_mod.verify(app.gpa, p.expected(app.gpa), after);
    if (diffs.len > 0) {
        var aw: Io.Writer.Allocating = .init(app.gpa);
        for (diffs) |d| aw.writer.print("\n  {s}", .{d}) catch {};
        return app.fail("VERIFY_FAILED", .failure, "The LMS doesn't match what was sent:{s}\nCheck it in the browser or with: nust lms status {d}", .{ aw.written(), a.id });
    }
    const now_files = after.files(app.gpa);
    if (app.json) {
        const F = struct { name: []const u8, size: u64 };
        var fl: std.ArrayList(F) = .empty;
        for (now_files) |f| fl.append(app.gpa, .{ .name = f.name, .size = f.size }) catch {};
        return app.emitJson(.{
            .submitted = true,
            .late_secs = p.late,
            .assignment = .{ .id = a.id, .course = a.course.code, .name = a.name },
            .files = fl.items,
            .text = p.online_text,
            .saved_at = after.modified(),
        });
    }
    app.print("{s} The LMS now has:\n", .{if (p.late > 0) "Submitted (late)." else "Submitted."});
    for (now_files) |f| app.print("  {s}   {s}   {s}\n", .{ f.name, tf.size(app.gpa, f.size), if (f.modified) |t| tf.when(app.gpa, app.zone, t, app.now) else "" });
    if (after.onlineText()) |ot| {
        const t = text.htmlToText(app.gpa, ot.text);
        if (t.len > 0) app.print("  your text ({d} characters)\n", .{t.len});
    }
}

fn planView(app: *App, p: Plan) PlanView {
    var files: std.ArrayList(FileView) = .empty;
    for (p.files) |f| files.append(app.gpa, .{ .name = f.name, .size = f.size }) catch {};
    var removed: std.ArrayList(FileView) = .empty;
    for (p.replaces) |r| if (!r.overwritten) removed.append(app.gpa, .{ .name = r.name, .size = r.size }) catch {};
    return .{
        .assignment = .{ .id = p.assignment.id, .course = p.assignment.course.code, .name = p.assignment.name },
        .due = p.assignment.due,
        .late_secs = p.late,
        .files = files.items,
        .removes = removed.items,
        .text = p.online_text,
        .statement_accepted = p.statement != null,
    };
}

const FileView = struct { name: []const u8, size: u64 };
const PlanView = struct {
    assignment: struct { id: i64, course: []const u8, name: []const u8 },
    due: ?i64,
    late_secs: i64,
    files: []const FileView,
    /// Files on record that the new submission drops.
    removes: []const FileView,
    text: ?[]const u8,
    statement_accepted: bool,
};

fn header(app: *App, w: *Io.Writer, a: model.Assignment) void {
    w.print("{s}\n{s}\n", .{ a.course.label(app.gpa), a.name }) catch {};
}

fn showPlan(app: *App, w: *Io.Writer, p: Plan) void {
    const a = p.assignment;
    header(app, w, a);
    if (a.due) |d| w.print("Due   {s} ({s})\n", .{ tf.when(app.gpa, app.zone, d, app.now), tf.relative(app.gpa, d, app.now, true) }) catch {};
    if (p.late > 0) {
        w.print("\n  LATE by {s}.", .{tf.span(app.gpa, p.late)}) catch {};
        if (a.cutoff) |cut| w.print(" The LMS still accepts it until {s}.", .{tf.when(app.gpa, app.zone, cut, app.now)}) catch {};
        w.writeAll("\n") catch {};
    }
    w.writeAll("\n") catch {};
    for (p.files) |f| w.print("  + {s}   {s}\n", .{ f.name, tf.size(app.gpa, f.size) }) catch {};
    for (p.replaces) |r| {
        if (r.overwritten) {
            w.print("  ~ {s}   {s}   (replaced by the new copy)\n", .{ r.name, tf.size(app.gpa, r.size) }) catch {};
        } else w.print("  - {s}   {s}   (removed: a new submission replaces all old files)\n", .{ r.name, tf.size(app.gpa, r.size) }) catch {};
    }
    for (p.keeps) |k| w.print("    {s}   {s}   (kept)\n", .{ k.name, tf.size(app.gpa, k.size) }) catch {};
    if (p.online_text) |t| {
        w.print("  Text: \"{s}\" ({d} characters)\n", .{ preview(app, t), t.len }) catch {};
        if (p.held_text != null) w.writeAll("  (replaces the online text already on the LMS)\n") catch {};
    } else if (p.held_text) |h| if (h.kept) w.writeAll("  Your online text on the LMS is kept as it is.\n") catch {};
    if (p.statement) |s| {
        const st = text.collapse(app.gpa, s);
        if (st.len > 0) w.print("\n  Statement accepted for you: \"{s}\"\n", .{preview(app, st)}) catch {} else w.writeAll("\n  The submission statement is accepted for you.\n") catch {};
    }
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn preview(app: *App, s: []const u8) []const u8 {
    const one = text.collapse(app.gpa, s);
    if (one.len <= 90) return one;
    var end: usize = 87;
    while (end > 0 and (one[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(app.gpa, "{s}...", .{one[0..end]}) catch one;
}

/// The only writes: draft uploads, the save, and (for draft-keeping assignments) the submit
/// for grading. Files are rechecked first so what goes up is what the user saw.
fn execute(app: *App, m: *Moodle, p: Plan) Failed!void {
    for (p.files) |f| {
        const now = inspect(app, f.path);
        if (now != .file or now.file.size != f.size or !std.meta.eql(now.file.modified, f.modified))
            return app.fail("REFUSED", .refused, "{s} changed while you were confirming; nothing was submitted", .{f.path});
    }
    var itemid: ?i64 = null;
    for (p.files, 0..) |f, i| {
        const data = Io.Dir.cwd().readFileAlloc(app.io, f.path, app.gpa, .limited(f.size + 1)) catch |e|
            return app.fail("IO", .failure, "cannot read {s}: {s}; nothing was submitted", .{ f.path, @errorName(e) });
        if (data.len != f.size) return app.fail("REFUSED", .refused, "{s} changed while uploading; nothing was submitted", .{f.path});
        app.note("Uploading {s} ({s}, {d} of {d})...", .{ f.name, tf.size(app.gpa, f.size), i + 1, p.files.len });
        const d = try m.upload(f.name, data, itemid orelse 0);
        if (!std.mem.eql(u8, d.filename, f.name))
            return app.fail("BAD_RESPONSE", .failure, "the LMS stored {s} as {s}; nothing was submitted", .{ f.name, d.filename });
        itemid = d.itemid;
    }
    var args: std.ArrayList([2][]const u8) = .empty;
    args.append(app.gpa, .{ "assignmentid", idStr(app, p.assignment.id) }) catch {};
    if (itemid) |id| args.append(app.gpa, .{ "plugindata[files_filemanager]", idStr(app, id) }) catch {};
    if (p.editorText()) |e| {
        args.append(app.gpa, .{ "plugindata[onlinetext_editor][text]", e.text }) catch {};
        args.append(app.gpa, .{ "plugindata[onlinetext_editor][format]", idStr(app, e.format) }) catch {};
        args.append(app.gpa, .{ "plugindata[onlinetext_editor][itemid]", "0" }) catch {};
    }
    app.note("Saving the submission...", .{});
    try write(app, m, "mod_assign_save_submission", args.items, p.assignment.id);
    if (p.submit_for_grading) {
        app.note("Submitting for grading...", .{});
        try write(app, m, "mod_assign_submit_for_grading", &.{
            .{ "assignmentid", idStr(app, p.assignment.id) },
            .{ "acceptsubmissionstatement", "1" },
        }, p.assignment.id);
    }
}

/// A write answers with a `warnings` array; any entry means it did not happen.
fn write(app: *App, m: *Moodle, func: []const u8, args: []const [2][]const u8, id: i64) Failed!void {
    const v = m.callWrite(func, args) catch |e| {
        if (app.failure) |f| if (std.mem.eql(u8, f.code, "WRITE_UNKNOWN"))
            return app.fail("WRITE_UNKNOWN", .failure, "{s}\nIt's unclear whether the LMS saved it. Check before trying again:\n  nust lms status {d}", .{ f.message, id });
        return e;
    };
    const warnings: []const std.json.Value = if (v == .array) v.array.items else j.arr(v, "warnings");
    if (warnings.len == 0) return;
    var aw: Io.Writer.Allocating = .init(app.gpa);
    for (warnings) |wv| {
        const msg = j.str(wv, "message");
        const code = j.str(wv, "warningcode");
        aw.writer.print("\n  {s}{s}{s}{s}", .{ msg, if (code.len > 0) " (" else "", code, if (code.len > 0) ")" else "" }) catch {};
    }
    return app.fail("REJECTED", .failure, "The LMS refused the submission:{s}", .{aw.written()});
}
