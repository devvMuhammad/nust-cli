//! Site base URLs, overridable for tests. An override must be https, or plain http on loopback.
const std = @import("std");

pub fn parseOverride(raw_in: []const u8) ![]const u8 {
    const raw = std.mem.trimEnd(u8, std.mem.trim(u8, raw_in, " \t"), "/");
    const sep = std.mem.find(u8, raw, "://") orelse return error.BadUrl;
    const scheme = raw[0..sep];
    const rest = raw[sep + 3 ..];
    const authority = rest[0 .. std.mem.findScalar(u8, rest, '/') orelse rest.len];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.BadUrl;
    const host = if (std.mem.startsWith(u8, authority, "["))
        authority[0 .. (std.mem.findScalar(u8, authority, ']') orelse return error.BadUrl) + 1]
    else
        authority[0 .. std.mem.findScalar(u8, authority, ':') orelse authority.len];
    if (host.len == 0) return error.BadUrl;
    if (std.mem.eql(u8, scheme, "https")) return raw;
    if (std.mem.eql(u8, scheme, "http") and (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]")))
        return raw;
    return error.BadUrl;
}

/// Whether `url` belongs to the site at `base` (same scheme, host and port).
pub fn serves(base: []const u8, url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, base)) return false;
    const rest = url[base.len..];
    return rest.len > 0 and (rest[0] == '/' or rest[0] == '?');
}

test "overrides" {
    try std.testing.expectEqualStrings("https://x.edu", try parseOverride("https://x.edu/"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", try parseOverride("http://127.0.0.1:8080"));
    for ([_][]const u8{ "http://x.edu", "http://127.0.0.1.evil.com", "http://localhost.evil.com:80", "ftp://127.0.0.1", "x.edu", "https://u:p@h", "https://" }) |u| {
        try std.testing.expectError(error.BadUrl, parseOverride(u));
    }
    try std.testing.expect(serves("https://lms.nust.edu.pk", "https://lms.nust.edu.pk/webservice/pluginfile.php/1/f.pdf"));
    try std.testing.expect(!serves("https://lms.nust.edu.pk", "https://lms.nust.edu.pk.evil.com/f.pdf"));
    try std.testing.expect(!serves("https://lms.nust.edu.pk", "http://lms.nust.edu.pk/f.pdf"));
}
