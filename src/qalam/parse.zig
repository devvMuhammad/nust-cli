//! Reads Qalam's server-rendered pages. Missing marks stay null; nothing is estimated. Each
//! parser returns `error.PortalChanged` when the page does not have the shape it expects.
const std = @import("std");
const Allocator = std.mem.Allocator;
const html = @import("../html.zig");
const Node = html.Node;
const text = @import("../text.zig");

pub const PageState = enum { content, login, challenge };

pub fn pageState(gpa: Allocator, doc: *const Node, raw: []const u8) PageState {
    const titles = doc.byTag(gpa, "title");
    const title = if (titles.len > 0) titles[0].textContent(gpa) else "";
    if (text.containsIgnoreCase(title, "just a moment") or std.mem.find(u8, raw, "cf-chl") != null or
        std.ascii.findIgnoreCase(raw, "verify you are human") != null or
        std.ascii.findIgnoreCase(raw, "performing security verification") != null)
        return .challenge;
    for (doc.byTag(gpa, "input")) |i| {
        if (std.ascii.eqlIgnoreCase(i.attr("type") orelse "", "password")) return .login;
    }
    return .content;
}

/// A page only signed-in students see links to their own area.
pub fn isStudentPage(gpa: Allocator, doc: *const Node) bool {
    for (doc.byTag(gpa, "a")) |a| {
        const href = a.attr("href") orelse continue;
        if (std.mem.find(u8, href, "/student/") != null or std.mem.find(u8, href, "/web/session/logout") != null) return true;
    }
    return false;
}

pub fn csrfToken(gpa: Allocator, doc: *const Node) ?[]const u8 {
    for (doc.byTag(gpa, "input")) |i| {
        if (std.mem.eql(u8, i.attr("name") orelse "", "csrf_token")) {
            const v = i.attr("value") orelse return null;
            return if (v.len > 0) v else null;
        }
    }
    return null;
}

/// `89.0`, `89.0 %`, `1,200` -> number; `-`, blank, words -> null.
pub fn number(s_in: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (std.mem.trim(u8, s_in, " \t\r\n%")) |c| {
        if (c == ',') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    const s = std.mem.trim(u8, buf[0..n], " %");
    if (s.len == 0) return null;
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+')) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

// ---- dashboard ----

pub const Course = struct {
    id: []const u8,
    name: []const u8,
    code: []const u8 = "",
    instructor: []const u8 = "",
    credit_hours: ?f64 = null,
    attendance_percent: ?f64 = null,
    term: []const u8 = "",
};

fn courseIdFrom(href: []const u8, kinds: []const []const u8) ?[]const u8 {
    for (kinds) |k| {
        if (std.mem.startsWith(u8, href, k)) {
            const rest = std.mem.trimEnd(u8, href[k.len..], "/");
            if (rest.len == 0) return null;
            for (rest) |c| if (!std.ascii.isDigit(c)) return null;
            return rest;
        }
    }
    return null;
}

/// Labelled value inside `<b>Label :</b> <span>value</span>` style markup.
fn labelled(gpa: Allocator, scope: *const Node, label: []const u8) ?[]const u8 {
    for (scope.byTag(gpa, "b")) |b| {
        const t = b.textContent(gpa);
        if (!text.containsIgnoreCase(t, label)) continue;
        for (b.nextSiblings(gpa)) |sib| {
            if (sib.is("span")) return sib.textContent(gpa);
        }
    }
    return null;
}

fn hasLabel(gpa: Allocator, scope: *const Node, label: []const u8) bool {
    for (scope.byTag(gpa, "b")) |b| if (text.containsIgnoreCase(b.textContent(gpa), label)) return true;
    return false;
}

pub fn dashboardCourses(gpa: Allocator, doc: *const Node) ![]const Course {
    var out: std.ArrayList(Course) = .empty;
    for (doc.byTag(gpa, "a")) |a| {
        const href = a.attr("href") orelse continue;
        const id = courseIdFrom(href, &.{"/student/course/info/"}) orelse continue;
        const card = a.firstClass(gpa, "card") orelse continue;
        var dup = false;
        for (out.items) |c| if (std.mem.eql(u8, c.id, id)) {
            dup = true;
        };
        if (dup) continue;
        const header = card.firstClass(gpa, "card-header");
        const name = if (header) |h| h.textContent(gpa) else a.textContent(gpa);
        if (name.len == 0) continue;
        var c: Course = .{ .id = id, .name = name };
        if (card.firstClass(gpa, "card-title")) |t| c.instructor = t.textContent(gpa);
        if (card.firstClass(gpa, "sub-heading")) |t| c.code = t.textContent(gpa);
        if (labelled(gpa, card, "Credit")) |v| c.credit_hours = number(v);
        // `Attendance: <span>89.0</span>%`
        for (card.byClass(gpa, "uk-text-small")) |d| {
            const t = d.textContent(gpa);
            if (std.mem.startsWith(u8, t, "Attendance")) {
                const spans = d.childrenTagged(gpa, "span");
                if (spans.len > 0) c.attendance_percent = number(spans[0].textContent(gpa));
                if (spans.len > 0) {
                    const last = spans[spans.len - 1];
                    if (last.hasClass("uk-text-small")) c.term = last.textContent(gpa);
                }
            }
        }
        try out.append(gpa, c);
    }
    if (out.items.len == 0) return error.PortalChanged;
    return out.items;
}

// ---- tabbed course pages ----

/// The `uk-tab` labels and the `#tabs_anim1` panels they switch between.
const Panels = struct { labels: []const []const u8, panels: []const *Node };

fn panels(gpa: Allocator, doc: *const Node) Panels {
    const switcher = doc.byId(gpa, "tabs_anim1") orelse return .{ .labels = &.{}, .panels = &.{} };
    var labels: std.ArrayList([]const u8) = .empty;
    for (doc.byClass(gpa, "uk-tab")) |tab| {
        const connect = tab.attr("data-uk-tab") orelse "";
        if (std.mem.find(u8, connect, "tabs_anim1") == null) continue;
        for (tab.childrenTagged(gpa, "li")) |li| {
            if (li.hasClass("uk-tab-responsive")) continue;
            labels.append(gpa, li.textContent(gpa)) catch {};
        }
        break;
    }
    return .{ .labels = labels.items, .panels = switcher.childrenTagged(gpa, "li") };
}

/// `Deep Learning (CS-405-Fall-26-SEECS/BSE/2023F-A-Lab)` -> `Lab`; `Lecture` stays `Lecture`.
pub fn componentName(label: []const u8) []const u8 {
    const open = std.mem.findScalarLast(u8, label, '(') orelse return label;
    const inner = std.mem.trimEnd(u8, label[open + 1 ..], ") ");
    const dash = std.mem.findScalarLast(u8, inner, '-') orelse return inner;
    return inner[dash + 1 ..];
}

pub const Attendance = struct {
    component: []const u8,
    attended: ?u32 = null,
    conducted: ?u32 = null,
    percent: ?f64 = null,
    /// Dates of classes marked absent, as Qalam lists them (`2026-10-19`).
    absent_on: []const []const u8 = &.{},
    not_marked: bool = false,
};

pub fn attendance(gpa: Allocator, doc: *const Node) ![]const Attendance {
    const p = panels(gpa, doc);
    var out: std.ArrayList(Attendance) = .empty;
    const scopes: []const *const Node = if (p.panels.len > 0) p.panels else &.{doc};
    for (scopes, 0..) |panel, i| {
        var a: Attendance = .{ .component = if (i < p.labels.len) componentName(p.labels[i]) else "Course" };
        // Unmarked courses show the labels with no numbers next to them.
        const saw_labels = hasLabel(gpa, panel, "classes Conducted") and hasLabel(gpa, panel, "classes Attended");
        if (labelled(gpa, panel, "classes Conducted")) |v| {
            if (number(v)) |n| a.conducted = @intFromFloat(n);
        }
        if (labelled(gpa, panel, "classes Attended")) |v| {
            if (number(v)) |n| a.attended = @intFromFloat(n);
        }
        if (a.attended != null and a.conducted != null) {
            if (a.attended.? > a.conducted.?) return error.DataInconsistent;
            if (a.conducted.? > 0) a.percent = @round(10000.0 * @as(f64, @floatFromInt(a.attended.?)) / @as(f64, @floatFromInt(a.conducted.?))) / 100.0;
        } else if (saw_labels) {
            a.not_marked = true;
        } else continue;
        var absent: std.ArrayList([]const u8) = .empty;
        for (panel.byTag(gpa, "tr")) |tr| {
            const tds = tr.childrenTagged(gpa, "td");
            if (tds.len < 3) continue;
            if (std.ascii.eqlIgnoreCase(tds[2].textContent(gpa), "Absent")) absent.append(gpa, tds[1].textContent(gpa)) catch {};
        }
        a.absent_on = absent.items;
        try out.append(gpa, a);
    }
    if (out.items.len == 0) return error.PortalChanged;
    return out.items;
}

// ---- gradebook ----

pub const Mark = struct {
    name: []const u8,
    max: ?f64 = null,
    obtained: ?f64 = null,
    class_average: ?f64 = null,
    percent: ?f64 = null,
    /// Qalam shows 0 for assessments that have not been marked; a 0 with a 0 class average is almost always that.
    likely_unmarked: bool = false,
};

pub const Category = struct {
    name: []const u8,
    weight_percent: ?f64 = null,
    /// Qalam's own "Obtained Percentage" for the category.
    obtained_percent: ?f64 = null,
    marks: []const Mark = &.{},
};

pub const Component = struct {
    component: []const u8,
    categories: []const Category,
};

fn cellTexts(gpa: Allocator, tr: *const Node) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (tr.elements(gpa)) |c| {
        if (c.is("td") or c.is("th")) out.append(gpa, c.textContent(gpa)) catch {};
    }
    return out.items;
}

fn headerIndex(headers: []const []const u8, names: []const []const u8) ?usize {
    for (headers, 0..) |h, i| {
        for (names) |n| if (text.containsIgnoreCase(h, n)) return i;
    }
    return null;
}

fn at(values: []const []const u8, i: ?usize) ?f64 {
    const k = i orelse return null;
    return if (k < values.len) number(values[k]) else null;
}

/// One `table_tree` table: parent rows with their child header and child rows.
pub const TreeGroup = struct {
    parent: *const Node,
    cells: []const []const u8,
    child_headers: []const []const u8,
    children: []const []const []const u8,
};

pub fn treeGroups(gpa: Allocator, table: *const Node) []const TreeGroup {
    var out: std.ArrayList(TreeGroup) = .empty;
    for (table.byClass(gpa, "table-parent-row")) |parent| {
        var headers: []const []const u8 = &.{};
        var rows: std.ArrayList([]const []const u8) = .empty;
        for (parent.nextSiblings(gpa)) |sib| {
            if (!sib.is("tr") or !sib.hasClass("table-child-row")) break;
            if (sib.childrenTagged(gpa, "th").len > 0) {
                headers = cellTexts(gpa, sib);
                continue;
            }
            rows.append(gpa, cellTexts(gpa, sib)) catch {};
        }
        out.append(gpa, .{ .parent = parent, .cells = cellTexts(gpa, parent), .child_headers = headers, .children = rows.items }) catch {};
    }
    return out.items;
}

pub fn gradebook(gpa: Allocator, doc: *const Node) ![]const Component {
    const p = panels(gpa, doc);
    var out: std.ArrayList(Component) = .empty;
    var tables_seen: usize = 0;
    const scopes: []const *const Node = if (p.panels.len > 0) p.panels else &.{doc};
    for (scopes, 0..) |panel, pi| {
        var cats: std.ArrayList(Category) = .empty;
        for (panel.byClass(gpa, "table_tree")) |table| {
            tables_seen += 1;
            for (treeGroups(gpa, table)) |g| {
                const first_cell = g.parent.childrenTagged(gpa, "td");
                if (first_cell.len == 0) continue;
                var weight: ?f64 = null;
                var name = first_cell[0].textContent(gpa);
                if (first_cell[0].firstClass(gpa, "uk-badge")) |badge| {
                    const bt = badge.textContent(gpa);
                    weight = number(bt);
                    if (std.mem.find(u8, name, bt)) |k| name = std.mem.trim(u8, name[0..k], " ");
                }
                var marks: std.ArrayList(Mark) = .empty;
                const h = g.child_headers;
                const i_max = headerIndex(h, &.{ "Max", "Total" }) orelse if (h.len == 0) @as(?usize, 1) else null;
                const i_obt = headerIndex(h, &.{"Obtained"}) orelse if (h.len == 0) @as(?usize, 2) else null;
                const i_avg = headerIndex(h, &.{"Average"}) orelse if (h.len == 0) @as(?usize, 3) else null;
                const i_pct = headerIndex(h, &.{"Percentage"}) orelse if (h.len == 0) @as(?usize, 4) else null;
                for (g.children) |row| {
                    if (row.len < 3) continue;
                    var m: Mark = .{ .name = row[0], .max = at(row, i_max), .obtained = at(row, i_obt), .class_average = at(row, i_avg), .percent = at(row, i_pct) };
                    m.likely_unmarked = (m.obtained orelse 0) == 0 and (m.class_average orelse 0) == 0;
                    marks.append(gpa, m) catch {};
                }
                cats.append(gpa, .{
                    .name = name,
                    .weight_percent = weight,
                    .obtained_percent = if (g.cells.len > 1) number(g.cells[1]) else null,
                    .marks = marks.items,
                }) catch {};
            }
        }
        try out.append(gpa, .{ .component = if (pi < p.labels.len) componentName(p.labels[pi]) else "Course", .categories = cats.items });
    }
    if (tables_seen == 0) return error.PortalChanged;
    return out.items;
}

// ---- results ----

pub const CourseResult = struct {
    course: []const u8,
    credit_hours: ?f64 = null,
    grade_points: ?f64 = null,
    grade: []const u8 = "",
};

pub const Term = struct {
    term: []const u8,
    sgpa: ?f64 = null,
    cgpa: ?f64 = null,
    attempted_credits: ?f64 = null,
    earned_credits: ?f64 = null,
    cumulative_credits: ?f64 = null,
    courses: []const CourseResult = &.{},
};

/// The "Previous Courses" transcript table: one group per term.
pub fn results(gpa: Allocator, doc: *const Node) ![]const Term {
    var out: std.ArrayList(Term) = .empty;
    for (doc.byClass(gpa, "table_tree")) |table| {
        const ths = table.byTag(gpa, "thead");
        if (ths.len == 0) continue;
        const heads = blk: {
            const rows = ths[0].byTag(gpa, "tr");
            if (rows.len == 0) continue;
            break :blk cellTexts(gpa, rows[0]);
        };
        if (headerIndex(heads, &.{"SGPA"}) == null) continue;
        const i_sgpa = headerIndex(heads, &.{"Current SGPA"});
        const i_cgpa = headerIndex(heads, &.{"Current CGPA"});
        const i_att = headerIndex(heads, &.{"Attempted CH"});
        const i_earn = headerIndex(heads, &.{"Earned CH"});
        const i_cum = headerIndex(heads, &.{"Cumulative CH"});
        for (treeGroups(gpa, table)) |g| {
            if (g.cells.len == 0) continue;
            const h = g.child_headers;
            const c_ch = headerIndex(h, &.{"Credit"}) orelse 1;
            const c_gp = headerIndex(h, &.{"Grade Pts"}) orelse 2;
            const c_gr = headerIndex(h, &.{"Final Grade"}) orelse 3;
            var courses: std.ArrayList(CourseResult) = .empty;
            for (g.children) |row| {
                if (row.len == 0) continue;
                courses.append(gpa, .{
                    .course = row[0],
                    .credit_hours = at(row, c_ch),
                    .grade_points = at(row, c_gp),
                    .grade = if (c_gr < row.len) row[c_gr] else "",
                }) catch {};
            }
            try out.append(gpa, .{
                .term = g.cells[0],
                .sgpa = at(g.cells, i_sgpa),
                .cgpa = at(g.cells, i_cgpa),
                .attempted_credits = at(g.cells, i_att),
                .earned_credits = at(g.cells, i_earn),
                .cumulative_credits = at(g.cells, i_cum),
                .courses = courses.items,
            });
        }
    }
    if (out.items.len == 0 and doc.byClass(gpa, "table_tree").len == 0) return error.PortalChanged;
    return out.items;
}

// ---- timetable ----

pub const Class = struct {
    day: []const u8,
    start: []const u8,
    end: []const u8,
    course: []const u8,
    section: []const u8 = "",
    room: []const u8 = "",
    instructor: []const u8 = "",
};

pub const Schedule = struct {
    term: []const u8 = "",
    classes: []const Class,
};

pub fn timetable(gpa: Allocator, doc: *const Node) !Schedule {
    var out: std.ArrayList(Class) = .empty;
    const groups = doc.byClass(gpa, "cd-schedule__group");
    if (groups.len == 0 and doc.byClass(gpa, "cd-schedule").len == 0) return error.PortalChanged;
    for (groups) |g| {
        const info = g.firstClass(gpa, "cd-schedule__top-info") orelse continue;
        const day = info.textContent(gpa);
        for (g.byClass(gpa, "cd-schedule__event")) |ev| {
            const a = ev.firstTag(gpa, "a") orelse continue;
            var c: Class = .{ .day = day, .start = a.attr("data-start") orelse "", .end = a.attr("data-end") orelse "", .course = "" };
            if (a.firstTag(gpa, "em")) |em| c.instructor = em.textContent(gpa);
            var fields: std.ArrayList([]const u8) = .empty;
            for (a.childrenTagged(gpa, "span")) |sp| {
                const t = sp.textContent(gpa);
                if (t.len > 0) fields.append(gpa, t) catch {};
            }
            if (fields.items.len > 0) c.course = fields.items[0];
            if (fields.items.len > 1) c.section = fields.items[1];
            if (fields.items.len > 2) c.room = fields.items[2];
            try out.append(gpa, c);
        }
    }
    return .{ .term = labelled(gpa, doc, "Term") orelse "", .classes = out.items };
}

// ---- invoices ----

pub const Invoice = struct {
    invoice_date: []const u8 = "",
    due_date: []const u8 = "",
    term: []const u8 = "",
    kind: []const u8 = "",
    challan_id: []const u8 = "",
    scholarship_percent: ?f64 = null,
    payable_amount: ?f64 = null,
    status: []const u8 = "",
    paid_date: []const u8 = "",
};

pub fn invoices(gpa: Allocator, doc: *const Node) ![]const Invoice {
    for (doc.byTag(gpa, "table")) |table| {
        const thead = table.firstTag(gpa, "thead") orelse continue;
        const hrow = thead.firstTag(gpa, "tr") orelse continue;
        const h = cellTexts(gpa, hrow);
        const i_challan = headerIndex(h, &.{"Challan ID"}) orelse continue;
        var out: std.ArrayList(Invoice) = .empty;
        const tbody = table.firstTag(gpa, "tbody") orelse table;
        for (tbody.byTag(gpa, "tr")) |tr| {
            const v = cellTexts(gpa, tr);
            if (v.len < h.len - 2) continue;
            const get = struct {
                fn f(vals: []const []const u8, i: ?usize) []const u8 {
                    const k = i orelse return "";
                    if (k >= vals.len) return "";
                    return if (std.mem.eql(u8, vals[k], "-")) "" else vals[k];
                }
            }.f;
            try out.append(gpa, .{
                .invoice_date = get(v, headerIndex(h, &.{"Invoice Date"})),
                .due_date = get(v, headerIndex(h, &.{"Due Date"})),
                .term = get(v, headerIndex(h, &.{"Term"})),
                .kind = get(v, headerIndex(h, &.{"Challan Type"})),
                .challan_id = get(v, i_challan),
                .scholarship_percent = at(v, headerIndex(h, &.{"Scholarship"})),
                .payable_amount = at(v, headerIndex(h, &.{"Payable"})),
                .status = get(v, headerIndex(h, &.{"Status"})),
                .paid_date = get(v, headerIndex(h, &.{"Paid Date"})),
            });
        }
        return out.items;
    }
    return error.PortalChanged;
}

// ---- tests against real (trimmed) pages ----
// The pages are private (they hold someone's marks), so the tests check structure and
// consistency, never specific values. Without the pages they skip.

fn fixture(gpa: Allocator, name: []const u8) !*Node {
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(gpa, "tests/fixtures/qalam/{s}", .{name});
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return error.SkipZigTest;
    return html.parse(gpa, data);
}

/// Every saved page whose name starts with `prefix`, e.g. `course_attendance_`.
fn fixtures(gpa: Allocator, prefix: []const u8) ![]const *Node {
    const io = std.testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "tests/fixtures/qalam", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var out: std.ArrayList(*Node) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, prefix)) try out.append(gpa, try fixture(gpa, e.name));
    }
    if (out.items.len == 0) return error.SkipZigTest;
    return out.items;
}

fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    return true;
}

fn isClock(s: []const u8) bool {
    return s.len == 5 and s[2] == ':' and std.ascii.isDigit(s[0]) and std.ascii.isDigit(s[1]) and std.ascii.isDigit(s[3]) and std.ascii.isDigit(s[4]);
}

test "dashboard courses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try fixture(a, "dashboard.html");
    try std.testing.expect(isStudentPage(a, doc));
    const cs = try dashboardCourses(a, doc);
    try std.testing.expect(cs.len > 0);
    for (cs) |c| {
        for (c.id) |ch| try std.testing.expect(std.ascii.isDigit(ch));
        try std.testing.expect(c.name.len > 0 and c.instructor.len > 0 and c.term.len > 0);
        try std.testing.expect(std.mem.findScalar(u8, c.code, '-') != null);
        try std.testing.expect(c.credit_hours.? > 0);
        try std.testing.expect(c.attendance_percent.? >= 0 and c.attendance_percent.? <= 100);
    }
}

test "attendance pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var counted: usize = 0;
    for (try fixtures(a, "course_attendance_")) |doc| {
        const comps = try attendance(a, doc);
        try std.testing.expect(comps.len > 0);
        for (comps) |c| {
            try std.testing.expect(c.component.len > 0);
            if (c.not_marked) {
                try std.testing.expect(c.conducted == null and c.attended == null and c.percent == null);
                continue;
            }
            counted += 1;
            try std.testing.expect(c.attended.? <= c.conducted.?);
            try std.testing.expect(c.absent_on.len <= c.conducted.? - c.attended.?);
            for (c.absent_on) |d| try std.testing.expect(isDate(d));
            const want = @round(10000.0 * @as(f64, @floatFromInt(c.attended.?)) / @as(f64, @floatFromInt(c.conducted.?))) / 100.0;
            try std.testing.expectEqual(want, c.percent.?);
        }
    }
    try std.testing.expect(counted > 0);
}

test "gradebook pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try fixtures(a, "course_gradebook_")) |doc| {
        const comps = try gradebook(a, doc);
        try std.testing.expect(comps.len > 0);
        for (comps) |comp| for (comp.categories) |cat| {
            try std.testing.expect(cat.name.len > 0);
            if (cat.weight_percent) |w| try std.testing.expect(w > 0 and w <= 100);
            for (cat.marks) |m| {
                try std.testing.expect(m.name.len > 0 and m.max.? > 0);
                try std.testing.expect(m.obtained.? <= m.max.?);
                try std.testing.expectEqual(m.obtained.? == 0 and m.class_average.? == 0, m.likely_unmarked);
            }
        };
    }
}

test "results transcript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = try results(a, try fixture(a, "results.html"));
    try std.testing.expect(terms.len > 0);
    for (terms) |t| {
        try std.testing.expect(std.mem.findScalar(u8, t.term, ' ') != null);
        try std.testing.expect(t.sgpa.? >= 0 and t.sgpa.? <= 4 and t.cgpa.? >= 0 and t.cgpa.? <= 4);
        try std.testing.expect(t.courses.len > 0);
        for (t.courses) |c| {
            try std.testing.expect(c.course.len > 0 and c.grade.len > 0 and c.credit_hours.? > 0);
            // Entities are decoded: no raw `&amp;` survives.
            try std.testing.expect(std.mem.find(u8, c.course, "&amp;") == null);
        }
    }
}

test "timetable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try timetable(a, try fixture(a, "class_schedule.html"));
    try std.testing.expect(s.term.len > 0 and s.classes.len > 0);
    const days = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
    for (s.classes) |c| {
        var known = false;
        for (days) |d| known = known or std.mem.eql(u8, d, c.day);
        try std.testing.expect(known);
        try std.testing.expect(isClock(c.start) and isClock(c.end) and std.mem.order(u8, c.start, c.end) == .lt);
        try std.testing.expect(c.course.len > 0 and c.room.len > 0 and c.instructor.len > 0);
    }
}

test "invoices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inv = try invoices(a, try fixture(a, "invoices.html"));
    try std.testing.expect(inv.len > 0);
    for (inv) |i| {
        try std.testing.expect(isDate(i.invoice_date) and isDate(i.due_date));
        try std.testing.expect(i.term.len > 0 and i.challan_id.len > 0 and i.status.len > 0);
        if (i.paid_date.len > 0) try std.testing.expect(isDate(i.paid_date));
    }
}

test "login page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/qalam/web_login.html", a, .limited(1 << 20)) catch return error.SkipZigTest;
    const doc = try html.parse(a, data);
    try std.testing.expectEqual(PageState.login, pageState(a, doc, data));
    try std.testing.expectEqualStrings("testcsrf123", csrfToken(a, doc).?);
}

test "component names" {
    try std.testing.expectEqualStrings("Lab", componentName("Deep Learning (CS-405-Fall-26-SEECS/BSE/2023F-A-Lab)"));
    try std.testing.expectEqualStrings("Lecture", componentName("Lecture"));
    try std.testing.expectEqual(@as(?f64, 70.0), number(" 70.0 % "));
    try std.testing.expectEqual(@as(?f64, null), number("-"));
}
