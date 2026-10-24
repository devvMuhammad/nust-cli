//! Everything kept on disk: the account, one session per system, and the password. Files are
//! private (0600 in a 0700 directory) and replaced atomically, so a reader never sees half a
//! write. The password goes to the OS keychain when there is one, otherwise to a private file.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const keyring = @import("keyring.zig");

const keyring_service = "nust-cli";

pub const Account = struct {
    version: u8 = 1,
    username: []const u8,
    /// Where the password lives: "keychain", "file", or "none".
    password_store: []const u8 = "none",
};

pub const LmsSession = struct {
    version: u8 = 1,
    token: []const u8,
    user_id: i64,
    full_name: []const u8 = "",
    username: []const u8,
};

pub const Cookie = struct { name: []const u8, value: []const u8 };

pub const QalamSession = struct {
    version: u8 = 1,
    username: []const u8,
    cookies: []const Cookie = &.{},
    authenticated_at: i64 = 0,
};

pub const Store = struct {
    app: *App,
    path: []const u8,

    pub fn open(app: *App) Failed!Store {
        const path = stateDir(app) catch return app.fail("STATE_DIR", .failure, "cannot find a home directory for saved sessions (set NUST_STATE_DIR)", .{});
        return .{ .app = app, .path = path };
    }

    fn file(s: Store, name: []const u8) []const u8 {
        return std.fs.path.join(s.app.gpa, &.{ s.path, name }) catch "";
    }

    fn prepare(s: Store) Failed!void {
        const io = s.app.io;
        Io.Dir.cwd().createDirPath(io, s.path) catch |e|
            return s.app.fail("STATE_DIR", .failure, "cannot create {s}: {s}", .{ s.path, @errorName(e) });
        if (builtin.os.tag != .windows) {
            var d = Io.Dir.cwd().openDir(io, s.path, .{}) catch return;
            defer d.close(io);
            d.setPermissions(io, .fromMode(0o700)) catch {};
        }
    }

    pub fn read(s: Store, name: []const u8) ?[]const u8 {
        return Io.Dir.cwd().readFileAlloc(s.app.io, s.file(name), s.app.gpa, .limited(1 << 20)) catch null;
    }

    pub fn write(s: Store, name: []const u8, content: []const u8) Failed!void {
        try s.prepare();
        const io = s.app.io;
        var dir = Io.Dir.cwd().openDir(io, s.path, .{}) catch |e|
            return s.app.fail("STATE_DIR", .failure, "cannot open {s}: {s}", .{ s.path, @errorName(e) });
        defer dir.close(io);
        const perms: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
        var af = dir.createFileAtomic(io, name, .{ .replace = true, .permissions = perms }) catch |e|
            return s.app.fail("STATE_WRITE", .failure, "cannot write {s}: {s}", .{ name, @errorName(e) });
        defer af.deinit(io);
        af.file.writeStreamingAll(io, content) catch |e|
            return s.app.fail("STATE_WRITE", .failure, "cannot write {s}: {s}", .{ name, @errorName(e) });
        af.replace(io) catch |e|
            return s.app.fail("STATE_WRITE", .failure, "cannot save {s}: {s}", .{ name, @errorName(e) });
    }

    pub fn remove(s: Store, name: []const u8) void {
        Io.Dir.cwd().deleteFile(s.app.io, s.file(name)) catch {};
    }

    /// An exclusive lock over session refreshes, so two commands never log in at once and
    /// overwrite each other's session. Release with `unlock`.
    pub fn lock(s: Store) Failed!File {
        try s.prepare();
        const perms: File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
        return Io.Dir.cwd().createFile(s.app.io, s.file("lock"), .{ .truncate = false, .lock = .exclusive, .permissions = perms }) catch |e|
            s.app.fail("SESSION_BUSY", .failure, "cannot lock the session: {s}", .{@errorName(e)});
    }

    pub fn unlock(s: Store, f: File) void {
        f.unlock(s.app.io);
        f.close(s.app.io);
    }

    pub fn loadJson(s: Store, comptime T: type, name: []const u8) ?T {
        const text = s.read(name) orelse return null;
        const v = std.json.parseFromSliceLeaky(T, s.app.gpa, text, .{ .ignore_unknown_fields = true }) catch return null;
        if (v.version != 1) return null;
        return v;
    }

    pub fn saveJson(s: Store, name: []const u8, value: anytype) Failed!void {
        const text = std.json.Stringify.valueAlloc(s.app.gpa, value, .{}) catch return s.app.fail("OOM", .failure, "out of memory", .{});
        try s.write(name, text);
    }

    pub fn account(s: Store) ?Account {
        return s.loadJson(Account, "account.json");
    }

    // ---- password ----

    /// Saves the password where this machine can keep it. Returns "keychain" or "file".
    pub fn savePassword(s: Store, username: []const u8, password: []const u8) Failed![]const u8 {
        if (s.app.getenv("NUST_PASSWORD_STORE")) |forced| {
            if (std.mem.eql(u8, forced, "file")) {
                try s.saveJson("password.json", .{ .version = 1, .username = username, .password = password });
                return "file";
            }
        }
        if (keyring.set(s.app.gpa, s.app.io, keyring_service, username, password)) {
            s.remove("password.json");
            return "keychain";
        } else |_| {
            try s.saveJson("password.json", .{ .version = 1, .username = username, .password = password });
            return "file";
        }
    }

    /// `NUST_PASSWORD` first, then the keychain, then the private file.
    pub fn loadPassword(s: Store, username: []const u8) ?[]const u8 {
        if (s.app.getenv("NUST_PASSWORD")) |p| return p;
        const acct = s.account();
        const where = if (acct) |a| a.password_store else "none";
        if (std.mem.eql(u8, where, "keychain")) {
            if (keyring.get(s.app.gpa, s.app.io, keyring_service, username) catch null) |p| return p;
        }
        const P = struct { version: u8 = 1, username: []const u8, password: []const u8 };
        if (s.loadJson(P, "password.json")) |p| {
            if (std.mem.eql(u8, p.username, username)) return p.password;
        }
        return null;
    }

    pub fn deletePassword(s: Store, username: []const u8) void {
        keyring.delete(s.app.gpa, s.app.io, keyring_service, username) catch {};
        s.remove("password.json");
    }
};

/// `NUST_STATE_DIR`, else the per-user config folder: `~/Library/Application Support/nust`,
/// `$XDG_CONFIG_HOME/nust` or `~/.config/nust`, `%APPDATA%\nust`.
fn stateDir(app: *App) ![]const u8 {
    if (app.getenv("NUST_STATE_DIR")) |d| return d;
    const gpa = app.gpa;
    return switch (builtin.os.tag) {
        .windows => std.fs.path.join(gpa, &.{ app.getenv("APPDATA") orelse return error.NoHome, "nust" }),
        .macos => std.fs.path.join(gpa, &.{ app.getenv("HOME") orelse return error.NoHome, "Library", "Application Support", "nust" }),
        else => if (app.getenv("XDG_CONFIG_HOME")) |x|
            std.fs.path.join(gpa, &.{ x, "nust" })
        else
            std.fs.path.join(gpa, &.{ app.getenv("HOME") orelse return error.NoHome, ".config", "nust" }),
    };
}
