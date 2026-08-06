// exec.zig — all process execution and SSH routing
// Commands call these functions; output is streamed or captured here.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const errors = @import("errors.zig");
const output = @import("output.zig");

// nixos-rebuild manages this profile; generation commands must target it
// explicitly. Bare nix-env defaults to the per-user profile, which is empty.
const SYSTEM_PROFILE = "/nix/var/nix/profiles/system";

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

pub const HookResult = enum {
    ok,
    failed,
    not_found,
};

pub const HookRun = struct {
    result: HookResult,
    exit_code: u8 = 0,
    output: []u8,
};

// Run a process and capture stdout+stderr (not streaming).
pub fn capture(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, cmd: []const []const u8) !RunResult {
    const argv = try buildArgv(gpa, machine, cmd);
    defer if (!machine.local) gpa.free(argv);

    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |e| {
        errors.error_info.setMessage("process failed: {s}", .{cmd[0]});
        return e;
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |c| c,
            else => 1,
        },
    };
}

// Run a process and stream its output to the terminal (inherit stdio).
pub fn stream(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, cmd: []const []const u8) !u8 {
    // The child inherits stdout and writes directly to the fd; flush any buffered
    // om header first so it isn't reordered after the child's output.
    output.flush();
    const argv = try buildArgv(gpa, machine, cmd);
    defer if (!machine.local) gpa.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        errors.error_info.setMessage("failed to spawn: {s}", .{cmd[0]});
        return e;
    };

    const term = child.wait(io) catch |e| {
        errors.error_info.setMessage("process wait failed", .{});
        return e;
    };

    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

// Run nix-tree on a package to show what depends on it
pub fn nixTree(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "nix-tree", pkg, "--derivation" });
}

// Stream a process with an overridden PS1 in the child environment.
fn streamEnv(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, cmd: []const []const u8, base_env: *const std.process.Environ.Map, ps1: []const u8) !u8 {
    output.flush();
    const argv = try buildArgv(gpa, machine, cmd);
    defer if (!machine.local) gpa.free(argv);

    var env = try base_env.clone(gpa);
    defer env.deinit();
    try env.put("PS1", ps1);
    try env.put("NINA_PS1", ps1);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    }) catch |e| {
        errors.error_info.setMessage("failed to spawn: {s}", .{cmd[0]});
        return e;
    };

    const term = child.wait(io) catch |e| {
        errors.error_info.setMessage("process wait failed", .{});
        return e;
    };

    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

fn createInteractiveShellRc(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const out = try captureLocal(gpa, io, &.{ "mktemp", "/tmp/om-shell-rc.XXXXXX" });
    defer gpa.free(out);

    const path = std.mem.trim(u8, out, " \t\r\n");
    if (path.len == 0) return error.FileNotFound;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);

    const file = std.Io.Dir.createFile(.cwd(), io, owned_path, .{}) catch {
        errors.error_info.setMessage("could not write shell prompt setup", .{});
        return error.FileNotFound;
    };
    errdefer file.close(io);

    const content =
        \\PS1="${NINA_PS1:-$PS1}"
        \\trap 'exit 130' INT
        \\
    ;
    file.writePositionalAll(io, content, 0) catch {
        errors.error_info.setMessage("could not write shell prompt setup", .{});
        return error.FileNotFound;
    };
    file.close(io);

    return owned_path;
}

// Stream a local process with inherited stdio (no SSH routing — for nix commands).
pub fn streamLocal(io: std.Io, cmd: []const []const u8) !u8 {
    output.flush();
    var child = std.process.spawn(io, .{
        .argv = cmd,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        errors.error_info.setMessage("failed to spawn: {s}", .{cmd[0]});
        return e;
    };
    const term = child.wait(io) catch {
        errors.error_info.setMessage("process wait failed", .{});
        return error.ProcessFailed;
    };
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

// Run a process and capture output as a single string (no SSH routing — for local nix commands).
pub fn captureLocal(gpa: std.mem.Allocator, io: std.Io, cmd: []const []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = cmd }) catch return error.ProcessFailed;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            gpa.free(result.stdout);
            return error.ProcessFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.ProcessFailed;
        },
    }
    return result.stdout;
}

// Create a directory and its parents, best-effort. Shelling out to `mkdir -p`
// matches how the rest of exec.zig provisions config locations (~/.config/nix).
pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) void {
    _ = captureLocal(gpa, io, &.{ "mkdir", "-p", dir }) catch {};
}

// Optional user hooks live in ~/.config/om/hooks and must be executable.
// They are always local: hooks protect the user's local workflow before om
// starts state-changing work.
pub fn runHook(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, hook_name: []const u8) !HookRun {
    const home = environ.get("HOME") orelse return .{
        .result = .not_found,
        .output = try gpa.dupe(u8, ""),
    };

    const hook_dir = try std.fs.path.join(gpa, &.{ home, ".config", "om", "hooks" });
    defer gpa.free(hook_dir);
    ensureDir(gpa, io, hook_dir);

    const hook_path = try std.fs.path.join(gpa, &.{ hook_dir, hook_name });
    defer gpa.free(hook_path);

    const executable = std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", "test -x \"$1\"", "om-hook-check", hook_path } }) catch return .{
        .result = .not_found,
        .output = try gpa.dupe(u8, ""),
    };
    defer gpa.free(executable.stdout);
    defer gpa.free(executable.stderr);
    const is_executable = switch (executable.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!is_executable) return .{
        .result = .not_found,
        .output = try gpa.dupe(u8, ""),
    };

    const tmp_raw = try captureLocal(gpa, io, &.{ "mktemp", "/tmp/om-hook.XXXXXX" });
    defer gpa.free(tmp_raw);
    const tmp_output = std.mem.trim(u8, tmp_raw, " \t\r\n");
    defer if (std.fs.path.isAbsolute(tmp_output)) std.Io.Dir.deleteFileAbsolute(io, tmp_output) catch {};

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "sh",
            "-c",
            "\"$1\" > \"$2\" 2>&1; code=$?; tail -c 4096 \"$2\"; exit \"$code\"",
            "om-hook-run",
            hook_path,
            tmp_output,
        },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(512),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{
        .result = if (exit_code == 0) .ok else .failed,
        .exit_code = exit_code,
        .output = try std.fmt.allocPrint(gpa, "{s}{s}", .{ result.stdout, result.stderr }),
    };
}

test "runHook ignores non-executable hooks and captures failures" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer a.free(home);

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", home);

    var hook_dir = try tmp.dir.createDirPathOpen(io, ".config/om/hooks", .{});
    defer hook_dir.close(io);

    const script =
        \\#!/bin/sh
        \\echo hook says no
        \\echo detail >&2
        \\exit 3
        \\
    ;
    {
        const file = try hook_dir.createFile(io, "pre-apply", .{});
        defer file.close(io);
        try file.writePositionalAll(io, script, 0);
        try file.setPermissions(io, .fromMode(0o644));
    }

    const missing = try runHook(a, io, &env, "pre-apply");
    defer a.free(missing.output);
    try std.testing.expectEqual(HookResult.not_found, missing.result);

    try hook_dir.setFilePermissions(io, "pre-apply", .fromMode(0o755), .{});

    const failed = try runHook(a, io, &env, "pre-apply");
    defer a.free(failed.output);
    try std.testing.expectEqual(HookResult.failed, failed.result);
    try std.testing.expectEqual(@as(u8, 3), failed.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, failed.output, "hook says no") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.output, "detail") != null);

    // NINA-010: the runner script's `$1` (the hook path) must be quoted — a
    // hook whose path contains a space used to word-split and fail to run.
    const spaced_script =
        \\#!/bin/sh
        \\echo spaced hook ran
        \\exit 0
        \\
    ;
    {
        const file = try hook_dir.createFile(io, "post apply", .{});
        defer file.close(io);
        try file.writePositionalAll(io, spaced_script, 0);
        try file.setPermissions(io, .fromMode(0o755));
    }
    const spaced = try runHook(a, io, &env, "post apply");
    defer a.free(spaced.output);
    try std.testing.expectEqual(HookResult.ok, spaced.result);
    try std.testing.expect(std.mem.indexOf(u8, spaced.output, "spaced hook ran") != null);
}

// Single-quote-wrap `arg` for a POSIX shell, escaping embedded single quotes as
// '\''. ssh joins its trailing command arguments with spaces and hands the
// result to the remote login shell for re-parsing, so passing om's argv
// through unquoted lets a package name, config path, or channel URL containing
// shell metacharacters or spaces be word-split or executed on the remote host.
fn shellQuote(gpa: std.mem.Allocator, arg: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(gpa, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, ch);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

fn buildArgv(gpa: std.mem.Allocator, machine: *const types.Machine, cmd: []const []const u8) ![]const []const u8 {
    if (machine.local) return cmd;

    const host = machine.host orelse {
        errors.error_info.setMessage("machine '{s}' has no host configured", .{machine.name});
        return error.SshFailed;
    };

    var ssh: std.ArrayList([]const u8) = .empty;
    try ssh.append(gpa, "ssh");
    try ssh.append(gpa, "-o");
    try ssh.append(gpa, "BatchMode=yes");
    try ssh.append(gpa, "-o");
    try ssh.append(gpa, "StrictHostKeyChecking=accept-new");
    if (machine.ssh_key) |key| {
        try ssh.append(gpa, "-i");
        try ssh.append(gpa, key);
    }
    const addr = if (machine.user) |u|
        try std.fmt.allocPrint(gpa, "{s}@{s}", .{ u, host })
    else
        try gpa.dupe(u8, host);
    try ssh.append(gpa, addr);

    // Quote every word and join into one ssh argument, so ssh has nothing left
    // to re-join with spaces — the remote shell receives exactly our argv.
    var quoted_cmd: std.ArrayList(u8) = .empty;
    for (cmd, 0..) |arg, i| {
        if (i > 0) try quoted_cmd.append(gpa, ' ');
        const q = try shellQuote(gpa, arg);
        defer gpa.free(q);
        try quoted_cmd.appendSlice(gpa, q);
    }
    try ssh.append(gpa, try quoted_cmd.toOwnedSlice(gpa));
    return ssh.toOwnedSlice(gpa);
}

test "shellQuote round-trips metacharacters through a real shell" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const dangerous = [_][]const u8{
        "foo;reboot",
        "foo && rm -rf /",
        "has space",
        "quo'te",
        "$(whoami)",
        "`whoami`",
        "a|b>c<d",
    };

    for (dangerous) |arg| {
        const quoted = try shellQuote(a, arg);
        defer a.free(quoted);

        // A shell asked to print out the quoted word verbatim must reproduce
        // exactly the original string, byte for byte — proving the metacharacters
        // stayed inert instead of being word-split or executed.
        const script = try std.fmt.allocPrint(a, "printf '%s' {s}", .{quoted});
        defer a.free(script);

        const r = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", script } });
        defer a.free(r.stdout);
        defer a.free(r.stderr);

        try std.testing.expectEqual(@as(u8, 0), switch (r.term) {
            .exited => |c| c,
            else => 1,
        });
        try std.testing.expectEqualStrings(arg, r.stdout);
    }
}

test "buildArgv joins a remote command into a single quoted ssh argument" {
    const a = std.testing.allocator;

    const machine: types.Machine = .{
        .name = "box",
        .local = false,
        .host = "example.com",
        .user = "june",
    };

    const argv = try buildArgv(a, &machine, &.{ "nix-env", "-iA", "foo;reboot" });
    defer {
        // Indices 5 (addr) and 6 (the joined quoted command) are the only
        // gpa-owned strings; the rest are literals baked into buildArgv.
        a.free(@constCast(argv[5]));
        a.free(@constCast(argv[6]));
        a.free(argv);
    }

    // Everything after the ssh destination must collapse into exactly one
    // argument — if ssh received the dangerous word as its own separate
    // argument, it would rejoin it with spaces for the remote shell to
    // re-parse, defeating the quoting.
    try std.testing.expectEqualStrings("ssh", argv[0]);
    try std.testing.expectEqualStrings("june@example.com", argv[5]);
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("'nix-env' '-iA' 'foo;reboot'", argv[6]);
}

// --- NixOS rebuild ---

// True if the machine's config dir holds a flake.nix. Only meaningful for a local
// machine — the file lives on the local filesystem. Remote flake detection would
// need an ssh round-trip; a remote flake at the default /etc/nixos needs no flag
// anyway, so we don't bother.
// True if `dir` contains a flake.nix (local filesystem check).
pub fn dirHasFlake(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const flake_path = std.fs.path.join(gpa, &.{ dir, "flake.nix" }) catch return false;
    defer gpa.free(flake_path);
    return pathExists(io, flake_path);
}

pub fn configHasFlake(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) bool {
    if (!machine.local) return false;
    return dirHasFlake(gpa, io, machine.config_path);
}

// nixos-rebuild auto-detects /etc/nixos/flake.nix, so the --flake flag is only
// needed when the flake lives elsewhere. A flake at a non-default path must be
// passed explicitly or nixos-rebuild falls back to channels. Compare with
// trailing slashes trimmed so "/etc/nixos/" is still treated as the default.
fn useFlakeFlag(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) bool {
    if (!configHasFlake(gpa, io, machine)) return false;
    var path = machine.config_path;
    while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    return !std.mem.eql(u8, path, "/etc/nixos");
}

// Capture nixos-rebuild stderr for the translation pipeline. Raw nix build
// output is suppressed; on failure, reportError() translates stderr via
// errors.translateError(). The substep line above the call tells the user what
// is running; silence during the build is intentional per the error-wrapping brief.
fn nixosRebuildRun(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, verb: []const u8, flake: bool, extra_flags: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "sudo", "nixos-rebuild", verb });
    if (flake) try argv.appendSlice(gpa, &.{ "--flake", machine.config_path });
    try argv.appendSlice(gpa, extra_flags);

    output.flush();
    const r = try capture(gpa, io, machine, argv.items);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errors.setBuildStderr(r.stderr);
    return r.exit_code;
}

pub fn nixosRebuildSwitch(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    const flake = useFlakeFlag(gpa, io, machine);
    if (flake) {
        output.printSubstep("nixos-rebuild switch --flake {s}", .{machine.config_path});
    } else {
        output.printSubstep("nixos-rebuild switch", .{});
    }
    return nixosRebuildRun(io, machine, gpa, "switch", flake, extra_flags);
}

// Live-streaming variant used by `apply` when stdout is a TTY. Each stderr line
// from nixos-rebuild is fed to the build panel for real-time progress display
// while the full stderr is also accumulated for the error translation pipeline.
// Falls back to the silent capture path when not a TTY.
pub fn nixosRebuildSwitchWithPanel(
    io: std.Io,
    machine: *const types.Machine,
    gpa: std.mem.Allocator,
    panel: *output.BuildPanel,
    extra_flags: []const []const u8,
) !u8 {
    const flake = useFlakeFlag(gpa, io, machine);
    if (flake) {
        output.printSubstep("nixos-rebuild switch --flake {s}", .{machine.config_path});
    } else {
        output.printSubstep("nixos-rebuild switch", .{});
    }
    if (!output.colorEnabled()) return nixosRebuildRun(io, machine, gpa, "switch", flake, extra_flags);
    return nixosRebuildRunStreamed(io, machine, gpa, "switch", flake, panel, extra_flags);
}

// Spawn argv with stderr piped, feed each line to the build panel for live progress,
// and accumulate the full stderr (newlines preserved) for errors.translateError.
// Factored out of nixosRebuildRunStreamed so the read loop is testable without a
// real nixos-rebuild binary.
fn runStreamedCapture(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, panel: *output.BuildPanel) !u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |e| {
        errors.error_info.setMessage("failed to spawn nixos-rebuild", .{});
        return e;
    };

    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(gpa);

    if (child.stderr) |stderr_file| {
        var reader_buf: [8192]u8 = undefined;
        var fr = std.Io.File.Reader.initStreaming(stderr_file, io, &reader_buf);
        while (true) {
            const raw = fr.interface.takeDelimiter('\n') catch |err| switch (err) {
                // A single line exceeded the reader's buffer — routine for nix eval
                // traces/derivation lists. Discard the oversized remainder instead of
                // abandoning the pipe: breaking here would leave stderr undrained, and
                // once the kernel pipe buffer filled the child would block on write()
                // forever, hanging child.wait() below.
                error.StreamTooLong => {
                    _ = fr.interface.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
                error.ReadFailed => break,
            } orelse break;
            // takeDelimiter excludes the delimiter, so re-add it or every downstream
            // line-oriented consumer in errors.zig sees one giant concatenated line.
            accumulated.appendSlice(gpa, raw) catch {};
            accumulated.append(gpa, '\n') catch {};
            const line = std.mem.trimEnd(u8, raw, "\r");
            panel.update(line);
            panel.render();
        }
    }

    errors.setBuildStderr(accumulated.items);

    const term = child.wait(io) catch |e| {
        errors.error_info.setMessage("nixos-rebuild wait failed", .{});
        return e;
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn nixosRebuildRunStreamed(
    io: std.Io,
    machine: *const types.Machine,
    gpa: std.mem.Allocator,
    verb: []const u8,
    flake: bool,
    panel: *output.BuildPanel,
    extra_flags: []const []const u8,
) !u8 {
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    try argv_list.appendSlice(gpa, &.{ "sudo", "nixos-rebuild", verb });
    if (flake) try argv_list.appendSlice(gpa, &.{ "--flake", machine.config_path });
    try argv_list.appendSlice(gpa, extra_flags);

    output.flush();
    const built_argv = try buildArgv(gpa, machine, argv_list.items);
    defer if (!machine.local) gpa.free(built_argv);

    return runStreamedCapture(io, gpa, built_argv, panel);
}

test "runStreamedCapture preserves newlines and survives an oversized stderr line (NINA-001/002)" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    // panel.render() writes through output's global writer, which only main.zig
    // initializes in real runs. Point it at a discard sink with color off so the
    // test exercises the real render() call path without a live terminal.
    var discard_buf: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&discard_buf);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    output.init(&discarding.writer, io, &env, false);

    var panel: output.BuildPanel = .{};

    // A single stderr line over 8192 bytes (the reader's fixed buffer size) used to
    // trip error.StreamTooLong and abandon the pipe (NINA-002); it must now be
    // discarded and draining must continue for the lines that follow.
    var oversized: [9000]u8 = undefined;
    @memset(&oversized, 'x');

    const script = try std.fmt.allocPrint(a,
        \\exec >&2
        \\printf 'these 3 paths will be fetched (12.3 MiB download, 45.6 MiB unpacked)\n'
        \\printf '%s\n' "{s}"
        \\printf 'error: om test canary xyz-explanation\n'
        \\printf 'For full logs, run some-command\n'
        \\exit 1
    , .{oversized});
    defer a.free(script);

    const exit_code = try runStreamedCapture(io, a, &.{ "sh", "-c", script }, &panel);
    try std.testing.expectEqual(@as(u8, 1), exit_code);

    const stderr = errors.getBuildStderr();
    // Newlines must survive accumulation (NINA-001) — without them, every
    // line-oriented consumer downstream (innermostError, extractLocation,
    // extractWarnings) sees one giant concatenated line instead of real lines.
    try std.testing.expect(std.mem.indexOf(u8, stderr, "error: om test canary xyz-explanation\n") != null);

    // translateError's returned strings are a mix of literals and heap allocations
    // depending which layer matched; an arena sidesteps the ownership ambiguity.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const translated = errors.translateError(arena.allocator(), stderr);
    // Must reach Layer 2's structured extraction (innermostError needs a trimmed
    // line starting with "error:") rather than falling through to the generic
    // Layer-3 fallback, which is only reachable when line structure is lost.
    try std.testing.expect(!std.mem.eql(u8, translated.body, "something went wrong that om couldn't translate."));
}

pub fn nixosRebuildDryActivate(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    return nixosRebuildRun(io, machine, gpa, "dry-activate", useFlakeFlag(gpa, io, machine), extra_flags);
}

pub fn nixosRebuildBuild(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    return nixosRebuildRun(io, machine, gpa, "build", useFlakeFlag(gpa, io, machine), extra_flags);
}

// --- Generations ---

// Read system-profile generations WITHOUT root. `nix-env --list-generations -p
// /nix/var/nix/profiles/system` takes a profile lock and fails as a normal user
// ("system.lock: Permission denied"). The generation symlinks themselves are
// world-readable, so list them directly: parse `system-N-link` names, take each
// link's own mtime for the date/time, and mark the one the `system` symlink
// points at as current. Output matches the `nix-env --list-generations` columns
// (num date time [current]) so parseGenerations is unchanged.
const GEN_LIST_SCRIPT =
    \\cur=$(readlink /nix/var/nix/profiles/system 2>/dev/null | sed 's/.*system-\([0-9]*\)-link/\1/'); find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' -printf '%f %TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sed 's/system-\([0-9]*\)-link/\1/' | sort -n | awk -v c="$cur" '{ if ($1==c) print $0" current"; else print $0 }'
;

pub fn getGenerations(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]types.GenerationInfo {
    const r = try capture(gpa, io, machine, &.{ "sh", "-c", GEN_LIST_SCRIPT });
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.ProcessFailed;
    return parseGenerations(gpa, r.stdout);
}

fn parseGenerations(gpa: std.mem.Allocator, output_str: []const u8) ![]types.GenerationInfo {
    var gens: std.ArrayList(types.GenerationInfo) = .empty;
    var lines = std.mem.splitScalar(u8, output_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const num_str = parts.next() orelse continue;
        const date_str = parts.next() orelse continue;
        const time_str = parts.next() orelse continue;
        const rest = parts.rest();
        const current = std.mem.indexOf(u8, rest, "current") != null;
        const num = std.fmt.parseInt(u32, num_str, 10) catch continue;
        try gens.append(gpa, .{
            .number = num,
            .date = try gpa.dupe(u8, date_str),
            .time = try gpa.dupe(u8, time_str),
            .current = current,
        });
    }
    return gens.toOwnedSlice(gpa);
}

pub fn getCurrentGeneration(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) !u32 {
    const gens = try getGenerations(gpa, io, machine);
    defer gpa.free(gens);
    for (gens) |g| {
        if (g.current) return g.number;
    }
    return 0;
}

pub fn switchGeneration(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, n: u32) !u8 {
    // Switch the system profile to generation n, then activate it (bootloader +
    // services). Without switch-to-configuration the change isn't applied.
    const cmd = try std.fmt.allocPrint(gpa, "nix-env -p {s} --switch-generation {d} && {s}/bin/switch-to-configuration switch", .{ SYSTEM_PROFILE, n, SYSTEM_PROFILE });
    defer gpa.free(cmd);
    return stream(io, machine, gpa, &.{ "sudo", "sh", "-c", cmd });
}

pub fn rollback(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nixos-rebuild", "switch", "--rollback" });
}

pub fn deleteGeneration(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, n: u32) !u8 {
    const n_str = try std.fmt.allocPrint(gpa, "{d}", .{n});
    defer gpa.free(n_str);
    return stream(io, machine, gpa, &.{ "sudo", "nix-env", "-p", SYSTEM_PROFILE, "--delete-generations", n_str });
}

pub fn deleteOldGenerations(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nix-env", "-p", SYSTEM_PROFILE, "--delete-generations", "old" });
}

// --- Garbage collection ---

// Global to communicate freed bytes from exec to command handler.
var freed_bytes: u64 = 0;

pub fn setFreedBytes(bytes: u64) void {
    freed_bytes = bytes;
}

pub fn getFreedBytes() u64 {
    return freed_bytes;
}

// Comprehensive clean: clear caches, old generations, garbage collect, report freed space
pub fn comprehensiveClean(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, delete_old: bool, keep: u32) !u8 {
    // Measure store size before
    const before = try capture(gpa, io, machine, &.{ "sh", "-c", "du -sb /nix/store 2>/dev/null | cut -f1" });
    defer gpa.free(before.stdout);
    defer gpa.free(before.stderr);

    // Clear user caches
    _ = try stream(io, machine, gpa, &.{ "sh", "-c", "rm -rf ~/.cache/nix ~/.cache/nixpkgs 2>/dev/null; true" });

    // Clear nix-env stale packages
    _ = try stream(io, machine, gpa, &.{ "sh", "-c", "nix-env --delete-generations old 2>/dev/null; true" });

    // Clear nix profile stale packages
    _ = try stream(io, machine, gpa, &.{ "sh", "-c", "nix profile list 2>/dev/null | grep -v 'nixpkgs#' | awk '{print $1}' | xargs -r nix profile remove 2>/dev/null; true" });

    // Delete old system generations
    if (delete_old) {
        _ = try stream(io, machine, gpa, &.{ "sudo", "nix-collect-garbage", "-d" });
    } else {
        const cmd = try std.fmt.allocPrint(gpa, "nix-env -p {s} --delete-generations +{d} && nix-collect-garbage", .{ SYSTEM_PROFILE, keep });
        defer gpa.free(cmd);
        _ = try stream(io, machine, gpa, &.{ "sudo", "sh", "-c", cmd });
    }

    // Measure store size after
    const after = try capture(gpa, io, machine, &.{ "sh", "-c", "du -sb /nix/store 2>/dev/null | cut -f1" });
    defer gpa.free(after.stdout);
    defer gpa.free(after.stderr);

    // Calculate freed space
    const before_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, before.stdout, " \t\n\r"), 10) catch 0;
    const after_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, after.stdout, " \t\n\r"), 10) catch 0;

    // Store the freed amount in a global for the command handler to read
    setFreedBytes(before_bytes -| after_bytes);

    return 0;
}

// --- Channels ---

pub fn channelList(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]types.ChannelInfo {
    const r = try capture(gpa, io, machine, &.{ "nix-channel", "--list" });
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.ProcessFailed;
    return parseChannels(gpa, r.stdout);
}

fn parseChannels(gpa: std.mem.Allocator, output_str: []const u8) ![]types.ChannelInfo {
    var channels: std.ArrayList(types.ChannelInfo) = .empty;
    var lines = std.mem.splitScalar(u8, output_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        try channels.append(gpa, .{
            .name = try gpa.dupe(u8, trimmed[0..space]),
            .url = try gpa.dupe(u8, std.mem.trim(u8, trimmed[space + 1 ..], " \t")),
        });
    }
    return channels.toOwnedSlice(gpa);
}

pub fn channelUpdate(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nix-channel", "--update" });
}

pub fn channelAdd(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, url: []const u8, name: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nix-channel", "--add", url, name });
}

pub fn channelRemove(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, name: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "nix-channel", "--remove", name });
}

// --- Sync ---

// Sync submodules: loop through the submodules of /etc/nixos, add/commit/push
// each, then do the same for the main repository itself. Every git step is
// best-effort (|| true) so one failing submodule doesn't abort the loop.
pub fn syncSubmodules(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    // Run a shell script that:
    // 1. Gets list of submodules from .gitmodules
    // 2. For each: cd into it, git add -A, git commit -m "om sync: auto-update", git push
    // 3. Then in the main repo: git add -A, git commit -m "om sync: update submodules", git push
    const script =
        \\cd /etc/nixos && \
        \\if [ -f .gitmodules ]; then \
        \\  git submodule foreach 'git add -A && git commit -m "om sync: auto-update" || true && git push || true' && \
        \\  git add -A && \
        \\  git commit -m "om sync: update submodules" || true && \
        \\  git push || true; \
        \\else \
        \\  git add -A && \
        \\  git commit -m "om sync: auto-update" || true && \
        \\  git push || true; \
        \\fi
    ;
    return stream(io, machine, gpa, &.{ "sh", "-c", script });
}

// --- Services ---

pub fn serviceList(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, user: bool) ![]types.ServiceInfo {
    const cmd: []const []const u8 = if (user)
        &.{ "systemctl", "--user", "list-units", "--type=service", "--no-legend", "--no-pager" }
    else
        &.{ "systemctl", "list-units", "--type=service", "--no-legend", "--no-pager" };
    const r = try capture(gpa, io, machine, cmd);
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.ProcessFailed;
    return parseServices(gpa, r.stdout);
}

fn parseServices(gpa: std.mem.Allocator, output_str: []const u8) ![]types.ServiceInfo {
    var svcs: std.ArrayList(types.ServiceInfo) = .empty;
    var lines = std.mem.splitScalar(u8, output_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == 0xE2) continue; // skip UTF-8 bullet lines
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const name = parts.next() orelse continue;
        _ = parts.next(); // load
        const active_str = parts.next() orelse continue;
        const sub_str = parts.next() orelse "unknown";

        const state: types.ServiceState = if (std.mem.eql(u8, active_str, "active"))
            (if (std.mem.eql(u8, sub_str, "running") or std.mem.eql(u8, sub_str, "exited")) .active else .active)
        else if (std.mem.eql(u8, active_str, "failed"))
            .failed
        else
            .inactive;

        try svcs.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .state = state,
            .uptime = null,
        });
    }
    return svcs.toOwnedSlice(gpa);
}

pub fn serviceCtl(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, verb: []const u8, name: []const u8, user: bool) !u8 {
    // --no-pager: `systemctl status` pipes to a pager on a tty and would block.
    // User services run under the caller's own systemd manager, so no sudo.
    if (user) {
        return stream(io, machine, gpa, &.{ "systemctl", "--user", "--no-pager", verb, name });
    }
    return stream(io, machine, gpa, &.{ "sudo", "systemctl", "--no-pager", verb, name });
}

pub fn serviceLogs(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, name: []const u8, last: u32, follow: bool, user: bool) !u8 {
    const n_str = try std.fmt.allocPrint(gpa, "{d}", .{last});
    defer gpa.free(n_str);
    if (user) {
        if (follow) return stream(io, machine, gpa, &.{ "journalctl", "--user", "-u", name, "-f" });
        return stream(io, machine, gpa, &.{ "journalctl", "--user", "-u", name, "-n", n_str, "--no-pager" });
    }
    if (follow) {
        return stream(io, machine, gpa, &.{ "journalctl", "-u", name, "-f" });
    }
    return stream(io, machine, gpa, &.{ "journalctl", "-u", name, "-n", n_str, "--no-pager" });
}

// --- Profile ---

// Stream with one extra environment variable injected alongside the inherited env.
// Used for cases like NIXPKGS_ALLOW_UNFREE=1 where we need a single override
// without replacing the full parent environment.
fn streamWithEnvVar(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, cmd: []const []const u8, base_env: *const std.process.Environ.Map, key: []const u8, val: []const u8) !u8 {
    output.flush();
    const argv = try buildArgv(gpa, machine, cmd);
    defer if (!machine.local) gpa.free(argv);

    var env = try base_env.clone(gpa);
    defer env.deinit();
    try env.put(key, val);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env,
    }) catch |e| {
        errors.error_info.setMessage("failed to spawn: {s}", .{cmd[0]});
        return e;
    };

    const term = child.wait(io) catch |e| {
        errors.error_info.setMessage("process wait failed", .{});
        return e;
    };

    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

pub fn profileInstall(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, attr: []const u8, allow_unfree: bool) !u8 {
    const pkg_ref = try std.fmt.allocPrint(gpa, "nixpkgs#{s}", .{attr});
    defer gpa.free(pkg_ref);
    // `nix profile add` is the current verb; `install` is a deprecated alias that
    // prints a warning on modern nix.
    if (allow_unfree) {
        // The package is unfree and the user's system-wide allowUnfree setting
        // doesn't propagate to imperative nix commands. Pass NIXPKGS_ALLOW_UNFREE=1
        // and --impure so the profile add succeeds: --impure allows builtins.getEnv
        // to read the env var inside the nixpkgs flake's pure evaluation context.
        return streamWithEnvVar(io, machine, gpa, &.{ "nix", "profile", "add", "--impure", pkg_ref }, environ, "NIXPKGS_ALLOW_UNFREE", "1");
    }
    return stream(io, machine, gpa, &.{ "nix", "profile", "add", pkg_ref });
}

pub fn profileRemove(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, attr: []const u8) !u8 {
    // `nix profile remove` matches by profile element name (e.g. "ripgrep"), not
    // by flake ref — passing nixpkgs#ripgrep matches nothing.
    return stream(io, machine, gpa, &.{ "nix", "profile", "remove", attr });
}

pub fn profileList(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix", "profile", "list" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) return error.ProcessFailed;
    return r.stdout;
}

// Machine-readable profile listing — caller parses elements -> name + version.
pub fn profileListJson(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix", "profile", "list", "--json" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// Returns the profile element name to pass to `nix profile remove/upgrade`
// (e.g. "om" or "default"), or null if om is not found. Caller owns the
// returned slice. A NixOS system-package install also resolves into /nix/store
// so the store path alone can't distinguish it from a profile install — the
// profile list can. A missing/empty profile (or no nix) returns null.
pub fn profileNinaElement(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ?[]const u8 {
    const js = profileListJson(gpa, io, machine) catch return null;
    defer gpa.free(js);
    return profileJsonNinaElement(gpa, js);
}


pub fn profileHasNina(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) bool {
    const name = profileNinaElement(gpa, io, machine) orelse return false;
    gpa.free(name);
    return true;
}

// True when a nix store path belongs to the om package. Store paths have the
// form /nix/store/<32-char-hash>-<pname>-<version>[/<subpath>]. We check that
// the 33 chars after /nix/store/ are the hash+dash, and the pname that follows
// is exactly "om" (followed by "-" or end-of-component).
fn storePathIsNina(path: []const u8) bool {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rel = path[prefix.len..];
    // The store entry name ends at the first "/" (if any sub-path follows).
    const entry = rel[0 .. std.mem.indexOf(u8, rel, "/") orelse rel.len];
    if (entry.len < 34) return false; // 32-char hash + dash + at least one char
    const pname_ver = entry[33..]; // skip hash + dash
    return std.mem.startsWith(u8, pname_ver, "om-") or std.mem.eql(u8, pname_ver, "om");
}

// Pure parse of `nix profile list --json` for a om element, returning its
// element name (the key to pass to `nix profile remove/upgrade`) or null.
// Newer nix (2.18+) keys elements by pname ("om"). Older nix uses an array
// with an "attrPath" field. Tarball installs via the `default` output may use
// the key "default" instead of "om"; we detect those via storePaths.
fn profileJsonNinaElement(gpa: std.mem.Allocator, js: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, js, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const elements = root.object.get("elements") orelse return null;
    switch (elements) {
        .object => |obj| {
            // Fast path: exact "om" key (nix 2.18+ with nixpkgs#om install).
            if (obj.contains("om")) return gpa.dupe(u8, "om") catch null;
            // Fallback: scan storePaths. Handles tarball installs where the default
            // output is selected and nix names the element "default" (older nix) or
            // some other key derived from the attrPath rather than the pname.
            var it = obj.iterator();
            while (it.next()) |kv| {
                const val = kv.value_ptr.*;
                if (val != .object) continue;
                const sps = val.object.get("storePaths") orelse continue;
                if (sps != .array) continue;
                for (sps.array.items) |sp| {
                    if (sp == .string and storePathIsNina(sp.string))
                        return gpa.dupe(u8, kv.key_ptr.*) catch null;
                }
            }
            return null;
        },
        .array => |arr| {
            // Older nix array format. Element name is the last component of attrPath.
            for (arr.items) |el| {
                if (el != .object) continue;
                const ap = el.object.get("attrPath") orelse continue;
                if (ap != .string) continue;
                if (std.mem.eql(u8, ap.string, "om") or
                    std.mem.endsWith(u8, ap.string, ".om"))
                    return gpa.dupe(u8, "om") catch null;
                // Tarball default-output install: attrPath ends in ".default" but
                // storePaths point to om. Return "default" as the element name.
                const sps = el.object.get("storePaths") orelse continue;
                if (sps != .array) continue;
                for (sps.array.items) |sp| {
                    if (sp != .string) continue;
                    if (!storePathIsNina(sp.string)) continue;
                    const dot = std.mem.lastIndexOf(u8, ap.string, ".") orelse 0;
                    const el_name = if (dot > 0) ap.string[dot + 1 ..] else ap.string;
                    return gpa.dupe(u8, el_name) catch null;
                }
            }
            return null;
        },
        else => return null,
    }
}

test "profileJsonNinaElement finds element name from profile JSON" {
    const a = std.testing.allocator;

    // Newer nix: elements keyed by pname. "om" key present.
    const named =
        \\{"elements":{"bat":{"storePaths":["/nix/store/h0000000000000000000000000000000-bat-0.26.1"]},
        \\"om":{"attrPath":"packages.x86_64-linux.om","storePaths":["/nix/store/a0000000000000000000000000000000-nina-3.0.15"]}},"version":3}
    ;
    const r1 = profileJsonNinaElement(a, named);
    defer if (r1) |n| a.free(n);
    try std.testing.expectEqualStrings("om", r1.?);

    // Tarball install via default output: element keyed as "default", storePath is om.
    const default_key =
        \\{"elements":{"default":{"attrPath":"packages.x86_64-linux.default","storePaths":["/nix/store/w0000000000000000000000000000000-om-3.0.16"]}},"version":3}
    ;
    const r2 = profileJsonNinaElement(a, default_key);
    defer if (r2) |n| a.free(n);
    try std.testing.expectEqualStrings("default", r2.?);

    // Decoy: storePath of another package contains "om" as a substring but is not om.
    const decoy =
        \\{"elements":{"luminance":{"storePaths":["/nix/store/x0000000000000000000000000000000-luminance-nina-1.0"]}},"version":3}
    ;
    const r3 = profileJsonNinaElement(a, decoy);
    try std.testing.expectEqual(@as(?[]const u8, null), r3);

    // Older nix array schema, attrPath ending in ".om".
    const arr =
        \\{"elements":[{"attrPath":"legacyPackages.x86_64-linux.om","storePaths":["/nix/store/a0000000000000000000000000000000-nina-3.0.15"]}],"version":2}
    ;
    const r4 = profileJsonNinaElement(a, arr);
    defer if (r4) |n| a.free(n);
    try std.testing.expectEqualStrings("om", r4.?);

    // Older nix array schema, tarball default-output install.
    const arr_default =
        \\{"elements":[{"attrPath":"packages.x86_64-linux.default","storePaths":["/nix/store/w0000000000000000000000000000000-om-3.0.16"]}],"version":2}
    ;
    const r5 = profileJsonNinaElement(a, arr_default);
    defer if (r5) |n| a.free(n);
    try std.testing.expectEqualStrings("default", r5.?);

    // Empty / malformed → null.
    try std.testing.expectEqual(@as(?[]const u8, null), profileJsonNinaElement(a, "{\"elements\":{},\"version\":3}"));
    try std.testing.expectEqual(@as(?[]const u8, null), profileJsonNinaElement(a, "not json"));
}

// The store paths that make up the running system environment. Each reference is
// a <hash>-<name>-<version> path, so the caller can list system packages with
// versions — there is no cleaner per-package list for environment.systemPackages.
pub fn systemPackagePaths(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix-store", "-q", "--references", "/run/current-system/sw" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn profileUpgrade(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "profile", "upgrade", ".*" });
}

// --- Store ---

pub fn storeGc(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nix-collect-garbage" });
}

pub fn storeVerify(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "store", "verify", "--all" });
}

// Deduplicate identical store files via hard links — frees space without
// garbage-collecting any paths.
pub fn storeOptimise(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "store", "optimise" });
}

// Optimize the nix store with verbose output
pub fn storeOptimiseVerbose(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    _ = try stream(io, machine, gpa, &.{ "sudo", "nix", "store", "optimise", "--verbose" });
    return stream(io, machine, gpa, &.{ "sudo", "nix-store", "--optimise", "--verbose" });
}

pub const SystemStatus = struct { size: []u8, age: []u8 };

// One read-only pass for `om status`: the current system's closure size (a
// single `path-info -S` of /run/current-system — fast, unlike -S over the whole
// store) and seconds since the system profile was last switched (its symlink
// mtime). Both are world-readable; no root needed.
const STATUS_SCRIPT =
    \\sz=$(nix path-info -S /run/current-system 2>/dev/null | awk '{print $NF}'); mt=$(stat -c %Y /nix/var/nix/profiles/system 2>/dev/null); now=$(date +%s); echo "${sz:-0} $(( ${now:-0} - ${mt:-0} ))"
;

// Get the system closure size in GB for a given machine
pub fn systemWeight(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    // Use nix path-info to get the closure size of the current system
    const r = try capture(gpa, io, machine, &.{ "sh", "-c", "nix path-info -Sh /run/current-system 2>/dev/null | tail -1 | awk '{print $2}'" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn systemStatus(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) SystemStatus {
    const unknown = SystemStatus{
        .size = gpa.dupe(u8, "") catch return .{ .size = "", .age = "" },
        .age = gpa.dupe(u8, "") catch return .{ .size = "", .age = "" },
    };
    const r = capture(gpa, io, machine, &.{ "sh", "-c", STATUS_SCRIPT }) catch return unknown;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) return unknown;

    var it = std.mem.tokenizeAny(u8, r.stdout, " \t\n\r");
    const sz_str = it.next() orelse return unknown;
    const age_str = it.next() orelse return unknown;
    const bytes = std.fmt.parseInt(u64, sz_str, 10) catch 0;
    const age_secs = std.fmt.parseInt(u64, age_str, 10) catch 0;

    gpa.free(unknown.size);
    gpa.free(unknown.age);
    return .{
        .size = humanSize(gpa, bytes) catch (gpa.dupe(u8, "") catch ""),
        .age = humanAgo(gpa, age_secs) catch (gpa.dupe(u8, "") catch ""),
    };
}

// `systemctl is-system-running` -> "running" / "degraded" / "starting" ... A
// one-word health signal; exits non-zero when degraded, so we read stdout, not
// the code. Caller owns the returned slice.
pub fn systemRunningState(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = capture(gpa, io, machine, &.{ "systemctl", "is-system-running" }) catch
        return gpa.dupe(u8, "unknown");
    defer gpa.free(r.stderr);
    const state = std.mem.trim(u8, r.stdout, " \t\n\r");
    const owned = try gpa.dupe(u8, if (state.len > 0) state else "unknown");
    gpa.free(r.stdout);
    return owned;
}

fn humanAgo(gpa: std.mem.Allocator, secs: u64) ![]u8 {
    if (secs < 60) return std.fmt.allocPrint(gpa, "{d}s ago", .{secs});
    if (secs < 3600) return std.fmt.allocPrint(gpa, "{d}m ago", .{secs / 60});
    if (secs < 86400) return std.fmt.allocPrint(gpa, "{d}h ago", .{secs / 3600});
    return std.fmt.allocPrint(gpa, "{d}d ago", .{secs / 86400});
}

pub fn storeRepair(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sudo", "nix", "store", "repair", "--all" });
}

pub fn storeInfo(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) !types.StoreInfo {
    // `nix path-info -S --all` computes the CLOSURE size of every path — O(paths^2)
    // graph work that takes minutes on a real store (59k+ paths) and hangs the
    // command. We don't need closures: `--all --json` (no -S) carries each path's
    // own narSize, so one fast pass gives the path count and the summed store size.
    // `du -sh /nix/store` is just as slow on a big store, so it's gone too.
    // timeout-wrapped so a pathological store degrades to "?" instead of hanging.
    const pi = try capture(gpa, io, machine, &.{ "sh", "-c", "timeout 90 nix path-info --all --json 2>/dev/null" });
    defer gpa.free(pi.stdout);
    defer gpa.free(pi.stderr);

    const scan = scanStoreJson(pi.stdout);
    const total_owned = try humanSize(gpa, scan.total_bytes);

    return .{
        .total_size = total_owned,
        .live_paths = scan.count,
        .reclaimable_paths = 0,
    };
}

const StoreScan = struct { count: u64, total_bytes: u64 };

// One linear pass over `nix path-info --json`: each path object has exactly one
// "narSize": field, so counting them gives the true path count and summing the
// values gives the total store size — no per-path closure walk.
fn scanStoreJson(json_str: []const u8) StoreScan {
    const needle = "\"narSize\":";
    var count: u64 = 0;
    var total: u64 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, json_str, i, needle)) |pos| {
        var j = pos + needle.len;
        while (j < json_str.len and json_str[j] == ' ') : (j += 1) {}
        var val: u64 = 0;
        var any = false;
        while (j < json_str.len and json_str[j] >= '0' and json_str[j] <= '9') : (j += 1) {
            val = val * 10 + (json_str[j] - '0');
            any = true;
        }
        if (any) {
            count += 1;
            total += val;
        }
        i = j;
    }
    return .{ .count = count, .total_bytes = total };
}

fn humanSize(gpa: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var val: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (val >= 1024.0 and unit + 1 < units.len) : (unit += 1) val /= 1024.0;
    if (unit == 0) return std.fmt.allocPrint(gpa, "{d} {s}", .{ bytes, units[0] });
    return std.fmt.allocPrint(gpa, "{d:.1} {s}", .{ val, units[unit] });
}

pub fn storePath(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, attr: []const u8) ![]u8 {
    // nixpkgs#<attr>, not .#<attr>: the package lives in nixpkgs (resolved via the
    // flake registry), not a flake in the current directory.
    const expr = try std.fmt.allocPrint(gpa, "nixpkgs#{s}.outPath", .{attr});
    defer gpa.free(expr);
    const r = try capture(gpa, io, machine, &.{ "nix", "eval", "--raw", expr });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// --- Flake ---

pub fn flakeUpdate(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, input: ?[]const u8, extra_flags: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nix", "flake", "update" });
    if (input) |inp| try argv.append(gpa, inp);
    try argv.appendSlice(gpa, extra_flags);
    return stream(io, machine, gpa, argv.items);
}

pub fn flakeLockOverrideInput(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, input: []const u8, flake_ref: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "flake", "lock", "--override-input", input, flake_ref });
}

pub fn flakeLockOverrideRef(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, input: []const u8, rev: []const u8) ![]u8 {
    const r = capture(gpa, io, machine, &.{ "cat", "flake.lock" }) catch return error.FileNotFound;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        errors.error_info.setMessage("could not read flake.lock", .{});
        errors.error_info.setSuggestion("run om pin from the flake directory", .{});
        return error.FileNotFound;
    }
    return flakeOverrideRefFromLock(gpa, r.stdout, input, rev);
}

fn jsonObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |obj| obj,
        else => null,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn inputNodeName(nodes: std.json.ObjectMap, root_name: []const u8, input: []const u8) ?[]const u8 {
    const root_v = nodes.get(root_name) orelse return null;
    const root = jsonObject(root_v) orelse return null;
    const inputs_v = root.get("inputs") orelse return null;
    const inputs = jsonObject(inputs_v) orelse return null;
    const target = inputs.get(input) orelse return null;
    return switch (target) {
        .string => |s| s,
        .array => |arr| {
            if (arr.items.len == 0) return null;
            return switch (arr.items[arr.items.len - 1]) {
                .string => |s| s,
                else => null,
            };
        },
        else => null,
    };
}

fn appendQueryString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, first: *bool, key: []const u8, value: []const u8) !void {
    try out.append(gpa, if (first.*) '?' else '&');
    first.* = false;
    try out.appendSlice(gpa, key);
    try out.append(gpa, '=');
    try out.appendSlice(gpa, value);
}

fn appendQueryBool(out: *std.ArrayList(u8), gpa: std.mem.Allocator, first: *bool, key: []const u8, obj: std.json.ObjectMap) !void {
    const v = obj.get(key) orelse return;
    if (v != .bool) return;
    try appendQueryString(out, gpa, first, key, if (v.bool) "1" else "0");
}

fn appendSharedFlakeRefQuery(out: *std.ArrayList(u8), gpa: std.mem.Allocator, first: *bool, source: std.json.ObjectMap) !void {
    if (jsonString(source, "dir")) |dir| try appendQueryString(out, gpa, first, "dir", dir);
    try appendQueryBool(out, gpa, first, "submodules", source);
    try appendQueryBool(out, gpa, first, "lfs", source);
    try appendQueryBool(out, gpa, first, "shallow", source);
    try appendQueryBool(out, gpa, first, "allRefs", source);
}

fn sourceObject(node: std.json.ObjectMap) ?std.json.ObjectMap {
    if (node.get("original")) |v| {
        if (jsonObject(v)) |obj| return obj;
    }
    if (node.get("locked")) |v| {
        if (jsonObject(v)) |obj| return obj;
    }
    return null;
}

fn forgeFlakeRef(gpa: std.mem.Allocator, prefix: []const u8, source: std.json.ObjectMap, rev: []const u8) ![]u8 {
    if (source.get("host") != null) {
        errors.error_info.setMessage("cannot pin non-default {s} host automatically", .{prefix});
        errors.error_info.setSuggestion("use nix flake lock --override-input <input> <flake-ref>", .{});
        return error.Internal;
    }
    const owner = jsonString(source, "owner") orelse {
        errors.error_info.setMessage("flake.lock input is missing owner", .{});
        return error.Internal;
    };
    const repo = jsonString(source, "repo") orelse {
        errors.error_info.setMessage("flake.lock input is missing repo", .{});
        return error.Internal;
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    try out.append(gpa, ':');
    try out.appendSlice(gpa, owner);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, repo);
    var first_query = true;
    try appendQueryString(&out, gpa, &first_query, "rev", rev);
    try appendSharedFlakeRefQuery(&out, gpa, &first_query, source);
    return out.toOwnedSlice(gpa);
}

fn gitFlakeRef(gpa: std.mem.Allocator, source: std.json.ObjectMap, rev: []const u8) ![]u8 {
    const url = jsonString(source, "url") orelse {
        errors.error_info.setMessage("git flake.lock input is missing url", .{});
        return error.Internal;
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (!std.mem.startsWith(u8, url, "git+")) try out.appendSlice(gpa, "git+");
    try out.appendSlice(gpa, url);
    var first_query = std.mem.indexOfScalar(u8, url, '?') == null;
    try appendQueryString(&out, gpa, &first_query, "rev", rev);
    try appendSharedFlakeRefQuery(&out, gpa, &first_query, source);
    return out.toOwnedSlice(gpa);
}

pub fn flakeOverrideRefFromLock(gpa: std.mem.Allocator, lock_json: []const u8, input: []const u8, rev: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, lock_json, .{}) catch {
        errors.error_info.setMessage("could not parse flake.lock", .{});
        return error.ConfigParseError;
    };
    defer parsed.deinit();

    const root = jsonObject(parsed.value) orelse {
        errors.error_info.setMessage("could not parse flake.lock", .{});
        return error.ConfigParseError;
    };
    const nodes_v = root.get("nodes") orelse {
        errors.error_info.setMessage("flake.lock has no nodes", .{});
        return error.ConfigParseError;
    };
    const nodes = jsonObject(nodes_v) orelse {
        errors.error_info.setMessage("flake.lock nodes are malformed", .{});
        return error.ConfigParseError;
    };
    const root_name = jsonString(root, "root") orelse "root";
    const node_name = inputNodeName(nodes, root_name, input) orelse input;
    const node_v = nodes.get(node_name) orelse {
        errors.error_info.setMessage("flake input '{s}' not found in flake.lock", .{input});
        errors.error_info.setSuggestion("run om flake update first", .{});
        return error.Internal;
    };
    const node = jsonObject(node_v) orelse {
        errors.error_info.setMessage("flake input '{s}' is malformed", .{input});
        return error.ConfigParseError;
    };
    const source = sourceObject(node) orelse {
        errors.error_info.setMessage("flake input '{s}' has no source metadata", .{input});
        return error.Internal;
    };
    const typ = jsonString(source, "type") orelse {
        errors.error_info.setMessage("flake input '{s}' has no source type", .{input});
        return error.Internal;
    };

    if (std.mem.eql(u8, typ, "github")) return forgeFlakeRef(gpa, "github", source, rev);
    if (std.mem.eql(u8, typ, "gitlab")) return forgeFlakeRef(gpa, "gitlab", source, rev);
    if (std.mem.eql(u8, typ, "sourcehut")) return forgeFlakeRef(gpa, "sourcehut", source, rev);
    if (std.mem.eql(u8, typ, "git")) return gitFlakeRef(gpa, source, rev);

    errors.error_info.setMessage("cannot pin flake input '{s}' of type '{s}'", .{ input, typ });
    errors.error_info.setSuggestion("use nix flake lock --override-input <input> <flake-ref>", .{});
    return error.Internal;
}

test "flakeOverrideRefFromLock resolves root github input" {
    const a = std.testing.allocator;
    const lock =
        \\{
        \\  "nodes": {
        \\    "nixpkgs": {
        \\      "locked": { "owner": "NixOS", "repo": "nixpkgs", "rev": "old", "type": "github" },
        \\      "original": { "owner": "NixOS", "ref": "nixos-unstable", "repo": "nixpkgs", "type": "github" }
        \\    },
        \\    "root": { "inputs": { "nixpkgs": "nixpkgs" } }
        \\  },
        \\  "root": "root",
        \\  "version": 7
        \\}
    ;
    const ref = try flakeOverrideRefFromLock(a, lock, "nixpkgs", "abcdef");
    defer a.free(ref);
    try std.testing.expectEqualStrings("github:NixOS/nixpkgs?rev=abcdef", ref);
}

test "flakeOverrideRefFromLock preserves dir and boolean source flags" {
    const a = std.testing.allocator;
    const lock =
        \\{
        \\  "nodes": {
        \\    "dep-node": {
        \\      "original": {
        \\        "owner": "me",
        \\        "repo": "mono",
        \\        "type": "github",
        \\        "dir": "sub/flake",
        \\        "submodules": true
        \\      }
        \\    },
        \\    "root": { "inputs": { "dep": "dep-node" } }
        \\  },
        \\  "root": "root",
        \\  "version": 7
        \\}
    ;
    const ref = try flakeOverrideRefFromLock(a, lock, "dep", "1234");
    defer a.free(ref);
    try std.testing.expectEqualStrings("github:me/mono?rev=1234&dir=sub/flake&submodules=1", ref);
}

test "flakeOverrideRefFromLock resolves generic git inputs" {
    const a = std.testing.allocator;
    const lock =
        \\{
        \\  "nodes": {
        \\    "dep": {
        \\      "original": { "type": "git", "url": "https://example.com/repo.git" }
        \\    },
        \\    "root": { "inputs": { "dep": "dep" } }
        \\  },
        \\  "root": "root",
        \\  "version": 7
        \\}
    ;
    const ref = try flakeOverrideRefFromLock(a, lock, "dep", "deadbeef");
    defer a.free(ref);
    try std.testing.expectEqualStrings("git+https://example.com/repo.git?rev=deadbeef", ref);
}

test "flakeOverrideRefFromLock rejects unsupported source types" {
    const a = std.testing.allocator;
    const lock =
        \\{
        \\  "nodes": {
        \\    "local": { "original": { "type": "path", "path": "./dep" } },
        \\    "root": { "inputs": { "local": "local" } }
        \\  },
        \\  "root": "root",
        \\  "version": 7
        \\}
    ;
    try std.testing.expectError(error.Internal, flakeOverrideRefFromLock(a, lock, "local", "deadbeef"));
}

// Update flake inputs for the flake living in `dir` (the config dir). `nix flake
// update` operates on the flake in the working directory, so we cd there first.
// Used by `om upgrade` on a flake system in place of nix-channel --update.
pub fn flakeUpdateAt(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, dir: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "sh", "-c", "cd \"$0\" && nix flake update", dir });
}

// Update flake.lock in /etc/nixos
pub fn flakeUpdateAtConfig(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "sh", "-c", "cd /etc/nixos && nix flake update" });
}

pub fn flakeCheck(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nix", "flake", "check" });
    try argv.appendSlice(gpa, extra_flags);
    return stream(io, machine, gpa, argv.items);
}

pub fn flakeInit(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "flake", "init" });
}

pub fn flakeLock(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "flake", "lock" });
}

pub fn flakeClone(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, url: []const u8) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "flake", "clone", url });
}

pub fn flakeShow(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix", "flake", "show", "--json" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// --- Build / Run / Develop ---

pub fn nixBuild(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, attr: ?[]const u8, extra_flags: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "nix");
    try argv.append(gpa, "build");
    var ref_buf: ?[]u8 = null;
    defer if (ref_buf) |r| gpa.free(r);
    if (attr) |a| {
        ref_buf = try std.fmt.allocPrint(gpa, ".#{s}", .{a});
        try argv.append(gpa, ref_buf.?);
    }
    try argv.appendSlice(gpa, extra_flags);
    return stream(io, machine, gpa, argv.items);
}

pub fn nixRun(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8, extra_flags: []const []const u8) !u8 {
    // nix run always gets --no-write-lock-file for remote URLs
    const is_url = std.mem.startsWith(u8, pkg, "http://") or std.mem.startsWith(u8, pkg, "https://") or std.mem.startsWith(u8, pkg, "github:");

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "nix");
    try argv.append(gpa, "run");

    var ref_buf: ?[]u8 = null;
    defer if (ref_buf) |r| gpa.free(r);
    if (is_url) {
        try argv.append(gpa, pkg);
        try argv.append(gpa, "--no-write-lock-file");
    } else if (std.mem.indexOfScalar(u8, pkg, '#') != null) {
        // Already a flake ref (contains '#') → use as-is; bare name → default to nixpkgs#.
        try argv.append(gpa, pkg);
    } else {
        ref_buf = try std.fmt.allocPrint(gpa, "nixpkgs#{s}", .{pkg});
        try argv.append(gpa, ref_buf.?);
    }

    // extra_flags carries any `-- <program args>` separator verbatim, so this
    // naturally reconstructs `nix run <ref> -- <args>` — nix's own convention.
    try argv.appendSlice(gpa, extra_flags);
    return stream(io, machine, gpa, argv.items);
}

pub fn nixShell(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8) !u8 {
    const ref = try std.fmt.allocPrint(gpa, "nixpkgs#{s}", .{pkg});
    defer gpa.free(ref);
    return stream(io, machine, gpa, &.{ "nix", "shell", ref });
}

pub fn nixShellPs1(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8, base_env: *const std.process.Environ.Map) !u8 {
    const ref = try std.fmt.allocPrint(gpa, "nixpkgs#{s}", .{pkg});
    defer gpa.free(ref);
    const ps1 = try std.fmt.allocPrint(gpa, "(om: {s}) -> ", .{pkg});
    defer gpa.free(ps1);
    if (machine.local) {
        const rc_path = try createInteractiveShellRc(gpa, io);
        defer {
            std.Io.Dir.deleteFile(.cwd(), io, rc_path) catch {};
            gpa.free(rc_path);
        }
        return streamEnv(io, machine, gpa, &.{ "nix", "shell", ref, "--command", "bash", "--rcfile", rc_path, "-i" }, base_env, ps1);
    }
    return streamEnv(io, machine, gpa, &.{ "nix", "shell", ref }, base_env, ps1);
}

pub fn nixDevelop(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, run_cmd: ?[]const u8, extra_flags: []const []const u8) !u8 {
    if (run_cmd) |cmd| {
        // sh -c so a multi-word command isn't treated as a single executable name.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "nix", "develop", "--command", "sh", "-c", cmd });
        try argv.appendSlice(gpa, extra_flags);
        return stream(io, machine, gpa, argv.items);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "nix");
    try argv.append(gpa, "develop");
    try argv.appendSlice(gpa, extra_flags);
    return stream(io, machine, gpa, argv.items);
}

pub fn nixDevelopPs1(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, run_cmd: ?[]const u8, base_env: *const std.process.Environ.Map, extra_flags: []const []const u8) !u8 {
    if (run_cmd) |cmd| {
        // sh -c so a multi-word command isn't treated as a single executable name.
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "nix", "develop", "--command", "sh", "-c", cmd });
        try argv.appendSlice(gpa, extra_flags);
        return stream(io, machine, gpa, argv.items);
    }
    if (machine.local) {
        const rc_path = try createInteractiveShellRc(gpa, io);
        defer {
            std.Io.Dir.deleteFile(.cwd(), io, rc_path) catch {};
            gpa.free(rc_path);
        }
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, "nix");
        try argv.append(gpa, "develop");
        try argv.appendSlice(gpa, extra_flags);
        try argv.appendSlice(gpa, &.{ "--command", "bash", "--rcfile", rc_path, "-i" });
        return streamEnv(io, machine, gpa, argv.items, base_env, "(om: dev) -> ");
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "nix");
    try argv.append(gpa, "develop");
    try argv.appendSlice(gpa, extra_flags);
    return streamEnv(io, machine, gpa, argv.items, base_env, "(om: dev) -> ");
}

pub fn nixRepl(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    return stream(io, machine, gpa, &.{ "nix", "repl", "--expr", "import <nixpkgs> {}" });
}

// --- Format ---

pub fn nixpkgsFmt(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, path: []const u8, check: bool) !u8 {
    if (check) {
        return stream(io, machine, gpa, &.{ "nixpkgs-fmt", "--check", path });
    }
    return stream(io, machine, gpa, &.{ "nixpkgs-fmt", path });
}

// --- Info ---

pub fn systemInfo(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{"nixos-version"});
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn kernelInfo(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "uname", "-r" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn uptimeInfo(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{"uptime"});
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// --- Boot ---

pub fn bootEntries(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]types.BootEntry {
    const r = try capture(gpa, io, machine, &.{ "bootctl", "list" });
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.ProcessFailed;
    return parseBootEntries(gpa, r.stdout);
}

fn parseBootEntries(gpa: std.mem.Allocator, output_str: []const u8) ![]types.BootEntry {
    var entries: std.ArrayList(types.BootEntry) = .empty;
    var lines = std.mem.splitScalar(u8, output_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "title:")) {
            const title = std.mem.trim(u8, trimmed[6..], " \t");
            const current = std.mem.indexOf(u8, title, "(current)") != null;
            try entries.append(gpa, .{
                .title = try gpa.dupe(u8, title),
                .current = current,
            });
        }
    }
    return entries.toOwnedSlice(gpa);
}

// --- Pkg info ---

fn pkgInstallable(gpa: std.mem.Allocator, pkg: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "nixpkgs#{s}", .{pkg});
}

fn resolvePkgStorePath(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, installable: []const u8) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix", "build", "--no-link", "--print-out-paths", installable });
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.PackageNotFound;

    var lines = std.mem.tokenizeAny(u8, r.stdout, "\r\n");
    const first_path = lines.next() orelse return error.PackageNotFound;
    const store_path = std.mem.trim(u8, first_path, " \t");
    if (store_path.len == 0) return error.PackageNotFound;
    return gpa.dupe(u8, store_path);
}

pub fn pkgWhy(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8) !u8 {
    const installable = try pkgInstallable(gpa, pkg);
    defer gpa.free(installable);
    const store_path = try resolvePkgStorePath(gpa, io, machine, installable);
    defer gpa.free(store_path);
    return stream(io, machine, gpa, &.{ "nix", "why-depends", "/run/current-system", store_path });
}

pub fn pkgDeps(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8) !u8 {
    const installable = try pkgInstallable(gpa, pkg);
    defer gpa.free(installable);
    const store_path = try resolvePkgStorePath(gpa, io, machine, installable);
    defer gpa.free(store_path);
    return stream(io, machine, gpa, &.{ "nix-store", "--query", "--requisites", store_path });
}

pub fn pkgSize(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, pkg: []const u8) ![]u8 {
    const installable = try pkgInstallable(gpa, pkg);
    defer gpa.free(installable);
    const r = try capture(gpa, io, machine, &.{ "nix", "path-info", "-s", "--json", installable });
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (r.exit_code != 0) return error.ProcessFailed;

    const nar_size = try pathInfoNarSize(gpa, r.stdout);
    return humanPkgSize(gpa, nar_size);
}

pub fn pkgClosure(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, pkg: []const u8) !u8 {
    const installable = try pkgInstallable(gpa, pkg);
    defer gpa.free(installable);
    const store_path = try resolvePkgStorePath(gpa, io, machine, installable);
    defer gpa.free(store_path);
    return stream(io, machine, gpa, &.{ "nix", "path-info", "-rS", store_path });
}

fn pathInfoNarSize(gpa: std.mem.Allocator, json_str: []const u8) !u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{}) catch return error.ProcessFailed;
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.object.get("narSize")) |v| {
                        if (v == .integer and v.integer >= 0) return @intCast(v.integer);
                    }
                }
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .object) {
                    if (item.object.get("narSize")) |v| {
                        if (v == .integer and v.integer >= 0) return @intCast(v.integer);
                    }
                }
            }
        },
        else => {},
    }
    return error.ProcessFailed;
}

fn humanPkgSize(gpa: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var val: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (val >= 1024.0 and unit + 1 < units.len) : (unit += 1) val /= 1024.0;
    if (unit == 0) return std.fmt.allocPrint(gpa, "{d} {s}", .{ bytes, units[0] });
    return std.fmt.allocPrint(gpa, "{d:.1} {s}", .{ val, units[unit] });
}

test "pathInfoNarSize parses object and array shapes" {
    try std.testing.expectEqual(@as(u64, 1064629862), try pathInfoNarSize(std.testing.allocator,
        \\{"/nix/store/abc-ffmpeg":{"narSize":1064629862}}
    ));
    try std.testing.expectEqual(@as(u64, 2048), try pathInfoNarSize(std.testing.allocator,
        \\[{"path":"/nix/store/abc-pkg","narSize":2048}]
    ));
}

// --- Hash / Fetch ---

pub fn nixHash(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, path: []const u8) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix", "hash", "path", path });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn nixFetch(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, url: []const u8) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix-prefetch-url", url });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

pub fn openEditor(io: std.Io, gpa: std.mem.Allocator, editor: []const u8, path: []const u8, line: ?u32) !u8 {
    if (line) |l| {
        const line_arg = try std.fmt.allocPrint(gpa, "+{d}", .{l});
        defer gpa.free(line_arg);
        return stream(io, &types.Machine{}, gpa, &.{ editor, path, line_arg });
    }
    return stream(io, &types.Machine{}, gpa, &.{ editor, path });
}

// Open a config directory as root with `sudo -E <editor> <path>` — `-E`
// preserves the user's environment (PATH, TERM, EDITOR config) so the editor
// behaves the same as it does unprivileged. Used by `om edit --dir`.
pub fn openEditorSudo(io: std.Io, gpa: std.mem.Allocator, editor: []const u8, path: []const u8) !u8 {
    return stream(io, &types.Machine{}, gpa, &.{ "sudo", "-E", editor, path });
}

pub fn diffClosures(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, a: u32, b: u32) !u8 {
    const a_str = try std.fmt.allocPrint(gpa, "/nix/var/nix/profiles/system-{d}-link", .{a});
    defer gpa.free(a_str);
    const b_str = try std.fmt.allocPrint(gpa, "/nix/var/nix/profiles/system-{d}-link", .{b});
    defer gpa.free(b_str);
    // On a tty, the child's own color is fine — stream it directly.
    if (output.colorEnabled()) {
        return stream(io, machine, gpa, &.{ "nix", "store", "diff-closures", a_str, b_str });
    }
    // Piped/redirected: nix store diff-closures colorizes regardless of NO_COLOR,
    // so we can't ask it to stop — capture its output and strip the ANSI ourselves.
    const r = try capture(gpa, io, machine, &.{ "nix", "store", "diff-closures", a_str, b_str });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const cleaned = try output.sanitize(gpa, r.stdout);
    defer gpa.free(cleaned);
    output.raw(cleaned);
    return r.exit_code;
}

// --- Doctor checks ---

pub fn runDoctorChecks(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]types.DoctorCheck {
    var checks: std.ArrayList(types.DoctorCheck) = .empty;

    // Check nix daemon
    {
        const r = try capture(gpa, io, machine, &.{ "systemctl", "is-active", "nix-daemon" });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        const active = std.mem.indexOf(u8, r.stdout, "active") != null;
        try checks.append(gpa, .{ .name = "nix daemon", .status = if (active) .ok else .fail });
    }

    // Check config syntax. Flake-aware like apply/upgrade: on a flake system a
    // plain `nixos-rebuild dry-build` evaluates <nixpkgs/nixos> + <nixos-config>
    // (channel style) and fails, so pass --flake when the config dir has one.
    // No sudo: dry-build only evaluates + builds, it never activates, so it
    // needs no more privilege than reading the config and talking to the nix
    // daemon over its (world-writable) socket — unlike switch/activate below.
    {
        const argv: []const []const u8 = if (useFlakeFlag(gpa, io, machine))
            &.{ "nixos-rebuild", "dry-build", "--flake", machine.config_path }
        else
            &.{ "nixos-rebuild", "dry-build" };
        const r = try capture(gpa, io, machine, argv);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try checks.append(gpa, .{ .name = "config syntax", .status = if (r.exit_code == 0) .ok else .fail });
    }

    // Check channel
    {
        const r = try capture(gpa, io, machine, &.{ "nix-channel", "--list" });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        const has_channel = r.exit_code == 0 and r.stdout.len > 0;
        try checks.append(gpa, .{ .name = "channel", .status = if (has_channel) .ok else .warn });
    }

    return checks.toOwnedSlice(gpa);
}

// --- Home Manager ---
//
// Home Manager has three usage modes. om detects which one is in play before
// any `home` command so it can either drive the standalone CLI or redirect the
// user to `om apply` (when HM is a NixOS/flake module activated by rebuild).

pub const HomeManagerMode = enum {
    // home-manager binary on PATH — manages the user env on its own.
    standalone,
    // No binary, but a home.nix exists — HM is a NixOS/flake module rebuilt by
    // nixos-rebuild. `om home apply` redirects to `om apply`.
    module,
    none,
};

fn homeConfigDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    return std.fmt.allocPrint(gpa, "{s}/.config/home-manager", .{home}) catch null;
}

// Path to the standalone home.nix. Caller frees.
pub fn homeNixPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const dir = homeConfigDir(gpa, environ) orelse return null;
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/home.nix", .{dir}) catch null;
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// `command -v <name>` — true if the binary resolves on PATH. Silent (captured),
// unlike streamLocal which would inherit stdio.
// `name` is passed as real argv (positional $1), never interpolated into the
// script text — only "home-manager" reaches this today, but this is the one
// place in exec.zig that used to build shell syntax from a parameter.
fn commandExists(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "_", name } }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn detectHomeManager(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) HomeManagerMode {
    if (commandExists(gpa, io, "home-manager")) return .standalone;
    if (homeNixPath(gpa, environ)) |p| {
        defer gpa.free(p);
        if (pathExists(io, p)) return .module;
    }
    return .none;
}

// The home-manager config dir when it holds a flake.nix (a flake-based home
// config that `home-manager switch --flake` drives). null for a channel-based
// config, which uses a plain `home-manager switch`. Caller frees.
pub fn homeFlakeDir(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ?[]const u8 {
    const dir = homeConfigDir(gpa, environ) orelse return null;
    const flake = std.fmt.allocPrint(gpa, "{s}/flake.nix", .{dir}) catch {
        gpa.free(dir);
        return null;
    };
    defer gpa.free(flake);
    if (!pathExists(io, flake)) {
        gpa.free(dir);
        return null;
    }
    return dir;
}

// Platform-specific home-manager attribute "<user>-<arch>-<os>" (e.g.
// murazaki-x86_64-linux) — the homeConfigurations key many flakes derive from
// ${USER}-${system}. arch/os come from uname on the local host (home commands
// are local-only). Caller frees.
pub fn homeManagerAttr(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, environ: *const std.process.Environ.Map) ![]const u8 {
    const user = environ.get("USER") orelse "user";

    const arch_r = try capture(gpa, io, machine, &.{ "uname", "-m" });
    defer gpa.free(arch_r.stdout);
    defer gpa.free(arch_r.stderr);
    if (arch_r.exit_code != 0) return error.ProcessFailed;
    const arch = std.mem.trim(u8, arch_r.stdout, " \t\r\n");

    const os_r = try capture(gpa, io, machine, &.{ "uname", "-s" });
    defer gpa.free(os_r.stdout);
    defer gpa.free(os_r.stderr);
    if (os_r.exit_code != 0) return error.ProcessFailed;
    const os = try gpa.dupe(u8, std.mem.trim(u8, os_r.stdout, " \t\r\n"));
    defer gpa.free(os);
    for (os) |*ch| ch.* = std.ascii.toLower(ch.*);

    if (arch.len == 0 or os.len == 0) return error.ProcessFailed;
    return std.fmt.allocPrint(gpa, "{s}-{s}-{s}", .{ user, arch, os });
}

// Map a nixos-version string to the matching home-manager branch: an unstable
// channel ("…pre…"/"unstable") → master; a stable release like
// "25.05.20250115.abcdef (Warbler)" → release-25.05. Anything unparseable
// falls back to master. Caller frees.
fn homeBranchFromVersion(gpa: std.mem.Allocator, version_raw: []const u8) ![]const u8 {
    const v = std.mem.trim(u8, version_raw, " \t\r\n");
    if (std.mem.indexOf(u8, v, "pre") != null or
        std.mem.indexOf(u8, v, "unstable") != null)
        return gpa.dupe(u8, "master");

    const head = v[0 .. std.mem.indexOfScalar(u8, v, ' ') orelse v.len];
    var it = std.mem.splitScalar(u8, head, '.');
    const major = it.next() orelse "";
    const minor = it.next() orelse "";
    if (allDigits(major) and allDigits(minor))
        return std.fmt.allocPrint(gpa, "release-{s}.{s}", .{ major, minor });

    return gpa.dupe(u8, "master");
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

test "homeBranchFromVersion maps channels to HM branches" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "25.05.20250115.abcdef (Warbler)", .want = "release-25.05" },
        .{ .in = "24.11.20241201.deadbee (Vicuna)", .want = "release-24.11" },
        .{ .in = "25.11pre-git", .want = "master" },
        .{ .in = "25.05pre789012.abcdef (Warbler)", .want = "master" },
        .{ .in = "nixos-unstable", .want = "master" },
        .{ .in = "garbage", .want = "master" },
    };
    for (cases) |c| {
        const got = try homeBranchFromVersion(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

// The home-manager branch matching the running nixpkgs. Falls back to master
// when nixos-version is unavailable (non-NixOS host). Caller frees.
fn detectHomeManagerBranch(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]const u8 {
    const r = capture(gpa, io, machine, &.{"nixos-version"}) catch
        return gpa.dupe(u8, "master");
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) return gpa.dupe(u8, "master");
    return homeBranchFromVersion(gpa, r.stdout);
}

// `nix run home-manager/<branch> -- init [--switch] [dir]` — generates
// flake.nix + home.nix (in dir, or ~/.config/home-manager by default),
// activating immediately when switch_on_init is set.
pub fn homeManagerInit(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, switch_on_init: bool, dir: ?[]const u8) !u8 {
    const branch = try detectHomeManagerBranch(gpa, io, machine);
    defer gpa.free(branch);
    const flake_ref = try std.fmt.allocPrint(gpa, "home-manager/{s}", .{branch});
    defer gpa.free(flake_ref);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "nix", "run", flake_ref, "--", "init" });
    if (switch_on_init) try argv.append(gpa, "--switch");
    if (dir) |d| try argv.append(gpa, d);

    return stream(io, machine, gpa, argv.items);
}

pub fn homeManagerSwitch(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    output.flush();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "home-manager", "switch" });
    try argv.appendSlice(gpa, extra_flags);
    const r = try capture(gpa, io, machine, argv.items);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errors.setBuildStderr(r.stderr);
    return r.exit_code;
}

// Outcome of a flake-based switch, so the caller can fall back to a less
// specific attribute on a missing-attribute evaluation error — but never on a
// genuine build failure.
pub const SwitchOutcome = enum { ok, attr_missing, failed };

pub fn homeManagerSwitchFlake(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, flake_ref: []const u8, extra_flags: []const []const u8) !SwitchOutcome {
    output.flush();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "home-manager", "switch", "--flake", flake_ref });
    try argv.appendSlice(gpa, extra_flags);
    const r = try capture(gpa, io, machine, argv.items);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.exit_code == 0) return .ok;
    // A flake that doesn't define this homeConfiguration fails during evaluation
    // with "does not provide attribute" — surface that so the caller can retry a
    // different attr rather than treating it as a build failure.
    if (std.mem.indexOf(u8, r.stderr, "does not provide attribute") != null)
        return .attr_missing;
    errors.setBuildStderr(r.stderr);
    return .failed;
}

// home-manager has no system-profile rollback; it re-activates the previous
// generation via `switch --rollback`.
pub fn homeManagerRollback(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator) !u8 {
    output.flush();
    const r = try capture(gpa, io, machine, &.{ "home-manager", "switch", "--rollback" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errors.setBuildStderr(r.stderr);
    return r.exit_code;
}

// Build (and validate) the home config without activating it — used by `home
// check` and `home apply --dry`. `home-manager build` drops a ./result symlink
// in the cwd, so run it in a throwaway temp dir to avoid littering the directory
// om was invoked from.
pub fn homeManagerBuild(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, extra_flags: []const []const u8) !u8 {
    output.flush();
    // extra_flags are passed as real argv elements after the literal `--`, picked
    // up via "$@" — never interpolated into the script text, so an extra flag
    // can't smuggle shell metacharacters into the command.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "sh", "-c", "d=$(mktemp -d) && cd \"$d\" && home-manager build \"$@\"", "--" });
    try argv.appendSlice(gpa, extra_flags);
    const r = try capture(gpa, io, machine, argv.items);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errors.setBuildStderr(r.stderr);
    return r.exit_code;
}

pub fn homeGenerations(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "home-manager", "generations" });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// Store paths referenced by a home generation — used to list managed packages.
pub fn homeGenerationReferences(gpa: std.mem.Allocator, io: std.Io, machine: *const types.Machine, gen_path: []const u8) ![]u8 {
    const r = try capture(gpa, io, machine, &.{ "nix-store", "-q", "--references", gen_path });
    defer gpa.free(r.stderr);
    if (r.exit_code != 0) {
        gpa.free(r.stdout);
        return error.ProcessFailed;
    }
    return r.stdout;
}

// diff-closures between two arbitrary store paths (home generations), mirroring
// diffClosures' tty/piped color handling.
pub fn diffClosuresPaths(io: std.Io, machine: *const types.Machine, gpa: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !u8 {
    if (output.colorEnabled()) {
        return stream(io, machine, gpa, &.{ "nix", "store", "diff-closures", a_path, b_path });
    }
    const r = try capture(gpa, io, machine, &.{ "nix", "store", "diff-closures", a_path, b_path });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const cleaned = try output.sanitize(gpa, r.stdout);
    defer gpa.free(cleaned);
    output.raw(cleaned);
    return r.exit_code;
}

// --- Log ---

pub fn readNinaLog(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, last: u32) ![]u8 {
    const home = environ.get("HOME") orelse return error.FileNotFound;
    const path = try std.fmt.allocPrint(gpa, "{s}/.om.log", .{home});
    defer gpa.free(path);
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch return error.FileNotFound;
    if (last == 0) return content;

    // Collect non-empty lines, then keep only the final `last`. Slices point into
    // `content`, so copy them out before freeing it.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try lines.append(gpa, line);
    }
    if (lines.items.len <= last) return content;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines.items[lines.items.len - last ..]) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    gpa.free(content);
    return out.toOwnedSlice(gpa);
}

// om is a one-shot process, so "did the last apply fail this session?" can't
// live in memory — it's persisted as a ~/.om-apply-failed flag, mirroring the
// other ~/.om-* state files. This lets a later successful apply earn the
// excited kaomoji. mark sets it; take reads-and-clears so it fires exactly once.
pub fn markApplyFailed(io: std.Io, environ: *const std.process.Environ.Map) void {
    const home = environ.get("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.om-apply-failed", .{home}) catch return;
    const file = std.Io.Dir.createFile(.cwd(), io, path, .{}) catch return;
    file.close(io);
}

pub fn takeApplyFailed(io: std.Io, environ: *const std.process.Environ.Map) bool {
    const home = environ.get("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.om-apply-failed", .{home}) catch return false;
    if (std.Io.Dir.openFile(.cwd(), io, path, .{})) |f| {
        f.close(io);
        std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
        return true;
    } else |_| {
        return false;
    }
}

pub fn appendNinaLog(io: std.Io, environ: *const std.process.Environ.Map, entry: []const u8) void {
    const home = environ.get("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.om.log", .{home}) catch return;
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write }) catch
        (std.Io.Dir.createFile(.cwd(), io, path, .{}) catch return);
    defer file.close(io);
    const size = file.length(io) catch 0;
    file.writePositionalAll(io, entry, size) catch {};
}

// --- Update helpers ---

// Fetch a URL with curl and return the response body. Caller must free.
// error.NetworkError = DNS/connect failure; error.HttpError = non-2xx response.
pub fn fetchUrl(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const argv = [_][]const u8{
        "curl", "-s", "-L", "-w", "\nHTTP_STATUS:%{http_code}", "-m", "30", "--", url,
    };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch return error.NetworkError;
    defer gpa.free(result.stderr);

    const marker = "\nHTTP_STATUS:";
    const mark_idx = std.mem.lastIndexOf(u8, result.stdout, marker) orelse {
        gpa.free(result.stdout);
        return error.NetworkError;
    };
    const status_str = std.mem.trim(u8, result.stdout[mark_idx + marker.len ..], " \r\n");
    const status = std.fmt.parseInt(u16, status_str, 10) catch {
        gpa.free(result.stdout);
        return error.NetworkError;
    };
    if (status == 0) { gpa.free(result.stdout); return error.NetworkError; }
    if (status < 200 or status >= 300) { gpa.free(result.stdout); return error.HttpError; }
    const body = gpa.dupe(u8, result.stdout[0..mark_idx]) catch |e| {
        gpa.free(result.stdout);
        return e;
    };
    gpa.free(result.stdout);
    return body;
}

// Download a URL to a temp file. Returns the temp path (caller must gpa.free
// the string AND delete the file once done with it — this only reserves the
// name and writes the content). mktemp's random suffix keeps the path from
// being guessable, unlike a fixed name that a shared /tmp lets any local user
// symlink out from under a self-update.
pub fn downloadToTemp(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const tmp_raw = try captureLocal(gpa, io, &.{ "mktemp", "/tmp/om-update.XXXXXX" });
    defer gpa.free(tmp_raw);
    const tmp_path = try gpa.dupe(u8, std.mem.trim(u8, tmp_raw, " \t\r\n"));
    errdefer gpa.free(tmp_path);

    var child = std.process.spawn(io, .{
        .argv = &.{ "curl", "-fsSL", "-m", "300", "-o", tmp_path, "--", url },
        .stdin = .close,
        .stdout = .close,
        .stderr = .inherit,
    }) catch return error.NetworkError;
    const term = child.wait(io) catch return error.NetworkError;
    switch (term) {
        .exited => |c| if (c != 0) return error.NetworkError,
        else => return error.NetworkError,
    }
    return tmp_path;
}

test "downloadToTemp uses a distinct random path per call and can be cleaned up (NINA-004)" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "om download fixture payload\n";
    {
        const f = try tmp.dir.createFile(io, "source.bin", .{});
        defer f.close(io);
        try f.writePositionalAll(io, payload, 0);
    }

    // curl supports file:// URLs, so this exercises the real downloadToTemp
    // implementation (real mktemp + real curl spawn) without any network.
    var real_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path_len = try tmp.dir.realPathFile(io, "source.bin", &real_path_buf);
    const url = try std.fmt.allocPrint(a, "file://{s}", .{real_path_buf[0..real_path_len]});
    defer a.free(url);

    const path1 = try downloadToTemp(a, io, url);
    defer a.free(path1);
    defer std.Io.Dir.deleteFileAbsolute(io, path1) catch {};

    const path2 = try downloadToTemp(a, io, url);
    defer a.free(path2);
    defer std.Io.Dir.deleteFileAbsolute(io, path2) catch {};

    // mktemp's random suffix must differ per call — a fixed path is
    // symlink-clobberable and shared across concurrent self-updates.
    try std.testing.expect(!std.mem.eql(u8, path1, path2));
    try std.testing.expect(!std.mem.eql(u8, path1, "/tmp/om-update.bin"));

    try std.testing.expect(pathExists(io, path1));
    const downloaded = try std.Io.Dir.readFileAlloc(.cwd(), io, path1, a, .unlimited);
    defer a.free(downloaded);
    try std.testing.expectEqualStrings(payload, downloaded);

    // The caller owns cleanup (see the update command's post-install defer) —
    // confirm the mktemp'd file is actually removable and gone afterward.
    try std.Io.Dir.deleteFileAbsolute(io, path1);
    try std.testing.expect(!pathExists(io, path1));
}

// Get the current executable path into buf. Returns slice of buf.
pub fn selfExePath(io: std.Io, buf: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try std.process.executablePath(io, buf);
    return buf[0..len];
}

// Verify blake3 of tmp_path against expected_hex (raw hex, no prefix), then
// atomically install the binary to install_path. Errors: ChecksumMismatch,
// AccessDenied (with error_info set), or underlying I/O errors.
pub fn verifyAndInstall(gpa: std.mem.Allocator, io: std.Io, tmp_path: []const u8, expected_hex: []const u8, install_path: []const u8) !void {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, tmp_path, gpa, .unlimited) catch {
        errors.error_info.setMessage("downloaded file not found: {s}", .{tmp_path});
        return error.FileNotFound;
    };
    defer gpa.free(bytes);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    if (!std.mem.eql(u8, &hex, expected_hex)) return error.ChecksumMismatch;

    var inst_tmp_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const inst_tmp = std.fmt.bufPrint(&inst_tmp_buf, "{s}.new", .{install_path}) catch
        return error.NameTooLong;

    {
        const f = std.Io.Dir.createFileAbsolute(io, inst_tmp, .{}) catch {
            errors.error_info.setMessage("cannot write to {s}", .{install_path});
            errors.error_info.setSuggestion("try: sudo om update", .{});
            return error.AccessDenied;
        };
        defer f.close(io);
        f.writePositionalAll(io, bytes, 0) catch {
            errors.error_info.setMessage("cannot write to {s}", .{install_path});
            return error.AccessDenied;
        };
        try f.setPermissions(io, .fromMode(0o755));
    }
    errdefer std.Io.Dir.deleteFileAbsolute(io, inst_tmp) catch {};

    if (comptime builtin.os.tag == .macos) {
        _ = captureLocal(gpa, io, &.{ "codesign", "-f", "-s", "-", inst_tmp }) catch {};
    }

    std.Io.Dir.renameAbsolute(inst_tmp, install_path, io) catch |e| switch (e) {
        error.AccessDenied => {
            errors.error_info.setMessage("cannot replace {s}", .{install_path});
            errors.error_info.setSuggestion("try: sudo om update", .{});
            return error.AccessDenied;
        },
        else => return e,
    };
}

// --- Nix feature setup ---

pub const NixFeatureStatus = struct {
    nix_command: bool = false,
    flakes: bool = false,

    pub fn allEnabled(self: NixFeatureStatus) bool {
        return self.nix_command and self.flakes;
    }
};

fn scanConfFeatures(conf: []const u8, status: *NixFeatureStatus) void {
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "experimental-features")) continue;
        if (std.mem.indexOf(u8, trimmed, "nix-command") != null) status.nix_command = true;
        if (std.mem.indexOf(u8, trimmed, "flakes") != null) status.flakes = true;
    }
}

pub fn checkNixFeatures(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) NixFeatureStatus {
    var status = NixFeatureStatus{};

    if (std.Io.Dir.readFileAlloc(.cwd(), io, "/etc/nix/nix.conf", gpa, .unlimited) catch null) |conf| {
        defer gpa.free(conf);
        scanConfFeatures(conf, &status);
    }

    if (environ.get("HOME")) |home| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.config/nix/nix.conf", .{home}) catch return status;
        if (std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch null) |conf| {
            defer gpa.free(conf);
            scanConfFeatures(conf, &status);
        }
    }

    return status;
}

pub fn isNixOS(io: std.Io) bool {
    const file = std.Io.Dir.openFile(.cwd(), io, "/etc/NIXOS", .{}) catch return false;
    file.close(io);
    return true;
}

// Appends `experimental-features = nix-command flakes` to ~/.config/nix/nix.conf.
// Returns the path written (caller must free).
pub fn enableNixFeatures(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = environ.get("HOME") orelse {
        errors.error_info.setMessage("HOME not set", .{});
        return error.ConfigNotFound;
    };

    const dir_path = try std.fmt.allocPrint(gpa, "{s}/.config/nix", .{home});
    defer gpa.free(dir_path);
    const file_path = try std.fmt.allocPrint(gpa, "{s}/.config/nix/nix.conf", .{home});
    errdefer gpa.free(file_path);

    _ = captureLocal(gpa, io, &.{ "mkdir", "-p", dir_path }) catch {};

    const line = "experimental-features = nix-command flakes\n";
    const file = std.Io.Dir.openFile(.cwd(), io, file_path, .{ .mode = .read_write }) catch
        (std.Io.Dir.createFile(.cwd(), io, file_path, .{}) catch {
        errors.error_info.setMessage("could not write {s}", .{file_path});
        return error.FileNotFound;
    });
    defer file.close(io);

    const size = file.length(io) catch 0;
    file.writePositionalAll(io, line, size) catch {
        errors.error_info.setMessage("could not write {s}", .{file_path});
        return error.FileNotFound;
    };

    return file_path;
}

// --- NixOS: declarative experimental-features ---
//
// On NixOS the permanent, declarative home for these flags is configuration.nix,
// not ~/.config/nix/nix.conf. om offers to add this one line and then leaves
// the `nixos-rebuild switch` to the user.

pub const NIXOS_FEATURES_LINE =
    "nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];";

// Best-effort, non-sudo check (configuration.nix is 0644 by default). Returns
// false on any read error so the caller still offers to add the line.
pub fn nixosConfigEnablesFeatures(gpa: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const conf = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch return false;
    defer gpa.free(conf);
    return std.mem.indexOf(u8, conf, "experimental-features") != null and
        std.mem.indexOf(u8, conf, "nix-command") != null and
        std.mem.indexOf(u8, conf, "flakes") != null;
}

fn readMaybeSudo(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .unlimited) catch null) |data| return data;
    return captureLocal(gpa, io, &.{ "sudo", "cat", path });
}

// Insert NIXOS_FEATURES_LINE just before the final `}` of configuration.nix
// (i.e. inside the top-level attribute set) and write it back via a single
// `sudo cp`, which prompts for the password on the terminal. Returns an error
// for the caller to fall back to printed manual instructions.
pub fn appendFeaturesToNixosConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    const conf = readMaybeSudo(gpa, io, path) catch {
        errors.error_info.setMessage("could not read {s}", .{path});
        return error.ConfigNotFound;
    };
    defer gpa.free(conf);

    if (std.mem.indexOf(u8, conf, "experimental-features") != null) return; // already declared

    const brace = std.mem.lastIndexOfScalar(u8, conf, '}') orelse {
        errors.error_info.setMessage("no closing brace in {s} — add the line by hand", .{path});
        return error.MalformedConfig;
    };

    const home = environ.get("HOME") orelse {
        errors.error_info.setMessage("HOME not set", .{});
        return error.ConfigNotFound;
    };
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/.om-configuration.nix", .{home});
    defer gpa.free(tmp_path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, conf[0..brace]);
    if (brace == 0 or conf[brace - 1] != '\n') try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, "  # added by om setup — flakes + the new nix CLI\n");
    try buf.appendSlice(gpa, "  ");
    try buf.appendSlice(gpa, NIXOS_FEATURES_LINE);
    try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, conf[brace..]);

    const tmp = std.Io.Dir.createFile(.cwd(), io, tmp_path, .{}) catch {
        errors.error_info.setMessage("could not write {s}", .{tmp_path});
        return error.FileNotFound;
    };
    tmp.writePositionalAll(io, buf.items, 0) catch {
        tmp.close(io);
        std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
        errors.error_info.setMessage("could not write {s}", .{tmp_path});
        return error.FileNotFound;
    };
    tmp.close(io);

    // Back up the existing config, then replace it — in one sudo call so the
    // password is asked for at most once. Paths travel as positional args ($0,
    // $1) to sidestep shell quoting.
    const code = streamLocal(io, &.{
        "sudo", "sh", "-c", "cp -- \"$0\" \"$0.om-bak\" && cp -- \"$1\" \"$0\"", path, tmp_path,
    }) catch {
        std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
        errors.error_info.setMessage("could not write {s}", .{path});
        return error.ProcessFailed;
    };
    std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};
    if (code != 0) {
        errors.error_info.setMessage("sudo cp into {s} failed", .{path});
        return error.ProcessFailed;
    }
}
