//! Process-wide context: IO, the arena, environment, clock, output streams and the one failure
//! record. Every command gets an `*App`; nothing else is global.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const timefmt = @import("timefmt.zig");

pub const Exit = enum(u8) {
    ok = 0,
    failure = 1,
    /// Bad arguments, or a prompt was needed and there is no terminal.
    usage = 2,
    /// A safety check refused the action before anything was sent.
    refused = 3,
};

/// The single error every command returns once it has recorded why in `App.failure`.
pub const Failed = error{Failed};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
    exit: Exit,
};

pub const App = struct {
    io: Io,
    /// Process arena. A CLI run is short, so nothing is freed individually.
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    now: i64,
    zone: timefmt.Zone,
    json: bool = false,
    /// `-y`: never prompt, act as if the user answered yes.
    yes: bool = false,
    /// stdin is a terminal, so prompts can be answered.
    interactive: bool,
    out: *Io.Writer,
    err: *Io.Writer,
    failure: ?Failure = null,

    pub fn fail(app: *App, code: []const u8, exit: Exit, comptime fmt: []const u8, args: anytype) Failed {
        app.failure = .{
            .code = code,
            .message = std.fmt.allocPrint(app.gpa, fmt, args) catch "out of memory",
            .exit = exit,
        };
        return error.Failed;
    }

    pub fn print(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.out.print(fmt, args) catch {};
    }

    /// A line for a person on stderr. Silent with `--json`, where stderr carries only the error.
    pub fn note(app: *App, comptime fmt: []const u8, args: anytype) void {
        if (app.json) return;
        app.out.flush() catch {};
        app.err.print(fmt ++ "\n", args) catch {};
        app.err.flush() catch {};
    }

    pub fn flush(app: *App) void {
        app.out.flush() catch {};
        app.err.flush() catch {};
    }

    pub fn getenv(app: *App, name: []const u8) ?[]const u8 {
        const v = app.env.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }

    /// Writes `value` as one JSON document on stdout.
    pub fn emitJson(app: *App, value: anytype) void {
        std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, app.out) catch {};
        app.out.writeByte('\n') catch {};
    }

    /// Reads one line from stdin. `hidden` turns terminal echo off (passwords).
    pub fn prompt(app: *App, label: []const u8, hidden: bool) Failed![]const u8 {
        if (!app.interactive) return app.fail("NO_TERMINAL", .usage, "a prompt is needed but stdin is not a terminal", .{});
        app.out.flush() catch {};
        app.err.writeAll(label) catch {};
        app.err.flush() catch {};
        const stdin = File.stdin();
        const saved = if (hidden) echo.off(stdin.handle) else null;
        defer if (saved) |m| {
            echo.restore(stdin.handle, m);
            app.err.writeAll("\n") catch {};
            app.err.flush() catch {};
        };
        var buf: [1024]u8 = undefined;
        var r = stdin.readerStreaming(app.io, &buf);
        const line = r.interface.takeDelimiter('\n') catch
            return app.fail("NO_TERMINAL", .usage, "could not read from the terminal", .{});
        const got = app.gpa.dupe(u8, line orelse "") catch return app.fail("OOM", .failure, "out of memory", .{});
        return std.mem.trimEnd(u8, got, "\r");
    }

    /// `[y/N]` question. `-y` answers yes without asking.
    pub fn confirm(app: *App, question: []const u8) Failed!bool {
        if (app.yes) return true;
        if (!app.interactive) return app.fail("NO_TERMINAL", .usage, "no terminal to confirm in; add -y to go ahead without asking", .{});
        const answer = try app.prompt(question, false);
        const a = std.mem.trim(u8, answer, " \t");
        return std.ascii.eqlIgnoreCase(a, "y") or std.ascii.eqlIgnoreCase(a, "yes");
    }
};

/// Terminal echo control. Returns the saved mode when stdin is a terminal, null otherwise.
const echo = if (builtin.os.tag == .windows) struct {
    const Saved = u32;
    extern "kernel32" fn GetConsoleMode(h: File.Handle, mode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(h: File.Handle, mode: u32) callconv(.winapi) i32;
    fn off(h: File.Handle) ?Saved {
        var m: u32 = 0;
        if (GetConsoleMode(h, &m) == 0) return null;
        _ = SetConsoleMode(h, m & ~@as(u32, 0x4)); // ENABLE_ECHO_INPUT
        return m;
    }
    fn restore(h: File.Handle, m: Saved) void {
        _ = SetConsoleMode(h, m);
    }
} else struct {
    const Saved = std.posix.termios;
    fn off(h: File.Handle) ?Saved {
        const orig = std.posix.tcgetattr(h) catch return null;
        var t = orig;
        t.lflag.ECHO = false;
        std.posix.tcsetattr(h, .FLUSH, t) catch return null;
        return orig;
    }
    fn restore(h: File.Handle, t: Saved) void {
        std.posix.tcsetattr(h, .FLUSH, t) catch {};
    }
};
