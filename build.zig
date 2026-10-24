const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk_opt = b.option([]const u8, "sdk", "macOS SDK path (needed for non-native macOS targets)");
    const version = b.option([]const u8, "version", "Version string") orelse "0.1.0";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = target.result.os.tag == .macos,
    });
    mod.addOptions("build_options", options);
    if (target.result.os.tag == .macos) {
        // Zig only finds the SDK by itself for the native target. Cross builds pass -Dsdk=$(xcrun --show-sdk-path).
        if (sdk_opt) |sdk| {
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
        mod.linkFramework("Security", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("advapi32", .{});
        mod.linkSystemLibrary("kernel32", .{});
    }

    const exe = b.addExecutable(.{ .name = "nust", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run nust").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
