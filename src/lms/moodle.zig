//! The only place that builds Moodle form bodies and reads Moodle errors. Every call that the
//! server rejects for an expired token logs in again once (with the saved password) and retries.
const std = @import("std");
const Value = std.json.Value;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const http_mod = @import("../http.zig");
const Http = http_mod.Http;
const store_mod = @import("../store.zig");
const Store = store_mod.Store;
const LmsSession = store_mod.LmsSession;
const creds = @import("../creds.zig");
const baseurl = @import("../baseurl.zig");
const j = @import("json.zig");

pub const default_base = "https://lms.nust.edu.pk";
const session_file = "lms-session.json";

/// Moodle's flat form encoding (`courseids[0]=3`).
pub const Args = std.ArrayList([2][]const u8);

const CallError = error{ AuthExpired, Failed };

pub const Moodle = struct {
    app: *App,
    http: *Http,
    store: Store,
    base: []const u8,
    session: ?LmsSession = null,

    pub fn init(app: *App, http: *Http, store: Store) Failed!Moodle {
        var base: []const u8 = default_base;
        if (app.getenv("LMS_BASE_URL")) |b| base = baseurl.parseOverride(b) catch
            return app.fail("CONFIG", .usage, "LMS_BASE_URL must be https, or http on 127.0.0.1/localhost", .{});
        return .{ .app = app, .http = http, .store = store, .base = base };
    }

    pub fn loadSession(m: *Moodle) ?LmsSession {
        m.session = m.store.loadJson(LmsSession, session_file);
        return m.session;
    }

    pub fn userId(m: *Moodle) Failed!i64 {
        if (m.session == null and m.loadSession() == null) try m.relogin(null);
        return m.session.?.user_id;
    }

    fn url(m: *Moodle, path: []const u8) []const u8 {
        return std.fmt.allocPrint(m.app.gpa, "{s}{s}", .{ m.base, path }) catch "";
    }

    /// Exchanges a password for a token, then asks who the token belongs to. Saves the session.
    pub fn login(m: *Moodle, username: []const u8, password: []const u8) Failed!LmsSession {
        const app = m.app;
        const form = http_mod.formEncode(app.gpa, &.{ .{ "username", username }, .{ "password", password }, .{ "service", "moodle_mobile_app" } }) catch
            return app.fail("OOM", .failure, "out of memory", .{});
        const res = m.http.send(.{ .method = .POST, .url = m.url("/login/token.php"), .body = form, .content_type = "application/x-www-form-urlencoded" }) catch
            return m.networkFail();
        const v = m.decode(res) catch |e| switch (e) {
            error.AuthExpired => return app.fail("LOGIN_FAILED", .failure, "the LMS did not accept the username or password", .{}),
            error.Failed => return error.Failed,
        };
        const token = j.str(v, "token");
        if (token.len == 0) return app.fail("BAD_RESPONSE", .failure, "the LMS login reply has no token", .{});
        const info = m.rest(token, "core_webservice_get_site_info", &.{}, false) catch |e| switch (e) {
            error.AuthExpired => return app.fail("LOGIN_FAILED", .failure, "the LMS rejected its own new token", .{}),
            error.Failed => return error.Failed,
        };
        const s: LmsSession = .{ .token = token, .user_id = j.int(info, "userid") orelse 0, .full_name = j.str(info, "fullname"), .username = username };
        if (s.user_id == 0) return app.fail("BAD_RESPONSE", .failure, "the LMS site info has no user id", .{});
        try m.store.saveJson(session_file, s);
        m.session = s;
        return s;
    }

    pub const Check = enum { ok, expired, none };

    /// Whether the saved token still works, without logging in again.
    pub fn check(m: *Moodle) Failed!Check {
        const s = m.loadSession() orelse return .none;
        _ = m.rest(s.token, "core_webservice_get_site_info", &.{}, false) catch |e| switch (e) {
            error.AuthExpired => return .expired,
            error.Failed => return error.Failed,
        };
        return .ok;
    }

    pub fn logout(m: *Moodle) void {
        m.store.remove(session_file);
    }

    fn networkFail(m: *Moodle) error{Failed} {
        return m.app.fail("NETWORK", .failure, "could not reach the LMS ({s}); check your connection and retry", .{m.http.describe()});
    }

    /// Strips what a NUST plugin echoes before some JSON bodies (an HTML comment, stray text).
    fn jsonStart(t_in: []const u8) []const u8 {
        var t = std.mem.trimStart(u8, t_in, " \t\r\n");
        while (std.mem.startsWith(u8, t, "<!--")) {
            const end = std.mem.find(u8, t, "-->") orelse return "";
            t = std.mem.trimStart(u8, t[end + 3 ..], " \t\r\n");
        }
        if (t.len > 0 and (t[0] == '[' or t[0] == '{' or t[0] == '"')) return t;
        const at = std.mem.findAny(u8, t, "[{") orelse return t;
        return t[at..];
    }

    /// Body to JSON. A Moodle error object becomes `AuthExpired` for auth codes, else a failure.
    fn decode(m: *Moodle, res: http_mod.Response) CallError!Value {
        const app = m.app;
        const v = std.json.parseFromSliceLeaky(Value, app.gpa, jsonStart(res.body), .{}) catch {
            if (res.status >= 400) return app.fail("HTTP_ERROR", .failure, "the LMS returned HTTP {d}", .{res.status});
            return app.fail("BAD_RESPONSE", .failure, "the LMS reply is not JSON (it may be in maintenance)", .{});
        };
        if (v == .object) {
            if (v.object.get("errorcode")) |code_v| {
                const code = if (code_v == .string) code_v.string else "";
                if (isAuthCode(code)) return error.AuthExpired;
                const msg = blk: {
                    const mm = j.str(v, "message");
                    break :blk if (mm.len > 0) mm else j.str(v, "error");
                };
                return app.fail(code, .failure, "{s} ({s})", .{ msg, code });
            }
        }
        return v;
    }

    fn rest(m: *Moodle, token: []const u8, func: []const u8, args: []const [2][]const u8, write: bool) CallError!Value {
        const app = m.app;
        var fields: std.ArrayList([2][]const u8) = .empty;
        fields.appendSlice(app.gpa, &.{ .{ "wstoken", token }, .{ "wsfunction", func }, .{ "moodlewsrestformat", "json" } }) catch return app.fail("OOM", .failure, "out of memory", .{});
        fields.appendSlice(app.gpa, args) catch return app.fail("OOM", .failure, "out of memory", .{});
        const form = http_mod.formEncode(app.gpa, fields.items) catch return app.fail("OOM", .failure, "out of memory", .{});
        const res = m.http.send(.{ .method = .POST, .url = m.url("/webservice/rest/server.php"), .body = form, .content_type = "application/x-www-form-urlencoded", .write = write }) catch {
            if (write) return app.fail("WRITE_UNKNOWN", .failure, "the connection dropped during {s}; the LMS may or may not have saved it", .{func});
            return m.networkFail();
        };
        if (write and res.status >= 500) return app.fail("WRITE_UNKNOWN", .failure, "the LMS returned HTTP {d} during {s}; it may or may not have saved it", .{ res.status, func });
        return m.decode(res);
    }

    /// Calls a web service function. An expired token triggers exactly one login and one retry.
    pub fn call(m: *Moodle, func: []const u8, args: []const [2][]const u8) Failed!Value {
        return m.callOpts(func, args, false);
    }

    /// A write (save, submit). Never resent after a transport failure; resent once after an
    /// auth rejection, because Moodle checks the token before doing anything.
    pub fn callWrite(m: *Moodle, func: []const u8, args: []const [2][]const u8) Failed!Value {
        return m.callOpts(func, args, true);
    }

    fn callOpts(m: *Moodle, func: []const u8, args: []const [2][]const u8, write: bool) Failed!Value {
        if (m.session == null and m.loadSession() == null) try m.relogin(null);
        const token = m.session.?.token;
        if (m.rest(token, func, args, write)) |v| return v else |e| switch (e) {
            error.Failed => return error.Failed,
            error.AuthExpired => {},
        }
        try m.relogin(token);
        return m.rest(m.session.?.token, func, args, write) catch |e| switch (e) {
            error.Failed => error.Failed,
            error.AuthExpired => m.app.fail("AUTH_REQUIRED", .failure, "the LMS rejected the new session; run `nust login`", .{}),
        };
    }

    fn relogin(m: *Moodle, stale_token: ?[]const u8) Failed!void {
        const app = m.app;
        const lock = try m.store.lock();
        defer m.store.unlock(lock);
        if (m.loadSession()) |s| {
            // Another command renewed it while we waited for the lock.
            if (stale_token == null or !std.mem.eql(u8, s.token, stale_token.?)) return;
        }
        const c = try creds.forRelogin(app, m.store, "LMS");
        const acct = m.store.account();
        const lms_user = if (m.session) |s| s.username else if (acct) |a| a.username else c.username;
        _ = try m.login(lms_user, c.password);
        creds.remember(app, m.store, c);
        if (stale_token != null) app.note("(LMS session expired, signed in again)", .{});
    }

    pub const Draft = struct { itemid: i64, filename: []const u8 };

    /// Uploads one file to the draft area. Pass itemid 0 for the first file, then the returned
    /// id so every file lands in the same draft.
    pub fn upload(m: *Moodle, filename: []const u8, data: []const u8, itemid: i64) Failed!Draft {
        const app = m.app;
        if (m.session == null and m.loadSession() == null) try m.relogin(null);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const id_s = std.fmt.allocPrint(app.gpa, "{d}", .{itemid}) catch "0";
            const body = http_mod.multipart(app.gpa, &.{ .{ "token", m.session.?.token }, .{ "filearea", "draft" }, .{ "itemid", id_s } }, "file_1", filename, data) catch
                return app.fail("OOM", .failure, "out of memory", .{});
            const res = m.http.send(.{ .method = .POST, .url = m.url("/webservice/upload.php"), .body = body, .content_type = "multipart/form-data; boundary=" ++ http_mod.multipart_boundary, .write = true }) catch
                return app.fail("NETWORK", .failure, "the connection dropped while uploading {s}; nothing was submitted", .{filename});
            const v = m.decode(res) catch |e| switch (e) {
                error.Failed => return error.Failed,
                error.AuthExpired => {
                    if (attempt > 0) return app.fail("AUTH_REQUIRED", .failure, "the LMS rejected the new session; run `nust login`", .{});
                    try m.relogin(m.session.?.token);
                    continue;
                },
            };
            if (v != .array or v.array.items.len == 0) return app.fail("BAD_RESPONSE", .failure, "the upload of {s} returned no file; nothing was submitted", .{filename});
            const f = v.array.items[0];
            return .{ .itemid = j.int(f, "itemid") orelse 0, .filename = j.str(f, "filename") };
        }
    }

    /// Downloads a pluginfile URL (with the token) to `dest` under `dir`. Returns bytes written.
    pub fn download(m: *Moodle, file_url: []const u8, dir: std.Io.Dir, dest: []const u8) Failed!u64 {
        const app = m.app;
        if (!baseurl.serves(m.base, file_url))
            return app.fail("UNSAFE_URL", .failure, "refusing to send the LMS token to a URL outside {s}", .{m.base});
        if (m.session == null and m.loadSession() == null) try m.relogin(null);
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const sep: []const u8 = if (std.mem.findScalar(u8, file_url, '?') != null) "&" else "?";
            const u = std.fmt.allocPrint(app.gpa, "{s}{s}token={s}", .{ file_url, sep, m.session.?.token }) catch return app.fail("OOM", .failure, "out of memory", .{});
            const r = m.http.download(u, dir, dest) catch return app.fail("NETWORK", .failure, "download failed ({s})", .{m.http.describe()});
            switch (r) {
                .saved => |n| return n,
                .status => |s| return app.fail("HTTP_ERROR", .failure, "the LMS returned HTTP {d}", .{s}),
                .json => |body| {
                    const v = std.json.parseFromSliceLeaky(Value, app.gpa, body, .{}) catch
                        return app.fail("BAD_RESPONSE", .failure, "the LMS sent an unexpected reply instead of the file", .{});
                    const code = j.str(v, "errorcode");
                    if (isAuthCode(code) and attempt == 0) {
                        try m.relogin(m.session.?.token);
                        continue;
                    }
                    return app.fail(if (code.len > 0) code else "BAD_RESPONSE", .failure, "the LMS refused the download: {s}", .{j.str(v, "error")});
                },
            }
        }
    }
};

pub fn isAuthCode(code: []const u8) bool {
    inline for (.{ "invalidtoken", "accessexception", "invalidlogin", "sitemaintenance_token" }) |c| {
        if (std.mem.eql(u8, code, c)) return true;
    }
    return false;
}

test "json start skips plugin junk" {
    try std.testing.expectEqualStrings("{\"a\":1}", Moodle.jsonStart("<!-- mod_enhancedlabel [x] -->\n{\"a\":1}"));
    try std.testing.expectEqualStrings("[1,2]", Moodle.jsonStart("notice: oops\n[1,2]"));
}
