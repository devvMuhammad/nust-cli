//! Turns what the user typed (`CS-405`, `deep`, `1930`, `cs-484/assignment 1`) into one record.
//! Several matches is an error that lists them, never a guess.
const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const model = @import("model.zig");
const text = @import("../text.zig");

fn exact(names: []const []const u8, q: []const u8) bool {
    for (names) |n| if (n.len > 0 and std.ascii.eqlIgnoreCase(n, q)) return true;
    return false;
}

fn fragment(names: []const []const u8, q: []const u8) bool {
    for (names) |n| if (text.containsIgnoreCase(n, q)) return true;
    return false;
}

fn courseNames(c: model.CourseRef) [3][]const u8 {
    return .{ c.code, c.title, c.full_name };
}

pub fn course(app: *App, list: []const model.Course, query_in: []const u8) Failed!model.Course {
    const q = std.mem.trim(u8, query_in, " \t");
    if (std.fmt.parseInt(i64, q, 10)) |id| {
        for (list) |c| if (c.id == id) return c;
    } else |_| {}
    var exacts: std.ArrayList(model.Course) = .empty;
    var frags: std.ArrayList(model.Course) = .empty;
    for (list) |c| {
        const n = courseNames(c.ref());
        if (exact(&n, q)) exacts.append(app.gpa, c) catch {};
        if (fragment(&n, q)) frags.append(app.gpa, c) catch {};
    }
    const found = if (exacts.items.len == 1) exacts.items else frags.items;
    if (found.len == 1) return found[0];
    if (found.len == 0) return app.fail("NOT_FOUND", .usage, "no LMS course matches \"{s}\"; see `nust lms courses`", .{q});
    var aw: std.Io.Writer.Allocating = .init(app.gpa);
    for (found) |c| aw.writer.print("\n  {s:<6}  {s}", .{ idText(app, c.id), c.ref().label(app.gpa) }) catch {};
    return app.fail("AMBIGUOUS", .usage, "\"{s}\" matches {d} courses:{s}\nUse the id or a longer name.", .{ q, found.len, aw.written() });
}

/// `query` is an assignment id, a name fragment, or `course/name` to narrow the search.
pub fn assignment(app: *App, list: []const model.Assignment, query_in: []const u8) Failed!model.Assignment {
    const q = std.mem.trim(u8, query_in, " \t");
    if (std.fmt.parseInt(i64, q, 10)) |id| {
        for (list) |a| if (a.id == id) return a;
    } else |_| {}
    var scope: []const model.Assignment = list;
    var name = q;
    if (std.mem.findScalar(u8, q, '/')) |slash| {
        const cq = std.mem.trim(u8, q[0..slash], " ");
        var in_course: std.ArrayList(model.Assignment) = .empty;
        for (list) |a| {
            const n = courseNames(a.course);
            if (exact(&n, cq) or fragment(&n, cq)) in_course.append(app.gpa, a) catch {};
        }
        if (in_course.items.len > 0) {
            scope = in_course.items;
            name = std.mem.trim(u8, q[slash + 1 ..], " ");
        }
    }
    var exacts: std.ArrayList(model.Assignment) = .empty;
    var frags: std.ArrayList(model.Assignment) = .empty;
    for (scope) |a| {
        if (exact(&.{a.name}, name)) exacts.append(app.gpa, a) catch {};
        if (fragment(&.{a.name}, name)) frags.append(app.gpa, a) catch {};
    }
    const found = if (exacts.items.len == 1) exacts.items else frags.items;
    if (found.len == 1) return found[0];
    if (found.len == 0) return app.fail("NOT_FOUND", .usage, "no assignment matches \"{s}\"; see `nust lms assignments`", .{q});
    var aw: std.Io.Writer.Allocating = .init(app.gpa);
    for (found) |a| aw.writer.print("\n  {s:<6}  {s:<8}  {s}", .{ idText(app, a.id), a.course.code, a.name }) catch {};
    return app.fail("AMBIGUOUS", .usage, "\"{s}\" matches {d} assignments:{s}\nUse the id, or narrow it like \"CS-405/lab 6\".", .{ q, found.len, aw.written() });
}

fn idText(app: *App, id: i64) []const u8 {
    return std.fmt.allocPrint(app.gpa, "{d}", .{id}) catch "?";
}
