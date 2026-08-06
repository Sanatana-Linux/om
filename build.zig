const std = @import("std");

pub fn build(b: *std.Build) void {
    // When built by Kepr Builds, KEPR_TARGET carries the cross-compile triple
    // so the same command works across all platforms without shell expansion.
    const target = if (b.graph.environ_map.get("KEPR_TARGET")) |t|
        b.resolveTargetQuery(std.Target.Query.parse(
            .{ .arch_os_abi = t },
        ) catch std.Target.Query{})
    else
        b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // VERSION file → build_options.version, accessible from version.zig.
    const version_raw = @embedFile("VERSION");
    const version = std.mem.trim(u8, version_raw, " \r\n\t");
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    // Absolute path to README.md, baked in at build time so tests can read it
    // regardless of the cwd `zig build test` happens to run from. README.md
    // lives outside src/, so it can't be @embedFile'd from within the src/
    // module's package boundary.
    options.addOption([]const u8, "readme_path", b.pathJoin(&.{ b.build_root.path.?, "README.md" }));
    // Absolute path to build.zig.zon, baked in the same way as readme_path so
    // a test can confirm its hand-maintained `.version` field (a kepr-publishing
    // fallback if VERSION is ever lost, per NINA-018) hasn't drifted from VERSION.
    options.addOption([]const u8, "zon_path", b.pathJoin(&.{ b.build_root.path.?, "build.zig.zon" }));

    const exe = b.addExecutable(.{
        .name = "om",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run om");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // rawterm.zig's pty-based tests call libc directly (posix_openpt &
            // co); without an explicit libc link the test step fails to compile.
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
