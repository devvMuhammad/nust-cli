//! `nust qalam ...`. Read-only: every command is a GET of one or more portal pages.
const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Clients = @import("../clients.zig").Clients;
const parse = @import("parse.zig");
const Qalam = @import("client.zig").Qalam;
const Table = @import("../table.zig").Table;
const orDash = @import("../table.zig").orDash;
const text = @import("../text.zig");

fn num(app: *App, v: ?f64) []const u8 {
    const x = v orelse return "-";
    if (x == @round(x)) return std.fmt.allocPrint(app.gpa, "{d}", .{@as(i64, @intFromFloat(x))}) catch "-";
    return std.fmt.allocPrint(app.gpa, "{d:.2}", .{x}) catch "-";
}

fn changed(app: *App, what: []const u8, e: anyerror) Failed {
    return switch (e) {
        error.DataInconsistent => app.fail("DATA_INCONSISTENT", .failure, "Qalam returned inconsistent {s} numbers", .{what}),
        else => app.fail("PORTAL_CHANGED", .failure, "the Qalam {s} page has changed and could not be read; the parser needs an update", .{what}),
    };
}

pub fn fetchCourses(app: *App, q: *Qalam) Failed![]const parse.Course {
    const page = try q.get("/student/dashboard");
    return parse.dashboardCourses(app.gpa, page.doc) catch |e| changed(app, "dashboard", e);
}

/// Course id, code (`CS-405`), or part of the name. Several matches is an error.
fn pick(app: *App, list: []const parse.Course, query_in: []const u8) Failed!parse.Course {
    const q = std.mem.trim(u8, query_in, " ");
    var exact: std.ArrayList(parse.Course) = .empty;
    var frag: std.ArrayList(parse.Course) = .empty;
    for (list) |c| {
        if (std.mem.eql(u8, c.id, q) or std.ascii.eqlIgnoreCase(c.code, q) or std.ascii.eqlIgnoreCase(c.name, q)) exact.append(app.gpa, c) catch {};
        if (text.containsIgnoreCase(c.name, q) or text.containsIgnoreCase(c.code, q)) frag.append(app.gpa, c) catch {};
    }
    const found = if (exact.items.len == 1) exact.items else frag.items;
    if (found.len == 1) return found[0];
    if (found.len == 0) return app.fail("NOT_FOUND", .usage, "no Qalam course matches \"{s}\"; see `nust qalam courses`", .{q});
    var aw: std.Io.Writer.Allocating = .init(app.gpa);
    for (found) |c| aw.writer.print("\n  {s:<8}  {s}", .{ c.code, c.name }) catch {};
    return app.fail("AMBIGUOUS", .usage, "\"{s}\" matches {d} courses:{s}", .{ q, found.len, aw.written() });
}

pub fn courses(app: *App, c: *Clients) Failed!void {
    const list = try fetchCourses(app, try c.qalam());
    if (app.json) return app.emitJson(list);
    var t = Table.init(app.gpa, &.{ "CODE", "COURSE", "CREDITS", "ATTENDANCE", "INSTRUCTOR" });
    for (list) |x| t.row(&.{
        orDash(x.code),
        x.name,
        num(app, x.credit_hours),
        if (x.attendance_percent) |p| std.fmt.allocPrint(app.gpa, "{d:.1}%", .{p}) catch "-" else "-",
        orDash(x.instructor),
    });
    t.write(app.out, "");
}

pub fn attendance(app: *App, c: *Clients, course_q: ?[]const u8) Failed!void {
    const q = try c.qalam();
    const all = try fetchCourses(app, q);
    const selected: []const parse.Course = if (course_q) |cq| &.{try pick(app, all, cq)} else all;
    const Entry = struct { course: parse.Course, components: []const parse.Attendance, combined_percent: ?f64, @"error": ?[]const u8 = null };
    var entries: std.ArrayList(Entry) = .empty;
    for (selected) |course| {
        const path = std.fmt.allocPrint(app.gpa, "/student/course/attendance/{s}", .{course.id}) catch continue;
        // With several courses, one unreadable page is reported in its row, not fatal.
        const page = q.get(path) catch |e| {
            if (course_q != null or isFatal(app.failure.?.code)) return e;
            entries.append(app.gpa, .{ .course = course, .components = &.{}, .combined_percent = null, .@"error" = app.failure.?.message }) catch {};
            app.failure = null;
            continue;
        };
        const comps = parse.attendance(app.gpa, page.doc) catch |e| {
            if (course_q != null) return changed(app, "attendance", e);
            entries.append(app.gpa, .{ .course = course, .components = &.{}, .combined_percent = null, .@"error" = "the page could not be read" }) catch {};
            continue;
        };
        var att: u32 = 0;
        var con: u32 = 0;
        var complete = true;
        for (comps) |x| {
            if (x.attended == null or x.conducted == null) complete = false else {
                att += x.attended.?;
                con += x.conducted.?;
            }
        }
        const combined: ?f64 = if (complete and con > 0) @round(10000.0 * @as(f64, @floatFromInt(att)) / @as(f64, @floatFromInt(con))) / 100.0 else null;
        entries.append(app.gpa, .{ .course = course, .components = comps, .combined_percent = combined }) catch {};
    }
    if (app.json) return app.emitJson(entries.items);
    var t = Table.init(app.gpa, &.{ "COURSE", "PART", "ATTENDED", "%", "ABSENT ON" });
    for (entries.items) |e| {
        if (e.@"error") |msg| {
            t.row(&.{ if (e.course.code.len > 0) e.course.code else e.course.name, "", "?", "-", msg });
            continue;
        }
        for (e.components, 0..) |x, i| {
            const label = if (i == 0) (if (e.course.code.len > 0) e.course.code else e.course.name) else "";
            if (x.not_marked) {
                t.row(&.{ label, x.component, "not marked yet", "-", "" });
                continue;
            }
            const absent = if (course_q != null)
                std.mem.join(app.gpa, ", ", x.absent_on) catch ""
            else if (x.absent_on.len > 0) std.fmt.allocPrint(app.gpa, "{d} class{s}", .{ x.absent_on.len, if (x.absent_on.len == 1) "" else "es" }) catch "" else "";
            t.row(&.{
                label,
                x.component,
                std.fmt.allocPrint(app.gpa, "{d}/{d}", .{ x.attended.?, x.conducted.? }) catch "",
                if (x.percent) |p| std.fmt.allocPrint(app.gpa, "{d:.2}", .{p}) catch "-" else "-",
                absent,
            });
        }
    }
    t.write(app.out, "");
}

fn isFatal(code: []const u8) bool {
    inline for (.{ "AUTH_REQUIRED", "LOGIN_FAILED", "NETWORK", "NO_TERMINAL", "FEEDBACK_REQUIRED", "BROWSER_CHECK" }) |c| if (std.mem.eql(u8, code, c)) return true;
    return false;
}

/// `Lab 2` before `Lab 11`: digit runs compare as numbers.
fn naturalLess(_: void, a: parse.Mark, b: parse.Mark) bool {
    var i: usize = 0;
    var k: usize = 0;
    const x = a.name;
    const y = b.name;
    while (i < x.len and k < y.len) {
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[k])) {
            var ie = i;
            while (ie < x.len and std.ascii.isDigit(x[ie])) ie += 1;
            var ke = k;
            while (ke < y.len and std.ascii.isDigit(y[ke])) ke += 1;
            const nx = std.fmt.parseInt(u64, x[i..ie], 10) catch 0;
            const ny = std.fmt.parseInt(u64, y[k..ke], 10) catch 0;
            if (nx != ny) return nx < ny;
            i = ie;
            k = ke;
            continue;
        }
        const cx = std.ascii.toLower(x[i]);
        const cy = std.ascii.toLower(y[k]);
        if (cx != cy) return cx < cy;
        i += 1;
        k += 1;
    }
    return x.len - i < y.len - k;
}

pub fn grades(app: *App, c: *Clients, course_q: []const u8, filter: ?[]const u8) Failed!void {
    const q = try c.qalam();
    const course = try pick(app, try fetchCourses(app, q), course_q);
    const path = std.fmt.allocPrint(app.gpa, "/student/course/gradebook/{s}", .{course.id}) catch "";
    const page = try q.get(path);
    const comps = parse.gradebook(app.gpa, page.doc) catch |e| return changed(app, "gradebook", e);
    // Filter like "quiz", "Quiz 2", "midterm" against category and assessment names.
    var shown: std.ArrayList(parse.Component) = .empty;
    for (comps) |comp| {
        var cats: std.ArrayList(parse.Category) = .empty;
        for (comp.categories) |cat| {
            if (filter) |f| {
                if (text.containsIgnoreCase(cat.name, f)) {
                    cats.append(app.gpa, cat) catch {};
                    continue;
                }
                var marks: std.ArrayList(parse.Mark) = .empty;
                for (cat.marks) |mk| if (text.containsIgnoreCase(mk.name, f)) marks.append(app.gpa, mk) catch {};
                if (marks.items.len > 0) {
                    var cc = cat;
                    cc.marks = marks.items;
                    cats.append(app.gpa, cc) catch {};
                }
            } else cats.append(app.gpa, cat) catch {};
        }
        shown.append(app.gpa, .{ .component = comp.component, .categories = cats.items }) catch {};
    }
    if (app.json) return app.emitJson(.{ .course = course, .filter = filter, .components = shown.items });
    app.print("{s} {s}\n", .{ course.code, course.name });
    var any = false;
    var any_unmarked = false;
    for (shown.items) |comp| {
        if (comp.categories.len == 0) continue;
        any = true;
        if (shown.items.len > 1) app.print("\n{s}\n", .{comp.component});
        for (comp.categories) |cat| {
            app.print("\n  {s}{s}{s}{s}  (you: {s}%)\n", .{
                cat.name,
                if (cat.weight_percent != null) ", weight " else "",
                if (cat.weight_percent != null) num(app, cat.weight_percent) else "",
                if (cat.weight_percent != null) "%" else "",
                num(app, cat.obtained_percent),
            });
            var t = Table.init(app.gpa, &.{ "ASSESSMENT", "MARKS", "OUT OF", "CLASS AVG" });
            const sorted = app.gpa.dupe(parse.Mark, cat.marks) catch cat.marks;
            std.mem.sort(parse.Mark, @constCast(sorted), {}, naturalLess);
            for (sorted) |mk| {
                if (mk.likely_unmarked) any_unmarked = true;
                t.row(&.{ mk.name, if (mk.likely_unmarked) "-" else num(app, mk.obtained), num(app, mk.max), if (mk.likely_unmarked) "-" else num(app, mk.class_average) });
            }
            t.write(app.out, "    ");
        }
    }
    if (!any) return app.print("\nNo marks yet{s}.\n", .{if (filter != null) " matching that" else ""});
    if (any_unmarked) app.print("\n- means not marked yet (Qalam shows 0 for those).\n", .{});
}

pub fn results(app: *App, c: *Clients) Failed!void {
    const q = try c.qalam();
    const page = try q.get("/student/results/");
    const terms = parse.results(app.gpa, page.doc) catch |e| return changed(app, "results", e);
    if (app.json) return app.emitJson(terms);
    if (terms.len == 0) return app.print("No results published yet.\n", .{});
    for (terms) |t| {
        app.print("{s}   SGPA {s}   CGPA {s}   credits {s}\n", .{ t.term, num(app, t.sgpa), num(app, t.cgpa), num(app, t.earned_credits) });
        var tb = Table.init(app.gpa, &.{ "COURSE", "CREDITS", "GRADE" });
        for (t.courses) |cr| tb.row(&.{ cr.course, num(app, cr.credit_hours), orDash(cr.grade) });
        tb.write(app.out, "  ");
        app.print("\n", .{});
    }
}

pub fn timetable(app: *App, c: *Clients) Failed!void {
    const q = try c.qalam();
    const page = try q.get("/student/class/schedule");
    const s = parse.timetable(app.gpa, page.doc) catch |e| return changed(app, "timetable", e);
    if (app.json) return app.emitJson(s);
    if (s.classes.len == 0) return app.print("No classes on the timetable.\n", .{});
    // Back-to-back hours of the same class are one block.
    var merged: std.ArrayList(parse.Class) = .empty;
    for (s.classes) |cl0| {
        var cl = cl0;
        cl.room = text.replaceAll(app.gpa, text.replaceAll(app.gpa, text.collapse(app.gpa, cl.room), "( ", "("), " )", ")");
        if (merged.items.len > 0) {
            const prev = &merged.items[merged.items.len - 1];
            if (std.mem.eql(u8, prev.day, cl.day) and std.mem.eql(u8, prev.end, cl.start) and std.mem.eql(u8, prev.course, cl.course) and
                std.mem.eql(u8, prev.room, cl.room) and std.mem.eql(u8, prev.instructor, cl.instructor))
            {
                prev.end = cl.end;
                continue;
            }
        }
        merged.append(app.gpa, cl) catch {};
    }
    var last_day: []const u8 = "";
    var t = Table.init(app.gpa, &.{ "DAY", "TIME", "COURSE", "ROOM", "INSTRUCTOR" });
    for (merged.items) |cl| {
        const day = if (std.mem.eql(u8, cl.day, last_day)) "" else cl.day;
        last_day = cl.day;
        t.row(&.{ day, std.fmt.allocPrint(app.gpa, "{s}-{s}", .{ cl.start, cl.end }) catch "", cl.course, orDash(cl.room), orDash(cl.instructor) });
    }
    if (s.term.len > 0) app.print("{s}\n\n", .{s.term});
    t.write(app.out, "");
}

pub fn invoices(app: *App, c: *Clients) Failed!void {
    const q = try c.qalam();
    const page = try q.get("/student/invoices");
    const list = parse.invoices(app.gpa, page.doc) catch |e| return changed(app, "invoices", e);
    if (app.json) return app.emitJson(list);
    if (list.len == 0) return app.print("No invoices.\n", .{});
    var t = Table.init(app.gpa, &.{ "ISSUED", "DUE", "TERM", "TYPE", "CHALLAN", "AMOUNT", "STATUS", "PAID ON" });
    var unpaid: usize = 0;
    for (list) |inv| {
        if (!std.ascii.eqlIgnoreCase(inv.status, "Paid")) unpaid += 1;
        t.row(&.{ inv.invoice_date, orDash(inv.due_date), inv.term, inv.kind, inv.challan_id, num(app, inv.payable_amount), inv.status, orDash(inv.paid_date) });
    }
    t.write(app.out, "");
    if (unpaid > 0) app.print("\n{d} not paid. Pay or print challans on Qalam: https://qalam.nust.edu.pk/student/invoices\n", .{unpaid});
}
