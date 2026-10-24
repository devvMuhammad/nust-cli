//! nust: one command line for NUST's Qalam portal and LMS.
//! Parse arguments, dispatch, map failures to exit codes. No logic lives here.
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const build_options = @import("build_options");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Clients = @import("clients.zig").Clients;
const timefmt = @import("timefmt.zig");
const account = @import("account.zig");
const lms = @import("lms/cmds.zig");
const qalam = @import("qalam/cmds.zig");
const docs = @import("docs.zig");

const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    help: bool = false,
    all: bool = false,
    unread: bool = false,
    text: ?[]const u8 = null,
    download: ?[]const u8 = null,
    only: ?[]const u8 = null,
    lms_username: ?[]const u8 = null,
};

fn parseArgs(app: *App, argv: []const []const u8) Failed!Args {
    var a: Args = .{};
    var i: usize = 1;
    var rest = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (rest or arg.len < 2 or arg[0] != '-') {
            a.pos.append(app.gpa, arg) catch {};
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            rest = true;
            continue;
        }
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.findScalar(u8, arg, '=')) |at| {
            name = arg[0..at];
            inline_value = arg[at + 1 ..];
        }
        const valued = [_][]const u8{ "--text", "--download", "--only", "--lms-username" };
        var value: ?[]const u8 = null;
        for (valued) |v| if (std.mem.eql(u8, name, v)) {
            value = inline_value orelse blk: {
                i += 1;
                if (i >= argv.len) return app.fail("USAGE", .usage, "{s} needs a value", .{name});
                break :blk argv[i];
            };
        };
        if (std.mem.eql(u8, name, "--json")) {
            app.json = true;
        } else if (std.mem.eql(u8, name, "-y") or std.mem.eql(u8, name, "--yes")) {
            app.yes = true;
        } else if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) {
            a.help = true;
        } else if (std.mem.eql(u8, name, "-V") or std.mem.eql(u8, name, "--version")) {
            a.pos.insert(app.gpa, 0, "version") catch {};
        } else if (std.mem.eql(u8, name, "--all")) {
            a.all = true;
        } else if (std.mem.eql(u8, name, "--unread")) {
            a.unread = true;
        } else if (std.mem.eql(u8, name, "--text")) {
            a.text = value;
        } else if (std.mem.eql(u8, name, "--download")) {
            a.download = value;
        } else if (std.mem.eql(u8, name, "--only")) {
            a.only = value;
        } else if (std.mem.eql(u8, name, "--lms-username")) {
            a.lms_username = value;
        } else {
            return app.fail("USAGE", .usage, "unknown option {s} (see `nust --help`)", .{name});
        }
    }
    return a;
}

fn need(app: *App, a: Args, n: usize, usage: []const u8) Failed![]const u8 {
    if (a.pos.items.len <= n) return app.fail("USAGE", .usage, "usage: {s}", .{usage});
    return a.pos.items[n];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn dispatch(app: *App, a: Args) Failed!void {
    var c: Clients = .{ .app = app };
    const p = a.pos.items;
    if (p.len == 0) return app.print("{s}", .{docs.usage});
    const cmd = p[0];
    if (a.help) return app.print("{s}", .{docs.helpFor(p)});
    if (eq(cmd, "help")) {
        if (p.len > 1 and eq(p[1], "agents")) return app.print("{s}", .{docs.agents});
        return app.print("{s}", .{docs.helpFor(p[1..])});
    }
    if (eq(cmd, "agents")) return app.print("{s}", .{docs.agents});
    if (eq(cmd, "version")) return app.print("nust {s}\n", .{build_options.version});
    if (eq(cmd, "completions")) {
        const shell = try need(app, a, 1, "nust completions <bash|zsh|fish|powershell>");
        return app.print("{s}", .{docs.completion(shell) orelse return app.fail("USAGE", .usage, "unknown shell {s}; use bash, zsh, fish or powershell", .{shell})});
    }
    if (eq(cmd, "login")) return account.login(app, &c, try account.Systems.parse(app, a.only), a.lms_username);
    if (eq(cmd, "logout")) return account.logout(app, &c, try account.Systems.parse(app, a.only));
    if (eq(cmd, "status")) return account.status(app, &c);

    if (eq(cmd, "lms")) {
        if (p.len < 2) return app.print("{s}", .{docs.lms_help});
        const sub = p[1];
        if (eq(sub, "whoami")) return lms.whoami(app, &c);
        if (eq(sub, "courses")) return lms.courses(app, &c);
        if (eq(sub, "deadlines")) return lms.deadlines(app, &c, a.all);
        if (eq(sub, "notifications")) return lms.notifications(app, &c, a.unread);
        if (eq(sub, "assignments")) return lms.assignments(app, &c, if (p.len > 2) p[2] else null);
        if (eq(sub, "status")) return lms.status(app, &c, try need(app, a, 2, "nust lms status <assignment>"));
        if (eq(sub, "files")) return lms.files(app, &c, try need(app, a, 2, "nust lms files <course> [--download <dir>]"), a.download);
        if (eq(sub, "submit")) {
            const target = try need(app, a, 2, "nust lms submit <assignment> <file>... [--text \"...\"] [-y]");
            return lms.submit(app, &c, target, p[3..], a.text);
        }
        return app.fail("USAGE", .usage, "unknown command `nust lms {s}` (see `nust lms --help`)", .{sub});
    }
    if (eq(cmd, "qalam")) {
        if (p.len < 2) return app.print("{s}", .{docs.qalam_help});
        const sub = p[1];
        if (eq(sub, "courses")) return qalam.courses(app, &c);
        if (eq(sub, "attendance")) return qalam.attendance(app, &c, if (p.len > 2) p[2] else null);
        if (eq(sub, "grades")) return qalam.grades(app, &c, try need(app, a, 2, "nust qalam grades <course> [<filter>]"), if (p.len > 3) p[3] else null);
        if (eq(sub, "results")) return qalam.results(app, &c);
        if (eq(sub, "timetable")) return qalam.timetable(app, &c);
        if (eq(sub, "invoices")) return qalam.invoices(app, &c);
        return app.fail("USAGE", .usage, "unknown command `nust qalam {s}` (see `nust qalam --help`)", .{sub});
    }
    return app.fail("USAGE", .usage, "unknown command `{s}` (see `nust --help`)", .{cmd});
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var out_buf: [16 * 1024]u8 = undefined;
    var err_buf: [4 * 1024]u8 = undefined;
    var out = File.stdout().writerStreaming(io, &out_buf);
    var err = File.stderr().writerStreaming(io, &err_buf);
    var app: App = .{
        .io = io,
        .gpa = gpa,
        .env = init.environ_map,
        .now = Io.Clock.real.now(io).toSeconds(),
        .zone = .{},
        .interactive = File.stdin().isTty(io) catch false,
        .out = &out.interface,
        .err = &err.interface,
    };
    const argv = init.minimal.args.toSlice(gpa) catch {
        err.interface.writeAll("nust: cannot read arguments\n") catch {};
        err.interface.flush() catch {};
        std.process.exit(1);
    };
    app.zone = timefmt.Zone.load(gpa, io, init.environ_map);

    const result = blk: {
        const a = parseArgs(&app, argv) catch |e| break :blk e;
        break :blk dispatch(&app, a);
    };
    app.out.flush() catch {};
    if (result) |_| {
        app.flush();
        std.process.exit(0);
    } else |_| {
        const f = app.failure orelse app_mod.Failure{ .code = "INTERNAL", .message = "failed", .exit = .failure };
        if (app.json) {
            err.interface.writeAll("{\"error\":") catch {};
            std.json.Stringify.value(.{ .code = f.code, .message = f.message, .exit = @intFromEnum(f.exit) }, .{}, &err.interface) catch {};
            err.interface.writeAll("}\n") catch {};
        } else {
            err.interface.print("nust: {s}\n", .{f.message}) catch {};
        }
        app.flush();
        std.process.exit(@intFromEnum(f.exit));
    }
}

test {
    _ = @import("app.zig");
    _ = @import("timefmt.zig");
    _ = @import("http.zig");
    _ = @import("store.zig");
    _ = @import("text.zig");
    _ = @import("html.zig");
    _ = @import("qalam/parse.zig");
    _ = @import("qalam/client.zig");
    _ = @import("baseurl.zig");
    _ = @import("lms/moodle.zig");
    _ = @import("lms/model.zig");
    _ = @import("lms/plan.zig");
}
