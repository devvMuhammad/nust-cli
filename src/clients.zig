//! Lazily built clients, so `--help` and usage errors never touch TLS or the disk.
const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Failed = app_mod.Failed;
const Http = @import("http.zig").Http;
const Store = @import("store.zig").Store;
const Moodle = @import("lms/moodle.zig").Moodle;
const Qalam = @import("qalam/client.zig").Qalam;

pub const Clients = struct {
    app: *App,
    http_: ?Http = null,
    store_: ?Store = null,
    moodle_: ?Moodle = null,
    qalam_: ?Qalam = null,

    pub fn store(c: *Clients) Failed!Store {
        if (c.store_ == null) c.store_ = try Store.open(c.app);
        return c.store_.?;
    }

    pub fn http(c: *Clients) Failed!*Http {
        if (c.http_ == null) c.http_ = Http.init(c.app.gpa, c.app.io) catch |e|
            return c.app.fail("TLS_SETUP", .failure, "could not set up TLS: {s}", .{@errorName(e)});
        return &c.http_.?;
    }

    pub fn moodle(c: *Clients) Failed!*Moodle {
        if (c.moodle_ == null) c.moodle_ = try Moodle.init(c.app, try c.http(), try c.store());
        return &c.moodle_.?;
    }

    pub fn qalam(c: *Clients) Failed!*Qalam {
        if (c.qalam_ == null) c.qalam_ = try Qalam.init(c.app, try c.http(), try c.store());
        return &c.qalam_.?;
    }
};
