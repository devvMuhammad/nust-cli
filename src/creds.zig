//! Where a fresh login gets its username and password when a session has expired.
const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Store = @import("store.zig").Store;

pub const Creds = struct {
    username: []const u8,
    password: []const u8,
    /// Typed just now, so it should be saved again once it works.
    prompted: bool = false,
};

/// The saved account's username and password: `NUST_PASSWORD`, then the saved password, then a
/// prompt when there is a terminal. Without any of those the command stops instead of waiting.
pub fn forRelogin(app: *App, store: Store, system: []const u8) Failed!Creds {
    const acct = store.account() orelse
        return app.fail("AUTH_REQUIRED", .usage, "not signed in to {s}; run `nust login`", .{system});
    if (store.loadPassword(acct.username)) |p| return .{ .username = acct.username, .password = p };
    if (!app.interactive or app.json)
        return app.fail("AUTH_REQUIRED", .usage, "your {s} session expired and no password is saved; run `nust login`", .{system});
    app.note("Your {s} session expired. Enter your NUST password to sign in again.", .{system});
    const pw = try app.prompt("Password: ", true);
    if (pw.len == 0) return app.fail("AUTH_REQUIRED", .usage, "no password entered", .{});
    return .{ .username = acct.username, .password = pw, .prompted = true };
}

/// After a prompted password worked, keep it so the next expiry is silent again.
pub fn remember(app: *App, store: Store, c: Creds) void {
    if (!c.prompted) return;
    const where = store.savePassword(c.username, c.password) catch return;
    var acct = store.account() orelse return;
    acct.password_store = where;
    store.saveJson("account.json", acct) catch {};
    _ = app;
}
