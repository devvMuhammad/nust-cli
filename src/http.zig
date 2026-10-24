//! The only module that talks HTTP. TLS trusts the system roots plus the Sectigo intermediate
//! the LMS server forgets to send; verification always stays on. Redirects are never followed
//! here, so callers decide what a redirect means (Qalam login, feedback gate, unsafe hosts).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const intermediate_pem = @embedFile("sectigo_dv_r36.pem");
const user_agent = "nust-cli/0.1";

pub const Method = std.http.Method;

pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Writes must not be replayed: a request that failed mid-flight may still have been
    /// applied. They also go out on a fresh connection, because the server silently drops
    /// idle keep-alive connections and a write on a dead one could not be told apart from
    /// one that was applied.
    write: bool = false,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    location: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// Raw `Set-Cookie` values, in order.
    set_cookies: []const []const u8 = &.{},
};

pub const Error = error{ Network, OutOfMemory };

pub const Http = struct {
    gpa: Allocator,
    io: Io,
    client: std.http.Client,
    /// Name of the last transport error, for messages. Never contains request data.
    last_error: []const u8 = "",
    /// The system had CA certificates. Without them only the LMS (embedded intermediate) verifies.
    system_roots: bool = true,

    pub fn init(gpa: Allocator, io: Io) !Http {
        var h: Http = .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io } };
        const now = Io.Clock.real.now(io);
        const bundle = &h.client.ca_bundle;
        // Missing system roots are fine: the embedded intermediate alone anchors the chain.
        bundle.rescan(gpa, io, now) catch {};
        h.system_roots = bundle.bytes.items.len > 0;
        const b64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = std.mem.find(u8, intermediate_pem, "-----END").?;
        const body = std.mem.trim(u8, intermediate_pem[begin.len..end], " \t\r\n");
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, body.len);
        bundle.bytes.items.len += try b64.decode(bundle.bytes.allocatedSlice()[start..], body);
        try bundle.parseCert(gpa, start, now.toSeconds());
        h.client.now = now;
        return h;
    }

    /// A transport failure, explained. TLS failing on a machine with no CA certificates is the
    /// one cause the user can fix directly.
    pub fn describe(h: *Http) []const u8 {
        if (!h.system_roots and std.mem.eql(u8, h.last_error, "TlsInitializationFailed"))
            return "no system CA certificates were found, so the site cannot be verified; install the ca-certificates package";
        return h.last_error;
    }

    pub fn send(h: *Http, req: Request) Error!Response {
        return h.sendOnce(req) catch |e| {
            h.last_error = @errorName(e);
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // A read can be resent: the likely cause is a keep-alive connection the server closed.
            if (req.write) return error.Network;
            return h.sendOnce(req) catch |e2| {
                h.last_error = @errorName(e2);
                if (e2 == error.OutOfMemory) return error.OutOfMemory;
                return error.Network;
            };
        };
    }

    fn sendOnce(h: *Http, req: Request) !Response {
        const uri = try std.Uri.parse(req.url);
        if (req.write) {
            // Drop idle pooled connections so the write opens its own.
            try h.client.connection_pool.resize(h.io, 0);
        }
        defer if (req.write) h.client.connection_pool.resize(h.io, 32) catch {};
        var r = try h.client.request(req.method, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = !req.write,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .content_type = if (req.content_type) |ct| .{ .override = ct } else .default,
            },
            .extra_headers = req.headers,
        });
        defer r.deinit();
        if (req.body) |payload| {
            r.transfer_encoding = .{ .content_length = payload.len };
            var bw = try r.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(payload);
            try bw.end();
            try r.connection.?.flush();
        } else {
            try r.sendBodiless();
        }
        var res = try r.receiveHead(&.{});
        var out: Response = .{ .status = @intFromEnum(res.head.status), .body = "" };
        var cookies: std.ArrayList([]const u8) = .empty;
        var it = res.head.iterateHeaders();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "set-cookie")) {
                try cookies.append(h.gpa, try h.gpa.dupe(u8, hdr.value));
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "location")) {
                out.location = try h.gpa.dupe(u8, hdr.value);
            } else if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                out.content_type = try h.gpa.dupe(u8, hdr.value);
            }
        }
        out.set_cookies = cookies.items;
        const decompress_buffer: []u8 = switch (res.head.content_encoding) {
            .identity => &.{},
            .zstd => try h.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try h.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var transfer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = res.readerDecompressing(&transfer, &decompress, decompress_buffer);
        out.body = reader.allocRemaining(h.gpa, .limited(64 << 20)) catch |e| switch (e) {
            error.ReadFailed => return res.bodyErr().?,
            else => |x| return x,
        };
        return out;
    }

    pub const Download = union(enum) {
        /// Bytes written to the destination.
        saved: u64,
        /// The server answered with JSON instead of the file (an error object). First 4 KiB.
        json: []const u8,
        status: u16,
    };

    /// Streams a GET to `dest`, atomically (a temporary file renamed into place).
    pub fn download(h: *Http, url: []const u8, dir: Io.Dir, dest: []const u8) !Download {
        return h.downloadOnce(url, dir, dest) catch |e| {
            h.last_error = @errorName(e);
            return e;
        };
    }

    fn downloadOnce(h: *Http, url: []const u8, dir: Io.Dir, dest: []const u8) !Download {
        const uri = try std.Uri.parse(url);
        var r = try h.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .user_agent = .{ .override = user_agent } },
        });
        defer r.deinit();
        try r.sendBodiless();
        var res = try r.receiveHead(&.{});
        const status: u16 = @intFromEnum(res.head.status);
        if (status != 200) return .{ .status = status };
        const is_json = if (res.head.content_type) |ct| std.mem.find(u8, ct, "json") != null else false;
        var transfer: [64]u8 = undefined;
        const decompress_buffer: []u8 = switch (res.head.content_encoding) {
            .identity => &.{},
            .zstd => try h.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try h.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var decompress: std.http.Decompress = undefined;
        const reader = res.readerDecompressing(&transfer, &decompress, decompress_buffer);
        if (is_json) {
            const head = reader.allocRemaining(h.gpa, .limited(4096)) catch |e| switch (e) {
                error.StreamTooLong => return .{ .json = "" },
                error.ReadFailed => return res.bodyErr().?,
                else => |x| return x,
            };
            return .{ .json = head };
        }
        if (std.fs.path.dirname(dest)) |parent| try dir.createDirPath(h.io, parent);
        var af = try dir.createFileAtomic(h.io, dest, .{ .replace = true });
        defer af.deinit(h.io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = af.file.writer(h.io, &buf);
        const n = reader.streamRemaining(&fw.interface) catch |e| switch (e) {
            error.ReadFailed => return res.bodyErr().?,
            error.WriteFailed => return fw.err.?,
        };
        try fw.interface.flush();
        try af.replace(h.io);
        return .{ .saved = n };
    }
};

/// `application/x-www-form-urlencoded` body.
pub fn formEncode(gpa: Allocator, fields: []const [2][]const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    for (fields, 0..) |f, i| {
        if (i > 0) try aw.writer.writeByte('&');
        try percentEncode(&aw.writer, f[0]);
        try aw.writer.writeByte('=');
        try percentEncode(&aw.writer, f[1]);
    }
    return aw.written();
}

pub fn percentEncode(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

pub const multipart_boundary = "----nustcli7f3a9c1e5b20d4";

/// One file plus text fields, as `multipart/form-data`.
pub fn multipart(gpa: Allocator, fields: []const [2][]const u8, file_field: []const u8, filename: []const u8, data: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    for (fields) |f| try w.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ multipart_boundary, f[0], f[1] });
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ multipart_boundary, file_field, filename });
    try w.writeAll(data);
    try w.print("\r\n--{s}--\r\n", .{multipart_boundary});
    return aw.written();
}

test "form encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try formEncode(arena.allocator(), &.{ .{ "a b", "x&y=1" }, .{ "k[0]", "é" } });
    try std.testing.expectEqualStrings("a%20b=x%26y%3D1&k%5B0%5D=%C3%A9", s);
}
