//! Qalam portal client. Qalam has no API for students, so this signs in through the same form
//! a browser uses and reads server-rendered pages. Only the login POST and academic GETs are
//! made; redirects are followed by hand and never leave the portal's origin.
const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const http_mod = @import("../http.zig");
const Http = http_mod.Http;
const store_mod = @import("../store.zig");
const Store = store_mod.Store;
const Cookie = store_mod.Cookie;
const QalamSession = store_mod.QalamSession;
const html = @import("../html.zig");
const parse = @import("parse.zig");
const creds = @import("../creds.zig");
const baseurl = @import("../baseurl.zig");

pub const default_base = "https://qalam.nust.edu.pk";
pub const feedback_path = "/student/qa/feedback";
const session_file = "qalam-session.json";

pub const Page = struct { raw: []const u8, doc: *html.Node };

const ReqError = error{ AuthExpired, Failed };

pub const Qalam = struct {
    app: *App,
    http: *Http,
    store: Store,
    base: []const u8,
    cookies: std.ArrayList(Cookie) = .empty,
    username: []const u8 = "",

    pub fn init(app: *App, http: *Http, store: Store) Failed!Qalam {
        var base: []const u8 = default_base;
        if (app.getenv("QALAM_BASE_URL")) |b| base = baseurl.parseOverride(b) catch
            return app.fail("CONFIG", .usage, "QALAM_BASE_URL must be https, or http on 127.0.0.1/localhost", .{});
        return .{ .app = app, .http = http, .store = store, .base = base };
    }

    fn loadSession(q: *Qalam) bool {
        const s = q.store.loadJson(QalamSession, session_file) orelse return false;
        q.cookies = .empty;
        q.cookies.appendSlice(q.app.gpa, s.cookies) catch return false;
        q.username = s.username;
        return true;
    }

    fn saveSession(q: *Qalam) Failed!void {
        try q.store.saveJson(session_file, QalamSession{ .username = q.username, .cookies = q.cookies.items, .authenticated_at = q.app.now });
    }

    pub fn hasSession(q: *Qalam) bool {
        return q.loadSession();
    }

    fn cookieHeader(q: *Qalam) []const u8 {
        var aw: std.Io.Writer.Allocating = .init(q.app.gpa);
        for (q.cookies.items, 0..) |c, i| {
            if (i > 0) aw.writer.writeAll("; ") catch {};
            aw.writer.print("{s}={s}", .{ c.name, c.value }) catch {};
        }
        return aw.written();
    }

    fn takeCookies(q: *Qalam, set_cookies: []const []const u8) void {
        for (set_cookies) |raw| {
            const pair_end = std.mem.findScalar(u8, raw, ';') orelse raw.len;
            const pair = raw[0..pair_end];
            const eq = std.mem.findScalar(u8, pair, '=') orelse continue;
            const name = std.mem.trim(u8, pair[0..eq], " ");
            const value = std.mem.trim(u8, pair[eq + 1 ..], " \"");
            const attrs = raw[pair_end..];
            const deleted = value.len == 0 or std.ascii.findIgnoreCase(attrs, "max-age=0") != null or
                std.ascii.findIgnoreCase(attrs, "1970") != null;
            var i: usize = 0;
            while (i < q.cookies.items.len) {
                if (std.mem.eql(u8, q.cookies.items[i].name, name)) _ = q.cookies.orderedRemove(i) else i += 1;
            }
            if (!deleted) q.cookies.append(q.app.gpa, .{ .name = name, .value = value }) catch {};
        }
    }

    fn pathOf(q: *Qalam, url: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, url, "/") and !std.mem.startsWith(u8, url, "//")) return url;
        if (!baseurl.serves(q.base, url)) return null;
        return url[q.base.len..];
    }

    fn allowed(path_with_query: []const u8) bool {
        const path = path_with_query[0 .. std.mem.findAny(u8, path_with_query, "?#") orelse path_with_query.len];
        if (std.mem.indexOf(u8, path, "..") != null) return false;
        return std.mem.eql(u8, path, "/web/login") or std.mem.startsWith(u8, path, "/student/") or std.mem.eql(u8, path, "/student");
    }

    /// One logical request with redirects followed by hand. A redirect to the login page means
    /// the session expired; one to the feedback survey means Qalam is blocking every page.
    fn request(q: *Qalam, method: http_mod.Method, start_path: []const u8, form: ?[]const u8) ReqError!Page {
        const app = q.app;
        var path = start_path;
        var m = method;
        var body = form;
        var hops: usize = 0;
        while (hops < 7) : (hops += 1) {
            if (!allowed(path)) return app.fail("UNSAFE_REDIRECT", .failure, "Qalam redirected to an unsupported page ({s}); stopped", .{path});
            const url = std.fmt.allocPrint(app.gpa, "{s}{s}", .{ q.base, path }) catch return app.fail("OOM", .failure, "out of memory", .{});
            var headers: [2]std.http.Header = undefined;
            var nh: usize = 0;
            if (q.cookies.items.len > 0) {
                headers[nh] = .{ .name = "Cookie", .value = q.cookieHeader() };
                nh += 1;
            }
            headers[nh] = .{ .name = "Accept", .value = "text/html" };
            nh += 1;
            const res = q.http.send(.{
                .method = m,
                .url = url,
                .body = body,
                .content_type = if (body != null) "application/x-www-form-urlencoded" else null,
                .headers = headers[0..nh],
                .write = body != null,
            }) catch return app.fail("NETWORK", .failure, "could not reach Qalam ({s}); check your connection and retry", .{q.http.describe()});
            q.takeCookies(res.set_cookies);
            if (res.status >= 300 and res.status < 400 and res.location != null) {
                const next = q.pathOf(res.location.?) orelse
                    return app.fail("UNSAFE_REDIRECT", .failure, "Qalam redirected outside its site; stopped", .{});
                const next_path = next[0 .. std.mem.findAny(u8, next, "?#") orelse next.len];
                if (std.mem.eql(u8, std.mem.trimEnd(u8, next_path, "/"), feedback_path)) return feedbackRequired(app);
                if (std.mem.eql(u8, next_path, "/web/login") and m == .GET) return error.AuthExpired;
                if (res.status == 307 or res.status == 308) {
                    // Never forward a password through a method-preserving redirect.
                    if (m != .GET) return app.fail("LOGIN_REDIRECT", .failure, "unexpected redirect during Qalam login", .{});
                } else {
                    m = .GET;
                    body = null;
                }
                path = next;
                continue;
            }
            const doc = html.parse(app.gpa, res.body) catch return app.fail("OOM", .failure, "out of memory", .{});
            const state = parse.pageState(app.gpa, doc, res.body);
            if (state == .challenge) return app.fail("BROWSER_CHECK", .failure,
                "Qalam is showing a Cloudflare check. Open {s} in a browser once, then retry", .{q.base});
            if (res.status == 401 or res.status == 403) return app.fail("ACCESS_DENIED", .failure, "Qalam denied the request (HTTP {d})", .{res.status});
            if (res.status >= 400) return app.fail("PORTAL_ERROR", .failure, "Qalam returned HTTP {d}", .{res.status});
            if (state == .login and m == .GET and !std.mem.startsWith(u8, path, "/web/login")) return error.AuthExpired;
            return .{ .raw = res.body, .doc = doc };
        }
        return app.fail("REDIRECT_LOOP", .failure, "Qalam redirected too many times; run `nust login`", .{});
    }

    pub const LoginResult = struct { feedback_pending: bool = false };

    /// Signs in with the login form and saves the session cookies. The password goes only to
    /// the portal's own `/web/login`, never to a page-supplied form action.
    pub fn login(q: *Qalam, username: []const u8, password: []const u8) Failed!LoginResult {
        const app = q.app;
        q.cookies = .empty;
        const page = q.request(.GET, "/web/login", null) catch |e| switch (e) {
            error.AuthExpired => unreachable,
            error.Failed => return error.Failed,
        };
        const token = parse.csrfToken(app.gpa, page.doc) orelse
            return app.fail("PORTAL_CHANGED", .failure, "the Qalam login form has changed (no CSRF token)", .{});
        const form = http_mod.formEncode(app.gpa, &.{
            .{ "csrf_token", token },
            .{ "login", username },
            .{ "password", password },
            .{ "redirect", "/student/dashboard" },
        }) catch return app.fail("OOM", .failure, "out of memory", .{});
        var result: LoginResult = .{};
        const after = q.request(.POST, "/web/login", form) catch |e| switch (e) {
            error.AuthExpired => return app.fail("LOGIN_FAILED", .failure, "Qalam did not accept the username or password", .{}),
            error.Failed => blk: {
                // The feedback survey is only reachable with accepted credentials.
                if (app.failure != null and std.mem.eql(u8, app.failure.?.code, "FEEDBACK_REQUIRED")) {
                    app.failure = null;
                    result.feedback_pending = true;
                    break :blk null;
                }
                return error.Failed;
            },
        };
        if (after) |p| {
            if (parse.pageState(app.gpa, p.doc, p.raw) == .login)
                return app.fail("LOGIN_FAILED", .failure, "Qalam did not accept the username or password", .{});
            if (!parse.isStudentPage(app.gpa, p.doc))
                return app.fail("PORTAL_CHANGED", .failure, "signed in, but the page after login is not the student portal", .{});
        }
        q.username = username;
        try q.saveSession();
        return result;
    }

    /// A signed-in GET. An expired session is renewed once with the saved password.
    pub fn get(q: *Qalam, path: []const u8) Failed!Page {
        const app = q.app;
        if (!q.loadSession()) try q.relogin(&.{});
        const used = q.cookieHeader();
        if (q.request(.GET, path, null)) |page| {
            q.saveSession() catch {};
            return page;
        } else |e| switch (e) {
            error.Failed => return error.Failed,
            error.AuthExpired => {},
        }
        try q.relogin(used);
        return q.request(.GET, path, null) catch |e| switch (e) {
            error.Failed => return error.Failed,
            error.AuthExpired => app.fail("AUTH_REQUIRED", .failure, "Qalam rejected the new session; run `nust login`", .{}),
        };
    }

    /// Takes the session lock, and unless another command already renewed the session while
    /// we waited, logs in again.
    fn relogin(q: *Qalam, stale_cookies: []const u8) Failed!void {
        const app = q.app;
        const lock = try q.store.lock();
        defer q.store.unlock(lock);
        if (q.loadSession() and !std.mem.eql(u8, q.cookieHeader(), stale_cookies) and stale_cookies.len > 0) return;
        const c = try creds.forRelogin(app, q.store, "Qalam");
        const r = try q.login(c.username, c.password);
        creds.remember(app, q.store, c);
        if (stale_cookies.len > 0) app.note("(Qalam session expired, signed in again)", .{});
        if (r.feedback_pending) return feedbackRequired(app);
    }

    pub const Check = enum { ok, expired, feedback_pending, none };

    /// Whether the saved session still opens the dashboard, without logging in again.
    pub fn check(q: *Qalam) Failed!Check {
        if (!q.loadSession()) return .none;
        if (q.request(.GET, "/student/dashboard", null)) |_| {
            q.saveSession() catch {};
            return .ok;
        } else |e| switch (e) {
            error.AuthExpired => return .expired,
            error.Failed => {
                if (std.mem.eql(u8, q.app.failure.?.code, "FEEDBACK_REQUIRED")) {
                    q.app.failure = null;
                    return .feedback_pending;
                }
                return error.Failed;
            },
        }
    }

    pub fn logout(q: *Qalam) void {
        q.store.remove(session_file);
    }
};

fn feedbackRequired(app: *App) error{Failed} {
    return app.fail("FEEDBACK_REQUIRED", .failure,
        "Qalam blocks every page until the pending QA feedback forms are filled in. Do them at {s}{s} in a browser, then retry (no new login needed)", .{ default_base, feedback_path });
}

test "cookie jar keeps the latest value and drops deletions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var app: App = undefined;
    app.gpa = arena.allocator();
    var q: Qalam = .{ .app = &app, .http = undefined, .store = undefined, .base = default_base };
    q.takeCookies(&.{ "session_id=abc; Path=/; HttpOnly", "frontend_lang=en_US; Path=/" });
    q.takeCookies(&.{"session_id=def; Expires=Sat, 24 Oct 2027 10:00:00 GMT; Path=/"});
    try std.testing.expectEqualStrings("frontend_lang=en_US; session_id=def", q.cookieHeader());
    q.takeCookies(&.{"frontend_lang=; Max-Age=0"});
    try std.testing.expectEqualStrings("session_id=def", q.cookieHeader());
    try std.testing.expect(Qalam.allowed("/student/course/attendance/1"));
    try std.testing.expect(!Qalam.allowed("/web/database/manager"));
    try std.testing.expect(!Qalam.allowed("/student/../web/x"));
}
