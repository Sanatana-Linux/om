// main.zig — entry point, arg parsing, dispatch, error handler
// THE ONLY FILE that creates the Io.Writer and passes it to output.init().
const std = @import("std");
const Io = std.Io;

const types = @import("types.zig");
const errors = @import("errors.zig");
const config = @import("config.zig");
const commands = @import("commands.zig");
const output = @import("output.zig");
const man = @import("man.zig");

const Args = struct {
    command: []const u8 = "",
    sub: []const u8 = "",
    rest: []const []const u8 = &.{},
    passthrough: []const []const u8 = &.{}, // unrecognized flags (e.g. --refresh), forwarded to the wrapped nix command
    machine: ?[]const u8 = null,
    version: bool = false,
    dry: bool = false,
    check: bool = false,
    no_apply: bool = false,
    all: bool = false,
    json: bool = false,
    last: u32 = 50,
    user: bool = false,
    yes: bool = false, // bypass output.confirm() for scripted/automated invocations
};

pub fn main(startup: std.process.Init) !void {
    const arena = startup.arena.allocator();
    const gpa = startup.gpa;
    const io = startup.io;

    // Command allocations go through an arena freed when main returns. om is a
    // one-shot CLI that exits after one command, and std.process.exit skips
    // defers, so per-allocation frees were easy to miss — the arena guarantees
    // everything is released in one shot, eliminating exit-time leak reports.
    var cmd_arena = std.heap.ArenaAllocator.init(gpa);
    defer cmd_arena.deinit();
    const ca = cmd_arena.allocator();

    // Initialize output module with buffered stdout writer. Streaming (not the
    // default positional) mode: stdout may be a terminal, pipe, or a redirected
    // regular file. Positional mode pwrites from offset 0 and ignores the fd's
    // inherited offset, which corrupts `{ echo h; om x; } > f` and `>>` append
    // by overwriting from the start. Streaming honors the current file offset.
    var stdout_buf: [16384]u8 = undefined;
    var stdout_fw: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    output.init(&stdout_fw.interface, io, startup.environ_map, true);
    defer output.flush();

    const argv = try startup.minimal.args.toSlice(arena);
    const args = try parseArgs(arena, argv);

    // --yes bypasses output.confirm()'s prompts for legitimate automation (CI,
    // hooks, cron). Without it, confirm() now refuses on a closed/non-interactive
    // stdin instead of silently assuming yes (NINA-005).
    if (args.yes) output.setAutoYes(true);

    if (args.version) {
        output.version();
        return;
    }

    // Help and hello work without config
    if (args.command.len == 0 or std.mem.eql(u8, args.command, "help")) {
        output.help();
        return;
    }

    // man works without a config — it's pure docs, no machine context needed.
    if (std.mem.eql(u8, args.command, "man")) {
        const topic: []const u8 = if (args.rest.len > 0) args.rest[0] else "";
        man.run(io, topic) catch {};
        return;
    }

    // setup and update run before config so they work without ~/.om.conf
    if (std.mem.eql(u8, args.command, "setup") or std.mem.eql(u8, args.command, "update")) {
        const dummy_machine: types.Machine = .{ .name = "local", .local = true };
        const dummy_cfg: types.NinaConfig = .{};
        const pre_ctx = commands.Ctx{
            .gpa = ca,
            .io = io,
            .environ = startup.environ_map,
            .machine = dummy_machine,
            .cfg = dummy_cfg,
            .args = args.rest,
            .passthrough = args.passthrough,
            .sub = args.sub,
            .dry = args.dry,
            .check = args.check,
            .no_apply = args.no_apply,
            .all = args.all,
            .last = args.last,
            .json = args.json,
            .user = args.user,
        };
        if (std.mem.eql(u8, args.command, "setup")) {
            commands.setup(ca, io, startup.environ_map) catch |err| {
                const msg = errors.error_info.getMessage() orelse errors.staticMessage(err);
                const detail = errors.error_info.getDetail();
                const suggestion = errors.error_info.getSuggestion();
                output.printError(msg, detail, suggestion);
                output.flush();
                std.process.exit(1);
            };
        } else {
            dispatch(pre_ctx, args.command) catch |err| {
                reportError(err, ca);
                output.flush();
                std.process.exit(1);
            };
        }
        return;
    }

    // Load config and resolve machine. On first run with no config file, offer
    // the setup wizard when stdout is a TTY; skip silently in piped/scripted mode.
    const cfg = cfg_blk: {
        if (config.load(arena, io, startup.environ_map)) |c| {
            break :cfg_blk c;
        } else |err| {
            if (err == error.ConfigNotFound and (std.Io.File.stdout().isTty(io) catch false)) {
                commands.firstRunWizard(ca, io, startup.environ_map) catch |wizard_err| {
                    const msg = errors.error_info.getMessage() orelse errors.staticMessage(wizard_err);
                    const detail = errors.error_info.getDetail();
                    const suggestion = errors.error_info.getSuggestion();
                    output.printError(msg, detail, suggestion);
                    output.flush();
                    std.process.exit(1);
                };
                errors.error_info.reset();
                break :cfg_blk config.load(arena, io, startup.environ_map) catch |err2| {
                    const msg = errors.error_info.getMessage() orelse errors.staticMessage(err2);
                    const detail = errors.error_info.getDetail();
                    const suggestion = errors.error_info.getSuggestion();
                    output.printError(msg, detail, suggestion);
                    output.flush();
                    std.process.exit(1);
                };
            }
            const msg = errors.error_info.getMessage() orelse errors.staticMessage(err);
            const detail = errors.error_info.getDetail();
            const suggestion = errors.error_info.getSuggestion();
            output.printError(msg, detail, suggestion);
            output.flush();
            std.process.exit(1);
        }
    };

    output.setTeach(cfg.teach);

    const machine = config.resolveMachine(&cfg, args.machine) catch |err| {
        const msg = errors.error_info.getMessage() orelse errors.staticMessage(err);
        const detail = errors.error_info.getDetail();
        const suggestion = errors.error_info.getSuggestion();
        output.printError(msg, detail, suggestion);
        output.flush();
        std.process.exit(1);
    };

    const ctx = commands.Ctx{
        .gpa = ca,
        .io = io,
        .environ = startup.environ_map,
        .machine = machine,
        .cfg = cfg,
        .args = args.rest,
        .passthrough = args.passthrough,
        .sub = args.sub,
        .dry = args.dry,
        .check = args.check,
        .no_apply = args.no_apply,
        .all = args.all,
        .last = args.last,
        .json = args.json,
        .user = args.user,
    };

    dispatch(ctx, args.command) catch |err| {
        reportError(err, ca);
        output.flush();
        std.process.exit(1);
    };
}

// Network/ssh/search failures are the machine's fault, not the user's — surface
// them with the sad kaomoji. BuildFailed is routed through the 3-layer
// translation pipeline. Everything else uses a plain error line.
fn reportError(err: anyerror, allocator: std.mem.Allocator) void {
    switch (err) {
        // abort message already printed by output.aborted() — just exit non-zero
        error.HookAborted => {},
        // "config invalid" already printed by output.checkFailed() — just exit non-zero
        error.CheckFailed => {},
        error.BuildFailed => {
            const stderr = errors.getBuildStderr();
            const translated = errors.translateError(allocator, stderr);
            output.buildError(translated);
        },
        error.NetworkError, error.SshFailed, error.SearchFailed => {
            const msg = errors.error_info.getMessage() orelse errors.staticMessage(err);
            const detail = errors.error_info.getDetail();
            const suggestion = errors.error_info.getSuggestion();
            output.printSystemError(msg, detail, suggestion);
        },
        else => {
            const msg = errors.error_info.getMessage() orelse errors.staticMessage(err);
            const detail = errors.error_info.getDetail();
            const suggestion = errors.error_info.getSuggestion();
            output.printError(msg, detail, suggestion);
        },
    }
}

fn dispatch(ctx: commands.Ctx, cmd: []const u8) !void {
    if (std.mem.eql(u8, cmd, "gen")) return commands.genCmd(ctx);
    if (std.mem.eql(u8, cmd, "sync")) return commands.syncCmd(ctx);
    if (std.mem.eql(u8, cmd, "service")) return commands.service(ctx);
    if (std.mem.eql(u8, cmd, "check")) return commands.checkCmd(ctx);
    if (std.mem.eql(u8, cmd, "flake")) return commands.flake(ctx);
    if (std.mem.eql(u8, cmd, "store")) return commands.store(ctx);
    if (std.mem.eql(u8, cmd, "profile")) return commands.profile(ctx);
    if (std.mem.eql(u8, cmd, "pkg")) return commands.pkg(ctx);
    if (std.mem.eql(u8, cmd, "home")) return commands.home(ctx);
    if (std.mem.eql(u8, cmd, "boot")) return commands.boot(ctx);
    if (std.mem.eql(u8, cmd, "install")) return commands.install(ctx);
    if (std.mem.eql(u8, cmd, "help")) {
        output.help();
        return;
    }

    errors.error_info.setMessage("unknown command: {s}", .{cmd});
    errors.error_info.setSuggestion("om help", .{});
    return error.Internal;
}

fn parseArgs(arena: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    var result = Args{};
    var rest: std.ArrayList([]const u8) = .empty;
    var passthrough: std.ArrayList([]const u8) = .empty;
    var i: usize = 1; // skip program name

    // First positional = command
    if (i < argv.len and argv[i][0] != '-') {
        result.command = argv[i];
        i += 1;
    }

    // Second positional (if not a flag) = subcommand for multi-word commands
    if (i < argv.len and argv[i][0] != '-') {
        const multi_word = isMultiWord(result.command);
        if (multi_word) {
            result.sub = argv[i];
            i += 1;
        }
    }

    // Once a literal `--` separator is seen, everything after it (and the
    // separator itself) is opaque data for the wrapped program — e.g. `om run
    // hello -- --version` must forward `--version` to hello, not have om steal
    // it as its own --version flag. Stop matching om's own flags at that point.
    var past_separator = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (past_separator) {
            try passthrough.append(arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            past_separator = true;
            try passthrough.append(arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--on") or std.mem.eql(u8, a, "-on")) {
            i += 1;
            if (i < argv.len) result.machine = argv[i];
        } else if (std.mem.eql(u8, a, "--dry")) {
            result.dry = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            result.check = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            result.version = true;
        } else if (std.mem.eql(u8, a, "--no-apply")) {
            result.no_apply = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, a, "--user")) {
            result.user = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, a, "--yes")) {
            result.yes = true;
        } else if (std.mem.eql(u8, a, "--last")) {
            i += 1;
            if (i < argv.len) result.last = std.fmt.parseInt(u32, argv[i], 10) catch 50;
        } else if (std.mem.eql(u8, a, "-f")) {
            // -f flag for service logs follow
            try rest.append(arena, "-f");
        } else if (std.mem.eql(u8, a, "--switch")) {
            // --switch flag for `home init` (activate after init)
            try rest.append(arena, "--switch");
        } else if (std.mem.eql(u8, a, "--dir")) {
            // --dir flag for `om edit` (open the config directory)
            try rest.append(arena, "--dir");
        } else if (a.len > 0 and a[0] != '-') {
            try rest.append(arena, a);
        } else {
            // Unrecognized flag (e.g. --refresh) — forwarded verbatim to whatever
            // nix command the subcommand wraps, instead of being dropped silently.
            try passthrough.append(arena, a);
        }
    }

    result.rest = try rest.toOwnedSlice(arena);
    result.passthrough = try passthrough.toOwnedSlice(arena);
    return result;
}

fn isMultiWord(cmd: []const u8) bool {
    const multi = [_][]const u8{ "service", "flake", "store", "profile", "pkg", "gen", "develop", "home", "check" };
    for (multi) |m| {
        if (std.mem.eql(u8, cmd, m)) return true;
    }
    return false;
}

// Zig 0.16's test runner only discovers `test` blocks in files it can see are
// reachable from the root; refAllDecls forces every decl main.zig imports
// (transitively) to be referenced, which is what pulls in test blocks living
// in exec.zig, commands.zig, errors.zig, config.zig, etc.
test {
    std.testing.refAllDecls(@This());
}

test "parse args basic" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "apply", "--dry" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    try std.testing.expectEqualStrings("apply", args.command);
    try std.testing.expect(args.dry);
}

test "parse args with machine" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "status", "--on", "build-server" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    try std.testing.expectEqualStrings("status", args.command);
    try std.testing.expectEqualStrings("build-server", args.machine.?);
}

test "parse args forwards unrecognized flags" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "flake", "update", "--refresh" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("flake", args.command);
    try std.testing.expectEqualStrings("update", args.sub);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--refresh", args.passthrough[0]);
}

test "parse args forwards apply --show-trace" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "apply", "--show-trace" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("apply", args.command);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--show-trace", args.passthrough[0]);
}

test "parse args forwards check --show-trace" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "check", "--show-trace" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("check", args.command);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--show-trace", args.passthrough[0]);
}

test "parse args forwards flake check --all-systems" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "flake", "check", "--all-systems" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("flake", args.command);
    try std.testing.expectEqualStrings("check", args.sub);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--all-systems", args.passthrough[0]);
}

test "parse args forwards build --print-build-logs" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "build", "--print-build-logs" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("build", args.command);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--print-build-logs", args.passthrough[0]);
}

test "parse args forwards develop --show-trace" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "develop", "--show-trace" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("develop", args.command);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--show-trace", args.passthrough[0]);
}

test "parse args forwards run's -- separator and program args" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "run", "hello", "--", "--version" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("run", args.command);
    try std.testing.expectEqual(@as(usize, 1), args.rest.len);
    try std.testing.expectEqualStrings("hello", args.rest[0]);
    try std.testing.expectEqual(@as(usize, 2), args.passthrough.len);
    try std.testing.expectEqualStrings("--", args.passthrough[0]);
    try std.testing.expectEqualStrings("--version", args.passthrough[1]);
}

test "parse args forwards home apply --show-trace" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "home", "apply", "--show-trace" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("home", args.command);
    try std.testing.expectEqualStrings("apply", args.sub);
    try std.testing.expectEqual(@as(usize, 1), args.passthrough.len);
    try std.testing.expectEqualStrings("--show-trace", args.passthrough[0]);
}

test "parse subcommand" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "service", "list" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    try std.testing.expectEqualStrings("service", args.command);
    try std.testing.expectEqualStrings("list", args.sub);
}

test "parse args recognizes --yes" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "clean", "--yes" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    defer gpa.free(args.passthrough);
    try std.testing.expectEqualStrings("clean", args.command);
    try std.testing.expect(args.yes);
    try std.testing.expectEqual(@as(usize, 0), args.passthrough.len);
}

test "parse version flag" {
    const gpa = std.testing.allocator;
    const argv = [_][:0]const u8{ "om", "--version" };
    const args = try parseArgs(gpa, &argv);
    defer gpa.free(args.rest);
    try std.testing.expect(args.version);
}
