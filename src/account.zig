//! `nust login`, `nust logout`, `nust status`: one NUST account, two systems. Each system is
//! tried on its own, so a Qalam problem never blocks the LMS and the other way round.
const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Clients = @import("clients.zig").Clients;
const store_mod = @import("store.zig");

pub const Systems = struct {
    qalam: bool = true,
    lms: bool = true,

    pub fn parse(app: *App, only: ?[]const u8) Failed!Systems {
        const o = only orelse return .{};
        if (std.ascii.eqlIgnoreCase(o, "qalam")) return .{ .lms = false };
        if (std.ascii.eqlIgnoreCase(o, "lms")) return .{ .qalam = false };
        return app.fail("USAGE", .usage, "--only takes qalam or lms", .{});
    }
};

const Outcome = struct { ok: bool, message: []const u8 };

fn takeFailure(app: *App) []const u8 {
    const f = app.failure orelse return "failed";
    app.failure = null;
    return f.message;
}

pub fn login(app: *App, c: *Clients, sys: Systems, lms_username: ?[]const u8) Failed!void {
    const store = try c.store();
    const username = std.mem.trim(u8, app.getenv("NUST_USERNAME") orelse blk: {
        if (!app.interactive) return app.fail("NO_TERMINAL", .usage, "no terminal to ask for your username; set NUST_USERNAME (and NUST_PASSWORD)", .{});
        break :blk try app.prompt("NUST username (e.g. 123456 or your Qalam login): ", false);
    }, " \t");
    if (username.len == 0) return app.fail("USAGE", .usage, "a username is required", .{});
    const password = app.getenv("NUST_PASSWORD") orelse blk: {
        if (!app.interactive) return app.fail("NO_TERMINAL", .usage, "no terminal to ask for your password; set NUST_PASSWORD", .{});
        break :blk try app.prompt("Password: ", true);
    };
    if (password.len == 0) return app.fail("USAGE", .usage, "a password is required", .{});

    var qalam_r: ?Outcome = null;
    var lms_r: ?Outcome = null;
    if (sys.qalam) {
        app.note("Signing in to Qalam...", .{});
        const q = try c.qalam();
        if (q.login(username, password)) |r| {
            qalam_r = .{ .ok = true, .message = if (r.feedback_pending)
                "ok, but Qalam is blocking pages until you fill in the QA feedback forms at https://qalam.nust.edu.pk/student/qa/feedback"
            else
                "ok" };
        } else |_| qalam_r = .{ .ok = false, .message = takeFailure(app) };
    }
    if (sys.lms) {
        app.note("Signing in to the LMS...", .{});
        const m = try c.moodle();
        if (m.login(lms_username orelse username, password)) |s| {
            lms_r = .{ .ok = true, .message = std.fmt.allocPrint(app.gpa, "ok ({s})", .{s.full_name}) catch "ok" };
        } else |_| lms_r = .{ .ok = false, .message = takeFailure(app) };
    }
    const any_ok = (qalam_r != null and qalam_r.?.ok) or (lms_r != null and lms_r.?.ok);
    var where: []const u8 = "none";
    if (any_ok) {
        where = try store.savePassword(username, password);
        try store.saveJson("account.json", store_mod.Account{ .username = username, .password_store = where });
    }
    const all_ok = (qalam_r == null or qalam_r.?.ok) and (lms_r == null or lms_r.?.ok);
    if (app.json) {
        app.emitJson(.{ .ok = all_ok, .qalam = qalam_r, .lms = lms_r, .password_saved_to = where });
    } else {
        if (qalam_r) |r| app.print("Qalam  {s}\n", .{r.message});
        if (lms_r) |r| app.print("LMS    {s}\n", .{r.message});
        if (any_ok) app.print("{s}\n", .{if (std.mem.eql(u8, where, "keychain")) "Password saved to the system keychain." else "Password saved to a private file only you can read."});
    }
    if (!all_ok) {
        app.flush();
        return app.fail("LOGIN_FAILED", .failure, "{s}", .{if (any_ok) "signed in to one system only; see above" else "could not sign in"});
    }
}

pub fn logout(app: *App, c: *Clients, sys: Systems) Failed!void {
    const store = try c.store();
    if (sys.qalam) (try c.qalam()).logout();
    if (sys.lms) (try c.moodle()).logout();
    if (sys.qalam and sys.lms) {
        if (store.account()) |a| store.deletePassword(a.username);
        store.remove("account.json");
    }
    if (app.json) return app.emitJson(.{ .ok = true, .qalam = sys.qalam, .lms = sys.lms });
    app.print("Signed out{s}. Saved sessions{s} removed from this machine.\n", .{
        if (sys.qalam and sys.lms) "" else if (sys.qalam) " of Qalam" else " of the LMS",
        if (sys.qalam and sys.lms) " and password" else "",
    });
}

pub fn status(app: *App, c: *Clients) Failed!void {
    const store = try c.store();
    const acct = store.account();
    const q = try c.qalam();
    const m = try c.moodle();
    const qs: []const u8 = if (q.check()) |r| switch (r) {
        .ok => "signed in",
        .expired => "session expired (renews by itself on the next command)",
        .feedback_pending => "signed in, but pages are blocked until the QA feedback forms are done",
        .none => "not signed in",
    } else |_| takeFailure(app);
    const ls: []const u8 = if (m.check()) |r| switch (r) {
        .ok => "signed in",
        .expired => "session expired (renews by itself on the next command)",
        .none => "not signed in",
    } else |_| takeFailure(app);
    const pw: []const u8 = if (acct) |a| blk: {
        if (std.mem.eql(u8, a.password_store, "keychain")) break :blk "saved in the system keychain";
        if (std.mem.eql(u8, a.password_store, "file")) break :blk "saved in a private file";
        break :blk "not saved";
    } else "not saved";
    if (app.json) return app.emitJson(.{ .username = if (acct) |a| a.username else null, .qalam = qs, .lms = ls, .password = pw, .state_dir = store.path });
    app.print("Account   {s}\nQalam     {s}\nLMS       {s}\nPassword  {s}\nFiles     {s}\n", .{ if (acct) |a| a.username else "-", qs, ls, pw, store.path });
}
