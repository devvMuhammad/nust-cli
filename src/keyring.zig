//! OS keyring via raw platform APIs. macOS: Security.framework SecItem*. Windows: Credential
//! Manager (advapi32). Linux: shells out to `secret-tool` (libsecret); without it the caller
//! falls back to a private file.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const backend = switch (builtin.os.tag) {
    .macos => "macos-keychain-secitem",
    .windows => "windows-credential-manager",
    else => "linux-secret-tool-cli",
};

pub fn set(gpa: Allocator, io: Io, service: []const u8, account: []const u8, secret: []const u8) !void {
    return impl.set(gpa, io, service, account, secret);
}
pub fn get(gpa: Allocator, io: Io, service: []const u8, account: []const u8) !?[]u8 {
    return impl.get(gpa, io, service, account);
}
pub fn delete(gpa: Allocator, io: Io, service: []const u8, account: []const u8) !void {
    return impl.delete(gpa, io, service, account);
}

const impl = switch (builtin.os.tag) {
    .macos => mac,
    .windows => win,
    else => linux,
};

const mac = struct {
    const Ref = ?*anyopaque;
    extern const kSecClass: Ref;
    extern const kSecClassGenericPassword: Ref;
    extern const kSecAttrService: Ref;
    extern const kSecAttrAccount: Ref;
    extern const kSecValueData: Ref;
    extern const kSecReturnData: Ref;
    extern const kSecMatchLimit: Ref;
    extern const kSecMatchLimitOne: Ref;
    extern const kCFBooleanTrue: Ref;
    extern const kCFTypeDictionaryKeyCallBacks: u8;
    extern const kCFTypeDictionaryValueCallBacks: u8;
    extern fn CFStringCreateWithBytes(alloc: Ref, bytes: [*]const u8, n: isize, enc: u32, ext: bool) Ref;
    extern fn CFDataCreate(alloc: Ref, bytes: [*]const u8, n: isize) Ref;
    extern fn CFDataGetBytePtr(d: Ref) [*]const u8;
    extern fn CFDataGetLength(d: Ref) isize;
    extern fn CFDictionaryCreateMutable(alloc: Ref, cap: isize, k: *const u8, v: *const u8) Ref;
    extern fn CFDictionarySetValue(d: Ref, k: Ref, v: Ref) void;
    extern fn CFRelease(r: Ref) void;
    extern fn SecItemAdd(attrs: Ref, result: ?*Ref) i32;
    extern fn SecItemCopyMatching(query: Ref, result: ?*Ref) i32;
    extern fn SecItemDelete(query: Ref) i32;

    const errSecItemNotFound = -25300;

    fn str(s: []const u8) Ref {
        return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), 0x08000100, false);
    }

    fn query(service: []const u8, account: []const u8) Ref {
        const d = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(d, kSecClass, kSecClassGenericPassword);
        const s = str(service);
        const a = str(account);
        defer CFRelease(s);
        defer CFRelease(a);
        CFDictionarySetValue(d, kSecAttrService, s);
        CFDictionarySetValue(d, kSecAttrAccount, a);
        return d;
    }

    fn set(gpa: Allocator, io: Io, service: []const u8, account: []const u8, secret: []const u8) !void {
        try mac.delete(gpa, io, service, account);
        const d = query(service, account);
        defer CFRelease(d);
        const data = CFDataCreate(null, secret.ptr, @intCast(secret.len));
        defer CFRelease(data);
        CFDictionarySetValue(d, kSecValueData, data);
        if (SecItemAdd(d, null) != 0) return error.KeyringWriteFailed;
    }

    fn get(gpa: Allocator, _: Io, service: []const u8, account: []const u8) !?[]u8 {
        const d = query(service, account);
        defer CFRelease(d);
        CFDictionarySetValue(d, kSecReturnData, kCFBooleanTrue);
        CFDictionarySetValue(d, kSecMatchLimit, kSecMatchLimitOne);
        var result: Ref = null;
        const rc = SecItemCopyMatching(d, &result);
        if (rc == errSecItemNotFound) return null;
        if (rc != 0) return error.KeyringReadFailed;
        defer CFRelease(result);
        return try gpa.dupe(u8, CFDataGetBytePtr(result)[0..@intCast(CFDataGetLength(result))]);
    }

    fn delete(_: Allocator, _: Io, service: []const u8, account: []const u8) !void {
        const d = query(service, account);
        defer CFRelease(d);
        const rc = SecItemDelete(d);
        if (rc != 0 and rc != errSecItemNotFound) return error.KeyringDeleteFailed;
    }
};

const win = struct {
    const Credential = extern struct {
        flags: u32 = 0,
        kind: u32 = 1, // CRED_TYPE_GENERIC
        target: [*:0]const u16,
        comment: ?[*:0]const u16 = null,
        last_written: u64 = 0,
        blob_size: u32,
        blob: [*]const u8,
        persist: u32 = 2, // CRED_PERSIST_LOCAL_MACHINE
        attr_count: u32 = 0,
        attrs: ?*anyopaque = null,
        alias: ?[*:0]const u16 = null,
        user: ?[*:0]const u16 = null,
    };
    extern "advapi32" fn CredWriteW(c: *const Credential, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredReadW(target: [*:0]const u16, kind: u32, flags: u32, out: *?*Credential) callconv(.winapi) i32;
    extern "advapi32" fn CredDeleteW(target: [*:0]const u16, kind: u32, flags: u32) callconv(.winapi) i32;
    extern "advapi32" fn CredFree(p: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    fn target(gpa: Allocator, service: []const u8, account: []const u8) ![:0]u16 {
        const s = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ service, account });
        defer gpa.free(s);
        return std.unicode.utf8ToUtf16LeAllocZ(gpa, s);
    }

    fn set(gpa: Allocator, _: Io, service: []const u8, account: []const u8, secret: []const u8) !void {
        const t = try target(gpa, service, account);
        defer gpa.free(t);
        const c: Credential = .{ .target = t, .blob_size = @intCast(secret.len), .blob = secret.ptr };
        if (CredWriteW(&c, 0) == 0) return error.KeyringWriteFailed;
    }

    fn get(gpa: Allocator, _: Io, service: []const u8, account: []const u8) !?[]u8 {
        const t = try target(gpa, service, account);
        defer gpa.free(t);
        var out: ?*Credential = null;
        if (CredReadW(t, 1, 0, &out) == 0) {
            if (GetLastError() == 1168) return null; // ERROR_NOT_FOUND
            return error.KeyringReadFailed;
        }
        defer CredFree(out.?);
        return try gpa.dupe(u8, out.?.blob[0..out.?.blob_size]);
    }

    fn delete(gpa: Allocator, _: Io, service: []const u8, account: []const u8) !void {
        const t = try target(gpa, service, account);
        defer gpa.free(t);
        if (CredDeleteW(t, 1, 0) == 0 and GetLastError() != 1168) return error.KeyringDeleteFailed;
    }
};

const linux = struct {
    fn run(gpa: Allocator, io: Io, argv: []const []const u8, stdin_data: ?[]const u8) !struct { ok: bool, out: []u8 } {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = if (stdin_data != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SecretToolMissing;
        if (stdin_data) |d| {
            try child.stdin.?.writeStreamingAll(io, d);
            child.stdin.?.close(io);
            child.stdin = null;
        }
        var buf: [4096]u8 = undefined;
        var r = child.stdout.?.readerStreaming(io, &buf);
        const out = try r.interface.allocRemaining(gpa, .limited(1 << 16));
        const term = try child.wait(io);
        return .{ .ok = term.success(), .out = out };
    }

    fn set(gpa: Allocator, io: Io, service: []const u8, account: []const u8, secret: []const u8) !void {
        const r = try run(gpa, io, &.{ "secret-tool", "store", "--label=nust-cli", "service", service, "account", account }, secret);
        gpa.free(r.out);
        if (!r.ok) return error.KeyringWriteFailed;
    }

    fn get(gpa: Allocator, io: Io, service: []const u8, account: []const u8) !?[]u8 {
        const r = try run(gpa, io, &.{ "secret-tool", "lookup", "service", service, "account", account }, null);
        if (!r.ok or r.out.len == 0) {
            gpa.free(r.out);
            return null;
        }
        return r.out;
    }

    fn delete(gpa: Allocator, io: Io, service: []const u8, account: []const u8) !void {
        const r = try run(gpa, io, &.{ "secret-tool", "clear", "service", service, "account", account }, null);
        gpa.free(r.out);
    }
};
