const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const VERSION = build_options.version;

pub const PLATFORM: []const u8 = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => "macos-aarch64",
        .x86_64 => "macos-x86_64",
        else => "unsupported",
    },
    .linux => switch (builtin.cpu.arch) {
        .aarch64 => "linux-aarch64",
        .x86_64 => "linux-x86_64",
        else => "unsupported",
    },
    else => "unsupported",
};

// NINA-018 drift guard: build.zig.zon's `.version` field is a hand-maintained
// fallback the kepr publishing pipeline uses if VERSION is ever lost, so it
// must never silently drift from the real VERSION file. build.zig.zon lives
// outside src/'s package boundary, so it's read at its build-time-baked
// absolute path (build_options.zon_path, same trick as man.zig's readme_path)
// rather than @embedFile'd.
test "build.zig.zon .version matches VERSION" {
    const gpa = std.testing.allocator;
    const zon = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, build_options.zon_path, gpa, .unlimited);
    defer gpa.free(zon);

    const needle = ".version = \"";
    const start = (std.mem.indexOf(u8, zon, needle) orelse
        return error.VersionFieldNotFound) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, zon, start, '"') orelse
        return error.VersionFieldNotFound;
    const zon_version = zon[start..end];

    try std.testing.expectEqualStrings(VERSION, zon_version);
}
