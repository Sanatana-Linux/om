// commands.zig — all command handlers
// Orchestrates exec/api/output. Zero direct stdout writes.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const errors = @import("errors.zig");
const config = @import("config.zig");
const output = @import("output.zig");
const exec = @import("exec.zig");
const api = @import("api.zig");
const search_tui = @import("search.zig");
const version = @import("version.zig");

const UPDATE_URL = "https://kepr.uk/api/nina/releases/latest";
const FLAKE_URL = "https://kepr.uk/nina/archive/HEAD.tar.gz#nina";

const Semver = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    machine: types.Machine,
    cfg: types.NinaConfig,
    args: []const []const u8, // positional args after subcommand
    passthrough: []const []const u8, // unrecognized flags, forwarded verbatim to the wrapped nix command
    sub: []const u8, // subcommand (e.g. "list" in "service list")
    dry: bool,
    check: bool,
    no_apply: bool,
    all: bool,
    last: u32,
    json: bool,
    user: bool, // --user: operate on user (vs system) services
};

// A system is flake-managed when the config says so OR a flake.nix is present in
// the config dir. Detection means a fresh channel user who points om at a flake
// dir gets the right behavior without editing config first.
fn flakeSystem(ctx: Ctx) bool {
    return ctx.cfg.flake or exec.configHasFlake(ctx.gpa, ctx.io, &ctx.machine);
}

fn runPreHook(ctx: Ctx, hook_name: []const u8) !bool {
    const hook = try exec.runHook(ctx.gpa, ctx.io, ctx.environ, hook_name);
    defer ctx.gpa.free(hook.output);
    switch (hook.result) {
        .not_found, .ok => return true,
        .failed => {
            output.hookFailed(ctx.gpa, hook_name, hook.exit_code, hook.output);
            return output.confirmDefaultNo("continue anyway?");
        },
    }
}

fn runPostHook(ctx: Ctx, hook_name: []const u8) void {
    const hook = exec.runHook(ctx.gpa, ctx.io, ctx.environ, hook_name) catch return;
    defer ctx.gpa.free(hook.output);
    if (hook.result == .failed) {
        output.hookWarning(hook_name, hook.exit_code, hook.output);
    }
}

const check_help = [_][2][]const u8{
    .{ "doctor", "diagnose common issues" },
    .{ "fmt", "format nix files" },
    .{ "info", "system information" },
    .{ "local", "validate config without switching" },
    .{ "log", "operation history" },
    .{ "mood", "plain-language health summary" },
    .{ "status", "machine health at a glance" },
};

pub fn checkCmd(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("check", &check_help, null);
    if (std.mem.eql(u8, ctx.sub, "local")) return checkLocal(ctx);
    if (std.mem.eql(u8, ctx.sub, "doctor")) return doctor(ctx);
    if (std.mem.eql(u8, ctx.sub, "mood")) return mood(ctx);
    if (std.mem.eql(u8, ctx.sub, "fmt")) return fmt(ctx);
    if (std.mem.eql(u8, ctx.sub, "info")) return info(ctx);
    if (std.mem.eql(u8, ctx.sub, "log")) return log(ctx);
    if (std.mem.eql(u8, ctx.sub, "status")) return statusCmd(ctx);
    return output.subcommandHelp("check", &check_help, null);
}

pub fn apply(ctx: Ctx) !void {
    // Optional first positional arg is the NixOS configuration name to rebuild
    // (e.g. `om flake apply bagalamukhi`). Defaults to the machine name, so
    // `om flake apply` on host "bagalamukhi" rebuilds /etc/nixos#bagalamukhi.
    const flake_attr: ?[]const u8 = if (ctx.args.len > 0) ctx.args[0] else ctx.machine.name;
    if (ctx.dry) {
        output.applyDry(ctx.machine.name);
        const code = try exec.nixosRebuildDryActivate(ctx.io, &ctx.machine, ctx.gpa, flake_attr, ctx.passthrough);
        if (code != 0) return error.BuildFailed;
        output.applyDryDone();
        return;
    }
    if (ctx.check) {
        return checkLocal(ctx);
    }

    if (!try runPreHook(ctx, "pre-apply")) {
        output.aborted();
        return error.HookAborted;
    }

    output.applyStart(ctx.machine.name);
    output.buildPanelInit();
    const start = std.Io.Clock.awake.now(ctx.io);

    var panel = output.BuildPanel{};
    const code = exec.nixosRebuildSwitchWithPanel(ctx.io, &ctx.machine, ctx.gpa, &panel, flake_attr, ctx.passthrough) catch |e| {
        output.buildPanelClear();
        exec.markApplyFailed(ctx.io, ctx.environ);
        return e;
    };
    output.buildPanelClear();

    if (code != 0) {
        exec.markApplyFailed(ctx.io, ctx.environ);
        // Surface any nix warnings before the failure line so the user sees them
        // even on a failed build — they often point at the root cause.
        const warnings = errors.extractWarnings(ctx.gpa, errors.getBuildStderr()) catch &.{};
        defer {
            for (warnings) |w| ctx.gpa.free(w);
            ctx.gpa.free(warnings);
        }
        if (warnings.len > 0) output.buildWarnings(warnings);
        return error.BuildFailed;
    }

    const elapsed_ns = @max(0, start.untilNow(ctx.io, .awake).toNanoseconds());
    const elapsed: u64 = @intCast(@divFloor(elapsed_ns, 1_000_000));
    const gen = exec.getCurrentGeneration(ctx.gpa, ctx.io, &ctx.machine) catch 0;
    const after_failure = exec.takeApplyFailed(ctx.io, ctx.environ);
    output.applyDone(gen, elapsed, after_failure);
    // Show any nix warnings collected during the build (dim yellow, after success line).
    const warnings = errors.extractWarnings(ctx.gpa, errors.getBuildStderr()) catch &.{};
    defer {
        for (warnings) |w| ctx.gpa.free(w);
        ctx.gpa.free(warnings);
    }
    if (warnings.len > 0) output.buildWarnings(warnings);
    runPostHook(ctx, "post-apply");
    logAction(ctx, "apply", gen);
}

pub fn checkLocal(ctx: Ctx) !void {
    output.checkStart(ctx.machine.name);
    const flake_attr: ?[]const u8 = if (ctx.args.len > 0) ctx.args[0] else ctx.machine.name;
    const code = try exec.nixosRebuildBuild(ctx.io, &ctx.machine, ctx.gpa, flake_attr, ctx.passthrough);
    if (code != 0) return error.BuildFailed;
    output.checkOk();
}

pub fn back(ctx: Ctx) !void {
    const gens = try exec.getGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(gens);

    var current: u32 = 0;
    for (gens) |g| if (g.current) {
        current = g.number;
    };

    // Newest generation older than current. If there is none, we're already at the
    // oldest — stop cleanly instead of letting rollback fail with 'build failed'.
    var prev: u32 = 0;
    var has_prev = false;
    for (gens) |g| {
        if (g.number < current and (!has_prev or g.number > prev)) {
            prev = g.number;
            has_prev = true;
        }
    }
    if (!has_prev) {
        output.alreadyOldest();
        return;
    }

    if (!try runPreHook(ctx, "pre-back")) {
        output.aborted();
        return error.HookAborted;
    }

    output.backStart(ctx.machine.name, current, prev);
    if (ctx.cfg.confirm and !output.confirm("")) return;

    // Flake systems don't have <nixos-config> in the Nix search path, so
    // `nixos-rebuild --rollback` fails. Switch by generation number instead
    // (same path as `om go N`), which works for both channel and flake.
    const code = if (flakeSystem(ctx))
        try exec.switchGeneration(ctx.io, &ctx.machine, ctx.gpa, prev)
    else
        try exec.rollback(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.BuildFailed;
    output.backDone(prev);
    runPostHook(ctx, "post-back");
}

pub fn go(ctx: Ctx) !void {
    if (ctx.args.len == 0) return error.Internal;
    const target = std.fmt.parseInt(u32, ctx.args[0], 10) catch return error.Internal;
    const current = try exec.getCurrentGeneration(ctx.gpa, ctx.io, &ctx.machine);

    output.goStart(ctx.machine.name, current, target);
    if (ctx.cfg.confirm and !output.confirm("")) return;

    const code = try exec.switchGeneration(ctx.io, &ctx.machine, ctx.gpa, target);
    if (code != 0) return error.ProcessFailed;
    output.generationDone(target);
}

pub fn history(ctx: Ctx) !void {
    const gens = try exec.getGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(gens);
    output.historyHeader(ctx.machine.name);
    for (gens) |g| output.historyRow(g);
}

const gen_help = [_][2][]const u8{
    .{ "back", "roll back to the previous generation" },
    .{ "current", "show current generation" },
    .{ "delete <n>", "delete generation n" },
    .{ "delete old", "delete old generations" },
    .{ "diff", "compare generations" },
    .{ "go <n>", "switch to generation n" },
    .{ "history", "list all generations" },
    .{ "list", "list generations" },
};

pub fn genCmd(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("gen", &gen_help, null);
    if (std.mem.eql(u8, ctx.sub, "back")) return back(ctx);
    if (std.mem.eql(u8, ctx.sub, "current")) {
        const n = try exec.getCurrentGeneration(ctx.gpa, ctx.io, &ctx.machine);
        output.genCurrent(n);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "delete")) {
        if (ctx.args.len == 0) return error.Internal;
        if (std.mem.eql(u8, ctx.args[0], "old")) {
            if (ctx.cfg.confirm and !output.confirm("")) return;
            _ = try exec.deleteOldGenerations(ctx.io, &ctx.machine, ctx.gpa);
        } else {
            const n = std.fmt.parseInt(u32, ctx.args[0], 10) catch return error.Internal;
            if (ctx.cfg.confirm and !output.confirm("")) return;
            _ = try exec.deleteGeneration(ctx.io, &ctx.machine, ctx.gpa, n);
        }
        output.done();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "diff")) return diff(ctx);
    if (std.mem.eql(u8, ctx.sub, "go")) return go(ctx);
    if (std.mem.eql(u8, ctx.sub, "history")) return history(ctx);
    if (std.mem.eql(u8, ctx.sub, "list")) return history(ctx);
    return output.subcommandHelp("gen", &gen_help, null);
}

pub fn clean(ctx: Ctx) !void {
    const gens = try exec.getGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(gens);
    const all = ctx.all or std.mem.eql(u8, ctx.sub, "all");
    const total: u32 = @intCast(gens.len);
    const keep: u32 = if (all) 1 else ctx.cfg.generations;
    if (total <= keep) {
        output.cleanNothing(ctx.machine.name, total);
        return;
    }
    output.cleanStart(ctx.machine.name, keep, total);
    if (ctx.cfg.confirm and !output.confirm("removing — cannot be undone")) return;
    const code = try exec.comprehensiveClean(ctx.io, &ctx.machine, ctx.gpa, all, ctx.cfg.generations);
    if (code != 0) return error.ProcessFailed;
    const freed = exec.getFreedBytes();
    output.cleanDoneFreed(freed);
}

pub fn syncCmd(ctx: Ctx) !void {
    output.syncStart(ctx.machine.name);
    const code = try exec.syncSubmodules(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.ProcessFailed;
    output.syncDone();
}

pub fn statusCmd(ctx: Ctx) !void {
    output.statusHeader();
    // --all renders every configured machine; remotes route through the same SSH
    // path as exec.capture. An unreachable machine is shown in red, not fatal.
    if (ctx.all and ctx.cfg.machines.len > 0) {
        for (ctx.cfg.machines) |m| statusRowFor(ctx, &m);
    } else {
        statusRowFor(ctx, &ctx.machine);
    }
    homeStatusLine(ctx);
}

pub fn weightCmd(ctx: Ctx) !void {
    const target = if (ctx.args.len > 0) ctx.args[0] else ctx.machine.name;
    output.weightStart(target);
    const size = try exec.systemWeight(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(size);
    output.weightResult(target, std.mem.trim(u8, size, " \t\n\r"));
}

// When standalone Home Manager is present, show its current generation as a dim
// line indented under the machine rows. Gated on standalone mode (the only mode
// where we can read a generation), so a machine without HM is unaffected.
fn homeStatusLine(ctx: Ctx) void {
    if (exec.detectHomeManager(ctx.gpa, ctx.io, ctx.environ) != .standalone) return;
    const out = exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine) catch return;
    defer ctx.gpa.free(out);
    const gens = parseHomeGenerations(ctx.gpa, out) catch return;
    defer freeHomeGens(ctx.gpa, gens);
    if (gens.len == 0) return;
    output.statusHomeRow(gens[0].number, gens[0].date);
}

fn statusRowFor(ctx: Ctx, machine: *const types.Machine) void {
    // A failure to read the current generation means we couldn't reach or query
    // the machine — mark it unreachable rather than reporting a bogus gen 0.
    const gen = exec.getCurrentGeneration(ctx.gpa, ctx.io, machine) catch {
        output.statusRow(machine.name, 0, "", "", false);
        return;
    };
    const st = exec.systemStatus(ctx.gpa, ctx.io, machine);
    defer ctx.gpa.free(st.size);
    defer ctx.gpa.free(st.age);
    output.statusRow(machine.name, gen, st.age, st.size, true);
}

// Pure decision for `om diff`'s generation targets, split out so it can be
// unit tested without shelling out. Returns null when there's nothing safe to
// diff — no generation is marked current (a non-standard profile layout, a
// transient readlink failure, or a non-GNU remote host can all produce this)
// or fewer than two generations exist and no explicit pair was given. Nina
// ships ReleaseSafe, so leaving `current - 1` reachable with current == 0
// would be a u32 underflow panic, not silent wraparound.
fn diffTargets(gens: []const types.GenerationInfo, args: []const []const u8) ?struct { a: u32, b: u32 } {
    var current: u32 = 0;
    var prev: u32 = 0;
    for (gens) |g| {
        if (g.current) current = g.number;
        if (!g.current and g.number > prev and g.number < current) prev = g.number;
    }
    if (args.len >= 2) {
        const a = std.fmt.parseInt(u32, args[0], 10) catch blk: {
            if (current == 0) return null;
            break :blk current - 1;
        };
        const b = std.fmt.parseInt(u32, args[1], 10) catch blk: {
            if (current == 0) return null;
            break :blk current;
        };
        return .{ .a = a, .b = b };
    }
    if (current == 0 or gens.len < 2) return null;
    return .{ .a = if (prev > 0) prev else current - 1, .b = current };
}

pub fn diff(ctx: Ctx) !void {
    const gens = try exec.getGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(gens);
    const targets = diffTargets(gens, ctx.args) orelse {
        output.diffCannotDetermine();
        return;
    };
    output.diffHeader(targets.a, targets.b, ctx.machine.name);
    if (try exec.diffClosures(ctx.io, &ctx.machine, ctx.gpa, targets.a, targets.b) != 0) return error.ProcessFailed;
}

test "diffTargets returns null when no generation is marked current" {
    const gens = [_]types.GenerationInfo{
        .{ .number = 1, .date = "", .time = "", .current = false },
        .{ .number = 2, .date = "", .time = "", .current = false },
    };
    try std.testing.expect(diffTargets(&gens, &.{}) == null);
}

test "diffTargets returns null with fewer than two generations and no explicit args" {
    const gens = [_]types.GenerationInfo{
        .{ .number = 1, .date = "", .time = "", .current = true },
    };
    try std.testing.expect(diffTargets(&gens, &.{}) == null);
}

test "diffTargets falls back to prev/current when both are known" {
    const gens = [_]types.GenerationInfo{
        .{ .number = 1, .date = "", .time = "", .current = false },
        .{ .number = 2, .date = "", .time = "", .current = true },
    };
    const targets = diffTargets(&gens, &.{}).?;
    try std.testing.expectEqual(@as(u32, 1), targets.a);
    try std.testing.expectEqual(@as(u32, 2), targets.b);
}

test "diffTargets returns null when explicit args fail to parse and no current generation exists" {
    const gens = [_]types.GenerationInfo{
        .{ .number = 1, .date = "", .time = "", .current = false },
    };
    try std.testing.expect(diffTargets(&gens, &.{ "not-a-number", "2" }) == null);
}

test "diffTargets uses explicit args verbatim when both parse" {
    const gens = [_]types.GenerationInfo{
        .{ .number = 1, .date = "", .time = "", .current = false },
    };
    const targets = diffTargets(&gens, &.{ "3", "5" }).?;
    try std.testing.expectEqual(@as(u32, 3), targets.a);
    try std.testing.expectEqual(@as(u32, 5), targets.b);
}

pub fn mood(ctx: Ctx) !void {
    const gen = exec.getCurrentGeneration(ctx.gpa, ctx.io, &ctx.machine) catch 0;
    const st = exec.systemStatus(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(st.size);
    defer ctx.gpa.free(st.age);
    const state = exec.systemRunningState(ctx.gpa, ctx.io, &ctx.machine) catch try ctx.gpa.dupe(u8, "unknown");
    defer ctx.gpa.free(state);
    output.mood(ctx.machine.name, state, gen, st.age, st.size);
}

pub fn doctor(ctx: Ctx) !void {
    output.doctorHeader(ctx.machine.name);
    const checks = try exec.runDoctorChecks(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(checks);
    var warnings: u32 = 0;
    var failures: u32 = 0;
    for (checks) |ch| {
        output.doctorRow(ch);
        if (ch.status == .warn) warnings += 1;
        if (ch.status == .fail) failures += 1;
    }

    // Home Manager row only when present — absent on a machine without HM, so
    // doctor's table is unchanged there.
    const hm_mode = exec.detectHomeManager(ctx.gpa, ctx.io, ctx.environ);
    if (hm_mode != .none) {
        const note = homeDoctorNote(ctx, hm_mode);
        defer ctx.gpa.free(note);
        output.doctorRow(.{ .name = "home manager", .status = .ok, .note = note });
    }

    output.doctorSummary(warnings, failures);
}

// "standalone  gen 765" / "module" — the note shown in doctor's home manager row.
// Caller owns the returned slice.
fn homeDoctorNote(ctx: Ctx, mode: exec.HomeManagerMode) []const u8 {
    const label = switch (mode) {
        .standalone => "standalone",
        .module => "module",
        .none => "",
    };
    if (mode == .standalone) {
        const gen = homeCurrentGen(ctx);
        if (gen != 0)
            return std.fmt.allocPrint(ctx.gpa, "{s}  gen {d}", .{ label, gen }) catch
                (ctx.gpa.dupe(u8, label) catch "");
    }
    return ctx.gpa.dupe(u8, label) catch "";
}

// om update — kepr self-update for the om binary itself.
pub fn update(ctx: Ctx) !void {
    output.updateSelfStart();

    if (comptime std.mem.eql(u8, version.PLATFORM, "unsupported")) {
        output.updateSelfNoPlatform(@tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag));
        return error.Internal;
    }

    const env_url = ctx.environ.get("NINA_UPDATE_SOURCE");
    const source_url = env_url orelse UPDATE_URL;

    const body = exec.fetchUrl(ctx.gpa, ctx.io, source_url) catch |e| switch (e) {
        error.NetworkError, error.HttpError => {
            output.updateSelfNetworkError();
            return;
        },
        else => return e,
    };
    defer ctx.gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
        output.printWarning("could not parse release metadata");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        output.printWarning("malformed release metadata");
        return;
    }

    const remote_ver = blk: {
        const v = root.object.get("version") orelse {
            output.printWarning("malformed release metadata");
            return;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                output.printWarning("malformed release metadata");
                return;
            },
        };
    };
    if (!remoteVersionNewer(version.VERSION, remote_ver)) {
        output.updateSelfCurrent(version.VERSION);
        return;
    }

    const release_notes = try updateReleaseNotes(ctx.gpa, ctx.io, root, source_url, version.VERSION, remote_ver);
    defer ctx.gpa.free(release_notes);

    output.updateSelfAvailable(version.VERSION, remote_ver);
    output.updateSelfReleaseNotes(release_notes);
    if (ctx.check) return;

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const install_path = exec.selfExePath(ctx.io, &exe_buf) catch {
        errors.error_info.setMessage("could not determine install path", .{});
        return error.Internal;
    };

    // When running from the nix store, defer to nix profile upgrade so nix
    // manages the transition (the store is read-only; binary replacement fails).
    // A NixOS system install also resolves into the store but isn't a profile
    // element, so check the profile to avoid a no-op `upgrade` — it updates with
    // the next nixos-rebuild instead.
    if (std.mem.startsWith(u8, install_path, "/nix/store/")) {
        const nina_element = exec.profileNinaElement(ctx.gpa, ctx.io, &ctx.machine);
        defer if (nina_element) |n| ctx.gpa.free(n);
        if (nina_element == null) {
            output.updateSelfSystemManaged();
            return;
        }
        const element = nina_element.?;
        output.updateSelfNixManaged(remote_ver);
        if (ctx.cfg.confirm and !output.confirm("")) return;
        // Build the new version into the store BEFORE touching the profile. A
        // network drop or eval failure here leaves the old element untouched —
        // this is the only step that can fail for reasons outside our control,
        // so it must happen first. Once this succeeds, the subsequent
        // remove+add operates on an already-warm local store and is not
        // expected to fail for the same reasons, closing the window a raw
        // remove-then-add would leave open between the two profile edits.
        const prefetch_r = exec.capture(ctx.gpa, ctx.io, &ctx.machine, &.{ "nix", "build", "--no-link", "--refresh", FLAKE_URL }) catch {
            output.updateSelfNixPrefetchFailed();
            return;
        };
        defer ctx.gpa.free(prefetch_r.stdout);
        defer ctx.gpa.free(prefetch_r.stderr);
        if (prefetch_r.exit_code != 0) {
            output.raw(prefetch_r.stdout);
            output.raw(prefetch_r.stderr);
            output.updateSelfNixPrefetchFailed();
            return;
        }
        // `nix profile upgrade` re-resolves the element's own originalUrl. The
        // archive install runs with --no-write-lock-file, so nix has nowhere to
        // persist the lock it takes at install time except baking it into that
        // originalUrl as a `?narHash=` pin — which then never changes no matter
        // how far kepr's HEAD moves. Upgrading against that pin is a permanent
        // no-op: exit 0, "upgrading from X to X", nothing installed. Remove and
        // re-add against the plain (unpinned) archive URL instead, so nix
        // actually re-resolves HEAD and picks up a fresh narHash.
        const remove_r = exec.capture(ctx.gpa, ctx.io, &ctx.machine, &.{ "nix", "profile", "remove", element }) catch {
            output.updateSelfNixFailed();
            return;
        };
        defer ctx.gpa.free(remove_r.stdout);
        defer ctx.gpa.free(remove_r.stderr);
        if (remove_r.exit_code != 0) {
            output.raw(remove_r.stdout);
            output.raw(remove_r.stderr);
            output.updateSelfNixFailed();
            return;
        }
        // Even against the plain unpinned URL, nix caches its resolution for
        // `tarball-ttl` seconds (default 3600) regardless of HTTP cache-control
        // headers — so within an hour of any prior nix operation touching this
        // URL, add would silently reuse the stale narHash and reinstall the
        // same old version. --refresh forces nix to actually re-check HEAD.
        const add_r = exec.capture(ctx.gpa, ctx.io, &ctx.machine, &.{ "nix", "profile", "add", "--no-write-lock-file", "--refresh", FLAKE_URL }) catch {
            output.updateSelfNixReinstallFailed();
            return;
        };
        defer ctx.gpa.free(add_r.stdout);
        defer ctx.gpa.free(add_r.stderr);
        if (add_r.exit_code != 0) {
            output.raw(add_r.stdout);
            output.raw(add_r.stderr);
            output.updateSelfNixReinstallFailed();
            return;
        }
        output.updateSelfDone(version.VERSION, remote_ver);
        output.updateSelfNixRehash();
        return;
    }

    const plat_info = blk: {
        const pv = root.object.get("platforms") orelse break :blk null;
        if (pv != .object) break :blk null;
        break :blk pv.object.get(version.PLATFORM);
    };
    if (plat_info == null) {
        output.updateSelfNoPlatform(version.PLATFORM);
        return;
    }

    const dl_url = blk: {
        const v = plat_info.?.object.get("url") orelse {
            output.printWarning("malformed release metadata");
            return;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                output.printWarning("malformed release metadata");
                return;
            },
        };
    };

    const raw_cksum = blk: {
        if (plat_info.?.object.get("blake3")) |v|
            break :blk switch (v) {
                .string => |s| s,
                else => {
                    output.printWarning("malformed release metadata");
                    return;
                },
            };
        if (plat_info.?.object.get("checksum")) |v|
            break :blk switch (v) {
                .string => |s| s,
                else => {
                    output.printWarning("malformed release metadata");
                    return;
                },
            };
        output.printWarning("missing checksum in release metadata");
        return;
    };
    const expected_hex = if (std.mem.startsWith(u8, raw_cksum, "blake3:")) raw_cksum["blake3:".len..] else raw_cksum;

    if (ctx.cfg.confirm and !output.confirm("")) return;

    output.updateSelfDownloading(remote_ver, version.PLATFORM);
    const tmp_path = exec.downloadToTemp(ctx.gpa, ctx.io, dl_url) catch {
        output.printWarning("download failed — check your connection and try again");
        return;
    };
    defer ctx.gpa.free(tmp_path);
    // Clean up the downloaded temp file whether install succeeds or fails —
    // it's only ever a scratch copy verified against the release checksum.
    defer std.Io.Dir.deleteFileAbsolute(ctx.io, tmp_path) catch {};

    output.updateSelfVerifying();
    exec.verifyAndInstall(ctx.gpa, ctx.io, tmp_path, expected_hex, install_path) catch |e| switch (e) {
        error.ChecksumMismatch => {
            output.updateSelfChecksumFailed();
            return;
        },
        else => return e,
    };

    output.updateSelfDone(version.VERSION, remote_ver);
}

// archives.json covers every version between current and latest; the manifest's
// `notes` field only ever describes the single latest release. Try the full-range
// changelog first so an update spanning several versions doesn't collapse down to
// just the newest one's notes — fall back to `notes` only when the archive has
// nothing (e.g. releases predating archives.json, or the fetch failing).
fn updateReleaseNotes(gpa: std.mem.Allocator, io: std.Io, root: std.json.Value, source_url: []const u8, current: []const u8, latest: []const u8) ![]u8 {
    if (buildKeprArchiveReleaseNotes(gpa, io, source_url, current, latest) catch null) |notes| {
        if (std.mem.trim(u8, notes, " \t\r\n").len > 0) return notes;
        gpa.free(notes);
    }
    if (releaseNotesFromMetadata(gpa, root)) |notes| return notes;
    return gpa.dupe(u8, "");
}

fn releaseNotesFromMetadata(gpa: std.mem.Allocator, root: std.json.Value) ?[]u8 {
    if (root != .object) return null;
    // `notes` is the one canonical manifest field. The retired `release_notes`
    // and `changelog` fallbacks are gone — Kepr now emits `notes` everywhere, and
    // releases that predate `--notes` fall back to archives.json in the caller.
    const v = root.object.get("notes") orelse return null;
    return switch (v) {
        .string => |s| gpa.dupe(u8, s) catch null,
        else => null,
    };
}

fn buildKeprArchiveReleaseNotes(gpa: std.mem.Allocator, io: std.Io, source_url: []const u8, current: []const u8, latest: []const u8) ![]u8 {
    const archive_url = try keprArchiveUrl(gpa, source_url);
    defer gpa.free(archive_url);

    const body = exec.fetchUrl(gpa, io, archive_url) catch return gpa.dupe(u8, "");
    defer gpa.free(body);

    return releaseNotesFromArchiveJson(gpa, body, current, latest);
}

fn keprArchiveUrl(gpa: std.mem.Allocator, source_url: []const u8) ![]u8 {
    const scheme = std.mem.indexOf(u8, source_url, "://") orelse return error.InvalidUpdateSource;
    const path_start = std.mem.indexOfScalarPos(u8, source_url, scheme + 3, '/') orelse return error.InvalidUpdateSource;
    const origin = source_url[0..path_start];
    const path = source_url[path_start..];
    if (!std.mem.startsWith(u8, path, "/api/")) return error.InvalidUpdateSource;

    const after_api = path["/api/".len..];
    const repo_end = std.mem.indexOfScalar(u8, after_api, '/') orelse return error.InvalidUpdateSource;
    const repo = after_api[0..repo_end];
    if (repo.len == 0) return error.InvalidUpdateSource;

    return std.fmt.allocPrint(gpa, "{s}/{s}/archives.json?limit=100", .{ origin, repo });
}

// Saves arrive newest-first. For each version in the update range we want the OLDEST
// save message (the one that introduced that version), not a follow-up cleanup/docs save.
// We overwrite the tracked message on each occurrence, so the final stored value per
// version is always the oldest (last-seen in a newest-first stream).
fn releaseNotesFromArchiveJson(gpa: std.mem.Allocator, body: []const u8, current: []const u8, latest: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return gpa.dupe(u8, "");
    defer parsed.deinit();

    if (parsed.value != .object) return gpa.dupe(u8, "");
    const saves_v = parsed.value.object.get("saves") orelse return gpa.dupe(u8, "");
    if (saves_v != .array) return gpa.dupe(u8, "");

    // version string → oldest message seen (both slice into parsed JSON, valid until deinit)
    var best_msg = std.StringHashMap([]const u8).init(gpa);
    defer best_msg.deinit();
    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(gpa);

    for (saves_v.array.items) |save| {
        if (save != .object) continue;
        const ver_v = save.object.get("version") orelse continue;
        const msg_v = save.object.get("message") orelse continue;
        if (ver_v != .string or msg_v != .string) continue;
        const ver = ver_v.string;
        const msg = std.mem.trim(u8, msg_v.string, " \t\r\n");
        if (msg.len == 0 or !versionInUpdateRange(ver, current, latest)) continue;

        const entry = try best_msg.getOrPut(ver);
        if (!entry.found_existing) try order.append(gpa, ver);
        // Always overwrite: saves are newest-first, so last write = oldest save = version-intro message
        entry.value_ptr.* = msg;
    }

    if (order.items.len == 0) return gpa.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (order.items) |ver| {
        const msg = best_msg.get(ver).?;
        // Use only the first line as the summary; multi-line saves may have implementation details below
        const summary_end = std.mem.indexOf(u8, msg, "\n") orelse msg.len;
        const summary = std.mem.trim(u8, msg[0..summary_end], " \t\r");
        if (summary.len == 0) continue;
        try appendLine(&out, gpa, "## {s}\n", .{ver});
        try appendLine(&out, gpa, "- {s}\n\n", .{summary});
    }

    if (out.items.len == 0) {
        out.deinit(gpa);
        return gpa.dupe(u8, "");
    }
    return out.toOwnedSlice(gpa);
}

fn appendLine(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime template: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, template, args);
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

fn versionInUpdateRange(candidate: []const u8, current: []const u8, latest: []const u8) bool {
    const cand = parseSemver(candidate) orelse return std.mem.eql(u8, candidate, latest);
    const cur = parseSemver(current) orelse return std.mem.eql(u8, candidate, latest);
    const lat = parseSemver(latest) orelse return std.mem.eql(u8, candidate, latest);
    return compareSemver(cand, cur) == .gt and compareSemver(cand, lat) != .gt;
}

fn remoteVersionNewer(current: []const u8, remote: []const u8) bool {
    const cur = parseSemver(current) orelse return !std.mem.eql(u8, current, remote);
    const rem = parseSemver(remote) orelse return !std.mem.eql(u8, current, remote);
    return compareSemver(rem, cur) == .gt;
}

const VersionOrder = enum { lt, eq, gt };

fn compareSemver(a: Semver, b: Semver) VersionOrder {
    if (a.major != b.major) return if (a.major < b.major) .lt else .gt;
    if (a.minor != b.minor) return if (a.minor < b.minor) .lt else .gt;
    if (a.patch != b.patch) return if (a.patch < b.patch) .lt else .gt;
    return .eq;
}

fn parseSemver(raw: []const u8) ?Semver {
    const v = if (std.mem.startsWith(u8, raw, "v")) raw[1..] else raw;
    var it = std.mem.splitScalar(u8, v, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{
        .major = std.fmt.parseInt(u32, major_s, 10) catch return null,
        .minor = std.fmt.parseInt(u32, minor_s, 10) catch return null,
        .patch = std.fmt.parseInt(u32, patch_s, 10) catch return null,
    };
}

test "versionInUpdateRange includes only newer versions through latest" {
    try std.testing.expect(versionInUpdateRange("3.2.3", "3.1.9", "3.2.3"));
    try std.testing.expect(versionInUpdateRange("3.2.0", "3.1.9", "3.2.3"));
    try std.testing.expect(!versionInUpdateRange("3.1.9", "3.1.9", "3.2.3"));
    try std.testing.expect(!versionInUpdateRange("3.2.4", "3.1.9", "3.2.3"));
}

test "remoteVersionNewer does not offer downgrades" {
    try std.testing.expect(remoteVersionNewer("3.2.3", "3.2.4"));
    try std.testing.expect(!remoteVersionNewer("3.2.4", "3.2.3"));
    try std.testing.expect(!remoteVersionNewer("3.2.4", "3.2.4"));
}

test "releaseNotesFromArchiveJson uses oldest save per version" {
    // Saves arrive newest-first. For 3.2.3, the newest save is a CONTINUITY update;
    // the oldest is the version-intro message. We expect the intro message in the output.
    const body =
        \\{
        \\  "saves": [
        \\    {"version":"3.2.3","message":"wip: record verification in CONTINUITY"},
        \\    {"version":"3.2.1","message":"old release"},
        \\    {"version":"3.2.3","message":"add streaming deflate path"}
        \\  ]
        \\}
    ;
    const notes = try releaseNotesFromArchiveJson(std.testing.allocator, body, "3.2.1", "3.2.3");
    defer std.testing.allocator.free(notes);

    try std.testing.expect(std.mem.indexOf(u8, notes, "## 3.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "- add streaming deflate path") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "CONTINUITY") == null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "old release") == null);
}

test "releaseNotesFromMetadata reads canonical notes and ignores retired keys" {
    const a = std.testing.allocator;

    // Canonical field is read.
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"notes\":\"colored progress bar\"}", .{});
        defer parsed.deinit();
        const got = releaseNotesFromMetadata(a, parsed.value).?;
        defer a.free(got);
        try std.testing.expectEqualStrings("colored progress bar", got);
    }

    // Retired field names are no longer honoured — they fall through to null so
    // the caller drops to the archives.json derivation instead.
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"release_notes\":\"x\",\"changelog\":\"y\"}", .{});
        defer parsed.deinit();
        try std.testing.expect(releaseNotesFromMetadata(a, parsed.value) == null);
    }
}

// om goodbye — clean uninstall. Three install paths:
// - nix profile (binary in nix store with a profile element) → nix profile remove
// - koh build or source build (plain binary on PATH) → delete the file
pub fn goodbye(ctx: Ctx) !void {
    output.goodbyeStart();

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const install_path = exec.selfExePath(ctx.io, &exe_buf) catch {
        errors.error_info.setMessage("could not determine install path", .{});
        return error.Internal;
    };

    // A binary outside the nix store is a koh build or source build — delete it.
    if (!std.mem.startsWith(u8, install_path, "/nix/store/")) {
        output.goodbyeFile(install_path);
        if (ctx.cfg.confirm and !output.confirm("")) return;
        std.Io.Dir.deleteFileAbsolute(ctx.io, install_path) catch |e| {
            errors.error_info.setMessage("could not remove {s}", .{install_path});
            return e;
        };
        output.goodbyeDone();
        return;
    }

    // Binary is in the nix store — find and remove the profile element.
    const nina_element = exec.profileNinaElement(ctx.gpa, ctx.io, &ctx.machine);
    defer {
        if (nina_element) |n| ctx.gpa.free(n);
    }

    if (nina_element == null) {
        errors.error_info.setMessage("om not found in nix profile — was it installed via 'nix profile add'?", .{});
        return error.Internal;
    }

    output.goodbyeNix();
    if (ctx.cfg.confirm and !output.confirm("")) return;
    const ec = exec.streamLocal(ctx.io, &.{ "nix", "profile", "remove", nina_element.? }) catch {
        output.goodbyeFailed("nix profile remove failed");
        return;
    };
    if (ec != 0) {
        output.goodbyeFailed("nix profile remove failed");
        return;
    }
    output.goodbyeDone();
}

fn channelUpdateCmd(ctx: Ctx) !void {
    output.updateStart(ctx.machine.name);
    _ = try exec.channelUpdate(ctx.io, &ctx.machine, ctx.gpa);
    output.updateDone();
}

pub fn upgrade(ctx: Ctx) !void {
    if (!try runPreHook(ctx, "pre-upgrade")) {
        output.aborted();
        return error.HookAborted;
    }

    // Optional first positional arg is the NixOS configuration name to rebuild
    // (e.g. `om flake upgrade bagalamukhi`). Defaults to the machine name, so
    // `om flake upgrade` on host "bagalamukhi" rebuilds /etc/nixos#bagalamukhi.
    const flake_attr: ?[]const u8 = if (ctx.args.len > 0) ctx.args[0] else ctx.machine.name;

    output.upgradeStart(ctx.machine.name);
    // Flake systems update inputs (flake.lock); channel systems update channels.
    // Running nix-channel --update on a flake system is a no-op at best. The
    // rebuild below is already flake-aware via exec.nixosRebuildSwitch.
    if (flakeSystem(ctx)) {
        output.printSubstep("updating flake inputs", .{});
        _ = exec.flakeUpdateAt(ctx.io, &ctx.machine, ctx.gpa, ctx.machine.config_path) catch {};
    } else {
        output.printSubstep("updating channels", .{});
        _ = exec.channelUpdate(ctx.io, &ctx.machine, ctx.gpa) catch {};
    }
    output.printSubstep("rebuilding", .{});
    output.buildPanelInit();
    const start = std.Io.Clock.awake.now(ctx.io);
    var panel = output.BuildPanel{};
    const code = exec.nixosRebuildSwitchWithPanel(ctx.io, &ctx.machine, ctx.gpa, &panel, flake_attr, ctx.passthrough) catch |e| {
        output.buildPanelClear();
        return e;
    };
    output.buildPanelClear();
    if (code != 0) {
        // Surface any nix warnings before the failure line so the user sees them
        // even on a failed upgrade — they often point at the root cause.
        const warnings = errors.extractWarnings(ctx.gpa, errors.getBuildStderr()) catch &.{};
        defer {
            for (warnings) |w| ctx.gpa.free(w);
            ctx.gpa.free(warnings);
        }
        if (warnings.len > 0) output.buildWarnings(warnings);
        output.applyFailed("");
        return error.BuildFailed;
    }
    const elapsed_ns = @max(0, start.untilNow(ctx.io, .awake).toNanoseconds());
    const elapsed: u64 = @intCast(@divFloor(elapsed_ns, 1_000_000));
    const gen = exec.getCurrentGeneration(ctx.gpa, ctx.io, &ctx.machine) catch 0;
    output.applyDone(gen, elapsed, false);
    runPostHook(ctx, "post-upgrade");
}

pub fn log(ctx: Ctx) !void {
    output.logHeader(ctx.machine.name);
    const content = exec.readNinaLog(ctx.gpa, ctx.io, ctx.environ, ctx.last) catch {
        // No log yet — that's fine
        return;
    };
    defer ctx.gpa.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (t[0] == '{') {
            renderJsonLogLine(ctx.gpa, t);
        } else {
            // legacy tab-separated format
            var parts = std.mem.tokenizeScalar(u8, t, '\t');
            const date = parts.next() orelse continue;
            const time = parts.next() orelse "";
            const action = parts.next() orelse "";
            const detail = parts.next() orelse "";
            output.logRow(date, time, action, detail);
        }
    }
}

// The on-disk log is JSON Lines: {"ts","machine","command","outcome","gen_after",...}.
// Render ts -> date/time columns, command -> action, outcome(+gen) -> detail.
fn renderJsonLogLine(gpa: std.mem.Allocator, line: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch {
        // Unparseable — show raw rather than drop, but sanitized: a corrupted or
        // tampered-with log entry is untrusted text by the time we get here
        // (NINA-016).
        const cleaned = output.sanitize(gpa, line) catch line;
        defer if (cleaned.ptr != line.ptr) gpa.free(cleaned);
        output.logRow(cleaned, "", "", "");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const o = parsed.value.object;

    const ts = jsonStr(o, "ts");
    const date = if (ts.len >= 10) ts[0..10] else ts;
    const time = if (ts.len >= 16) ts[11..16] else "";
    const action = jsonStr(o, "command");
    const outcome = jsonStr(o, "outcome");

    var buf: [160]u8 = undefined;
    var detail: []const u8 = outcome;
    if (o.get("gen_after")) |g| {
        if (g == .integer) {
            detail = std.fmt.bufPrint(&buf, "{s}   -> gen {d}", .{ outcome, g.integer }) catch outcome;
        }
    }
    output.logRow(date, time, action, detail);
}

fn jsonStr(o: std.json.ObjectMap, key: []const u8) []const u8 {
    if (o.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

pub fn edit(ctx: Ctx) !void {
    // `edit` is multi-word, so a bare positional ("hardware") arrives as ctx.sub.
    // hardware-configuration.nix is generated by nixos-generate-config and warns
    // against hand-editing — refuse rather than silently opening the wrong file.
    if (std.mem.eql(u8, ctx.sub, "hardware")) {
        output.editHardwareWarning();
        return;
    }

    // --dir opens the whole config directory (for editors that work better with
    // a folder open), as root so root-owned config trees like /etc/nixos work.
    var open_dir = false;
    for (ctx.args) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) open_dir = true;
    }
    if (open_dir) {
        output.editOpen(ctx.machine.config_path, ctx.cfg.editor);
        _ = try exec.openEditorSudo(ctx.io, ctx.gpa, ctx.cfg.editor, ctx.machine.config_path);
        return;
    }

    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/configuration.nix", .{ctx.machine.config_path});
    defer ctx.gpa.free(path);
    output.editOpen(path, ctx.cfg.editor);
    _ = try exec.openEditor(ctx.io, ctx.gpa, ctx.cfg.editor, path, null);
}

pub fn fmt(ctx: Ctx) !void {
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/configuration.nix", .{ctx.machine.config_path});
    defer ctx.gpa.free(path);
    if (ctx.check) {
        const code = try exec.nixpkgsFmt(ctx.io, &ctx.machine, ctx.gpa, path, true);
        if (code != 0) output.fmtNeedsFormat() else output.fmtDone();
        return;
    }
    output.fmtStart(path);
    _ = try exec.nixpkgsFmt(ctx.io, &ctx.machine, ctx.gpa, path, false);
    output.fmtDone();
}

pub fn repl(ctx: Ctx) !void {
    output.replStart();
    _ = try exec.nixRepl(ctx.io, &ctx.machine, ctx.gpa);
}

pub fn develop(ctx: Ctx) !void {
    if (std.mem.eql(u8, ctx.sub, "show")) {
        _ = try exec.nixBuild(ctx.io, &ctx.machine, ctx.gpa, null, ctx.passthrough);
        return;
    }
    const run_cmd: ?[]const u8 = if (ctx.args.len > 0 and std.mem.eql(u8, ctx.sub, "run"))
        ctx.args[0]
    else
        null;
    output.developStart(&.{});
    _ = try exec.nixDevelopPs1(ctx.io, &ctx.machine, ctx.gpa, run_cmd, ctx.environ, ctx.passthrough);
    output.developDone();
}

pub fn info(ctx: Ctx) !void {
    output.infoHeader(ctx.machine.name);
    const nixos_ver = exec.systemInfo(ctx.gpa, ctx.io, &ctx.machine) catch try ctx.gpa.dupe(u8, "unknown");
    defer ctx.gpa.free(nixos_ver);
    output.infoRow("nixos", std.mem.trim(u8, nixos_ver, " \t\n\r"));

    const kernel = exec.kernelInfo(ctx.gpa, ctx.io, &ctx.machine) catch try ctx.gpa.dupe(u8, "unknown");
    defer ctx.gpa.free(kernel);
    output.infoRow("kernel", std.mem.trim(u8, kernel, " \t\n\r"));

    const uptime = exec.uptimeInfo(ctx.gpa, ctx.io, &ctx.machine) catch try ctx.gpa.dupe(u8, "unknown");
    defer ctx.gpa.free(uptime);
    output.infoRow("uptime", std.mem.trim(u8, uptime, " \t\n\r"));
}

pub fn boot(ctx: Ctx) !void {
    output.bootHeader(ctx.machine.name);
    const entries = exec.bootEntries(ctx.gpa, ctx.io, &ctx.machine) catch &.{};
    defer ctx.gpa.free(entries);
    for (entries, 0..) |entry, i| output.bootEntry(entry, i);
}

pub fn searchCmd(ctx: Ctx) !void {
    const query = if (ctx.args.len > 0) ctx.args[0] else "";
    api.ensureRegistryPinned(ctx.gpa, ctx.io, ctx.environ);
    const selected = try search_tui.run(ctx.gpa, ctx.io, query, .packages, ctx.environ);
    if (selected) |npkg| try selectAndInstall(ctx, npkg);
}

// om cache <pkg> — whether the package's store path is present locally and (via
// path-info's per-path fields) what cache/signature it came from. Non-zero exit
// means nix couldn't resolve the path into the local store — not cached.
pub fn cacheCmd(ctx: Ctx) !void {
    const pkg_name = if (ctx.args.len > 0) ctx.args[0] else {
        errors.error_info.setMessage("usage: om cache <package>", .{});
        return error.Internal;
    };
    output.cacheCheckStart(pkg_name);
    const installable = try std.fmt.allocPrint(ctx.gpa, "nixpkgs#{s}", .{pkg_name});
    defer ctx.gpa.free(installable);
    const r = try exec.capture(ctx.gpa, ctx.io, &ctx.machine, &.{ "nix", "path-info", "--json", installable });
    defer ctx.gpa.free(r.stdout);
    defer ctx.gpa.free(r.stderr);
    if (r.exit_code != 0) {
        output.cacheNotCached(pkg_name);
        return;
    }
    output.cacheResult(pkg_name, r.stdout);
}

pub fn optionCmd(ctx: Ctx) !void {
    const query = if (ctx.args.len > 0) ctx.args[0] else "";
    api.ensureRegistryPinned(ctx.gpa, ctx.io, ctx.environ);
    _ = try search_tui.run(ctx.gpa, ctx.io, query, .options, ctx.environ);
}

// Top-level alias for the option search that announces it covers both NixOS and
// home-manager options. The widget's option tree comes from nixpkgs's module
// system, whose optionAttrSetToDocList shape is shared by home-manager — the
// header just states the coverage up front.
pub fn optionsCmd(ctx: Ctx) !void {
    const query = if (ctx.args.len > 0) ctx.args[0] else {
        output.searchEmptyQuery();
        return;
    };
    output.optionsHeader(query);
    api.ensureRegistryPinned(ctx.gpa, ctx.io, ctx.environ);
    _ = try search_tui.run(ctx.gpa, ctx.io, query, .options, ctx.environ);
}

pub fn install(ctx: Ctx) !void {
    const pkg_name = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;

    api.ensureRegistryPinned(ctx.gpa, ctx.io, ctx.environ);

    // Search for the package to get the attr
    const pkgs = api.searchPackages(ctx.gpa, ctx.io, ctx.environ, pkg_name) catch {
        errors.error_info.setMessage("'{s}' not found in nixpkgs", .{pkg_name});
        errors.error_info.setSuggestion("om search {s}", .{pkg_name});
        return error.PackageNotFound;
    };

    if (pkgs.len == 0) {
        // No matches — likely a typo. Suggest the closest real package and offer it.
        if (closestPackage(ctx, pkg_name)) |sugg| {
            output.didYouMean(pkg_name, sugg.pname);
            if (output.confirm("")) try selectAndInstall(ctx, sugg);
            return;
        }
        errors.error_info.setMessage("'{s}' not found in nixpkgs", .{pkg_name});
        errors.error_info.setSuggestion("om search {s}", .{pkg_name});
        return error.PackageNotFound;
    }

    // Prefer an exact name match over the first search result — `install ripgrep`
    // must pick "ripgrep", not the alphabetically-first match like "repgrep".
    var found = pkgs[0];
    for (pkgs) |p| {
        if (std.mem.eql(u8, p.pname, pkg_name)) {
            found = p;
            break;
        }
    }
    try selectAndInstall(ctx, found);
}

// Find the real package whose name is closest to a not-found query (typo help).
// Typos usually keep the leading characters, so gather candidates with a prefix
// search and rank by edit distance; return the best only if it's typo-close.
fn closestPackage(ctx: Ctx, query: []const u8) ?types.NixPackage {
    if (query.len < 2) return null;
    var candidates = api.searchPackages(ctx.gpa, ctx.io, ctx.environ, query[0..@min(query.len, 4)]) catch &.{};
    if (candidates.len == 0 and query.len > 2) {
        candidates = api.searchPackages(ctx.gpa, ctx.io, ctx.environ, query[0..2]) catch &.{};
    }
    if (candidates.len == 0) return null;

    var best: ?types.NixPackage = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (candidates) |p| {
        const d = editDistance(query, p.pname);
        if (d > 0 and d < best_dist) {
            best_dist = d;
            best = p;
        }
    }
    // Only suggest a genuinely close name, scaled to query length.
    const threshold = @max(@as(usize, 2), query.len / 3);
    return if (best_dist <= threshold) best else null;
}

// Case-insensitive Levenshtein distance. Names longer than the row buffer are
// treated as far away (never suggested).
fn editDistance(a: []const u8, b: []const u8) usize {
    const n = b.len;
    if (a.len == 0) return n;
    if (n == 0) return a.len;
    if (n + 1 > 128) return std.math.maxInt(usize);
    var prev: [128]usize = undefined;
    var curr: [128]usize = undefined;
    var j: usize = 0;
    while (j <= n) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        curr[0] = i;
        j = 1;
        while (j <= n) : (j += 1) {
            const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            curr[j] = @min(prev[j] + 1, @min(curr[j - 1] + 1, prev[j - 1] + cost));
        }
        @memcpy(prev[0 .. n + 1], curr[0 .. n + 1]);
    }
    return prev[n];
}

test "editDistance is case-insensitive Levenshtein" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("firefux", "firefox"));
    try std.testing.expectEqual(@as(usize, 0), editDistance("git", "GIT"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("fierfox", "firefox"));
    try std.testing.expectEqual(@as(usize, 7), editDistance("", "firefox"));
}

// Prompt for the install method (profile / system / try) and dispatch. Shared by
// `om install <pkg>` and the search widget's Enter-to-select — the letter keys
// are read here, after the search widget's raw mode is gone, so they don't
// collide with typing a query.
fn selectAndInstall(ctx: Ctx, npkg: types.NixPackage) !void {
    output.installSelectPrompt(npkg.pname, npkg.version);

    var choice_buf: [8]u8 = undefined;
    var choice_len: usize = 0;
    while (choice_len < choice_buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, choice_buf[choice_len .. choice_len + 1]) catch break;
        if (n == 0) break;
        if (choice_buf[choice_len] == '\n') break;
        choice_len += 1;
    }
    const choice = std.mem.trim(u8, choice_buf[0..choice_len], " \t");

    if (choice.len == 0 or choice[0] == 'i' or choice[0] == 'I') {
        try profileInstallPkg(ctx, npkg);
    } else if (choice[0] == 's' or choice[0] == 'S') {
        try systemInstallPkg(ctx, npkg);
    } else if (choice[0] == 't' or choice[0] == 'T') {
        try tryPkg(ctx, npkg);
    }
}

fn profileInstallPkg(ctx: Ctx, npkg: types.NixPackage) !void {
    output.installStart(npkg.pname, .profile);
    if (npkg.unfree) {
        output.printSubstep("NIXPKGS_ALLOW_UNFREE=1 nix profile add --impure nixpkgs#{s}", .{npkg.attr});
        output.printTeach(try std.fmt.allocPrint(ctx.gpa, "NIXPKGS_ALLOW_UNFREE=1 nix profile add --impure nixpkgs#{s}", .{npkg.attr}));
    } else {
        output.printSubstep("nix profile add nixpkgs#{s}", .{npkg.attr});
        output.printTeach(try std.fmt.allocPrint(ctx.gpa, "nix profile add nixpkgs#{s}", .{npkg.attr}));
    }
    const code = try exec.profileInstall(ctx.io, &ctx.machine, ctx.gpa, ctx.environ, npkg.attr, npkg.unfree);
    if (code != 0) return error.ProcessFailed;
    output.installDone(npkg.pname);
}

fn systemInstallPkg(ctx: Ctx, npkg: types.NixPackage) !void {
    const config_path = try std.fmt.allocPrint(ctx.gpa, "{s}/configuration.nix", .{ctx.machine.config_path});
    defer ctx.gpa.free(config_path);
    const line = api.findSystemPackagesLine(ctx.io, config_path) orelse 1;
    output.installEditorPrompt(npkg.pname, config_path, line, ctx.cfg.editor);
    _ = try exec.openEditor(ctx.io, ctx.gpa, ctx.cfg.editor, config_path, line);
    if (ctx.cfg.confirm) {
        if (output.confirm("apply now? ")) {
            try apply(ctx);
        }
    }
}

fn tryPkg(ctx: Ctx, npkg: types.NixPackage) !void {
    output.tryStart(npkg.pname);
    output.printSubstep("nix shell nixpkgs#{s}", .{npkg.attr});
    output.tryExitHint();
    _ = try exec.nixShellPs1(ctx.io, &ctx.machine, ctx.gpa, npkg.attr, ctx.environ);
    output.tryDone();
}

pub fn remove(ctx: Ctx) !void {
    const pkg_name = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
    output.removeStart(pkg_name);
    const code = try exec.profileRemove(ctx.io, &ctx.machine, ctx.gpa, pkg_name);
    if (code != 0) return error.ProcessFailed;
    output.done();
}

pub fn list(ctx: Ctx) !void {
    output.listHeader(ctx.machine.name);

    // Profile packages: parse `nix profile list --json` into clean name+version
    // rows instead of dumping nix's verbose multi-line "Name:/Flake attribute:"
    // blocks.
    if (exec.profileListJson(ctx.gpa, ctx.io, &ctx.machine) catch null) |json| {
        defer ctx.gpa.free(json);
        output.listSection("profile");
        renderProfileJson(ctx.gpa, json);
    }

    // System packages: the references of /run/current-system/sw, each a
    // <hash>-<name>-<version> store path.
    if (exec.systemPackagePaths(ctx.gpa, ctx.io, &ctx.machine) catch null) |paths| {
        defer ctx.gpa.free(paths);
        output.blankLine();
        output.listSection("system");
        var lines = std.mem.splitScalar(u8, paths, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            const row = pkgFromStorePath(t);
            // Skip support paths with no parseable version (man pages, wrappers).
            if (row.version.len == 0) continue;
            output.listPkg(row.name, row.version);
        }
    }
}

const PkgRow = struct { name: []const u8, version: []const u8 };

// Split a nix store path basename (<hash>-<name>-<version>) into name + version.
// Version begins at the first '-' followed by a digit, which reliably lands on
// the name/version boundary since the 32-char hash and package names start with
// non-digits.
fn pkgFromStorePath(path: []const u8) PkgRow {
    const base = std.fs.path.basename(path);
    const after_hash = if (base.len > 33 and base[32] == '-') base[33..] else base;
    var i: usize = 0;
    while (i + 1 < after_hash.len) : (i += 1) {
        if (after_hash[i] == '-' and std.ascii.isDigit(after_hash[i + 1])) {
            return .{ .name = after_hash[0..i], .version = stripOutputSuffix(after_hash[i + 1 ..]) };
        }
    }
    return .{ .name = after_hash, .version = "" };
}

// Multi-output derivations append the output name to the store path (e.g.
// curl-8.20.0-bin, less-692-man). Strip that suffix so the version column reads
// as just the version.
fn stripOutputSuffix(ver: []const u8) []const u8 {
    const suffixes = [_][]const u8{ "-bin", "-man", "-dev", "-doc", "-lib", "-info", "-out", "-static", "-devdoc" };
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, ver, s)) return ver[0 .. ver.len - s.len];
    }
    return ver;
}

test "pkgFromStorePath splits name and version at first dash-digit" {
    const a = pkgFromStorePath("/nix/store/abcdefghijklmnopqrstuvwxyz012345-ripgrep-15.1.0");
    try std.testing.expectEqualStrings("ripgrep", a.name);
    try std.testing.expectEqualStrings("15.1.0", a.version);

    const b = pkgFromStorePath("/nix/store/abcdefghijklmnopqrstuvwxyz012345-helix-25.01");
    try std.testing.expectEqualStrings("helix", b.name);
    try std.testing.expectEqualStrings("25.01", b.version);

    // multi-output store paths drop their output-name suffix
    const c = pkgFromStorePath("/nix/store/abcdefghijklmnopqrstuvwxyz012345-curl-8.20.0-bin");
    try std.testing.expectEqualStrings("curl", c.name);
    try std.testing.expectEqualStrings("8.20.0", c.version);
}

fn firstStorePath(el: std.json.Value) ?[]const u8 {
    if (el != .object) return null;
    const sp = el.object.get("storePaths") orelse return null;
    if (sp != .array or sp.array.items.len == 0) return null;
    const first = sp.array.items[0];
    return if (first == .string) first.string else null;
}

// `nix profile list --json` has two shapes across nix versions: newer keys each
// element by name (object), older lists them positionally (array). Handle both.
fn renderProfileJson(gpa: std.mem.Allocator, json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const elements = parsed.value.object.get("elements") orelse return;
    switch (elements) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const ver = if (firstStorePath(entry.value_ptr.*)) |p| pkgFromStorePath(p).version else "";
                output.listPkg(entry.key_ptr.*, ver);
            }
        },
        .array => |arr| {
            for (arr.items) |el| {
                const path = firstStorePath(el) orelse continue;
                const row = pkgFromStorePath(path);
                output.listPkg(row.name, row.version);
            }
        },
        else => {},
    }
}

pub fn tryCmd(ctx: Ctx) !void {
    const pkg_name_arg = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
    const shell_pkg = types.NixPackage{ .attr = pkg_name_arg, .pname = pkg_name_arg, .version = "", .description = "" };
    try tryPkg(ctx, shell_pkg);
}

// --- Home Manager commands ---

const home_help = [_][2][]const u8{
    .{ "apply", "apply home-manager configuration" },
    .{ "apply --dry", "preview changes without activating" },
    .{ "back", "roll back one generation" },
    .{ "check", "validate without applying" },
    .{ "diff", "compare the latest two generations" },
    .{ "edit", "open home.nix" },
    .{ "history", "list all generations" },
    .{ "init", "set up home manager for the first time" },
    .{ "init --switch", "set up and activate immediately" },
    .{ "packages", "list managed packages" },
};

const HomeGen = struct {
    number: u32,
    date: []const u8,
    time: []const u8,
    path: []const u8,
};

// `home-manager generations` lines read:
//   2026-06-01 11:56 : id 765 -> /nix/store/<hash>-home-manager-generation
// Newest first, so index 0 is the current generation.
fn parseHomeGenerations(gpa: std.mem.Allocator, out_str: []const u8) ![]HomeGen {
    var gens: std.ArrayList(HomeGen) = .empty;
    var lines = std.mem.splitScalar(u8, out_str, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, t, " \t");
        const date = it.next() orelse continue;
        const time = it.next() orelse continue;
        var number: ?u32 = null;
        var path: []const u8 = "";
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "id")) {
                if (it.next()) |n| number = std.fmt.parseInt(u32, n, 10) catch null;
            } else if (std.mem.startsWith(u8, tok, "/nix/store/")) {
                path = tok;
            }
        }
        const num = number orelse continue;
        try gens.append(gpa, .{
            .number = num,
            .date = try gpa.dupe(u8, date),
            .time = try gpa.dupe(u8, time),
            .path = try gpa.dupe(u8, path),
        });
    }
    return gens.toOwnedSlice(gpa);
}

fn freeHomeGens(gpa: std.mem.Allocator, gens: []HomeGen) void {
    for (gens) |g| {
        gpa.free(g.date);
        gpa.free(g.time);
        gpa.free(g.path);
    }
    gpa.free(gens);
}

test "parseHomeGenerations reads id, date and store path" {
    const a = std.testing.allocator;
    const sample =
        \\2026-06-01 11:56 : id 765 -> /nix/store/aaaa-home-manager-generation
        \\2026-05-31 10:29 : id 764 -> /nix/store/bbbb-home-manager-generation
    ;
    const gens = try parseHomeGenerations(a, sample);
    defer freeHomeGens(a, gens);
    try std.testing.expectEqual(@as(usize, 2), gens.len);
    try std.testing.expectEqual(@as(u32, 765), gens[0].number);
    try std.testing.expectEqualStrings("2026-06-01", gens[0].date);
    try std.testing.expectEqualStrings("11:56", gens[0].time);
    try std.testing.expectEqualStrings("/nix/store/aaaa-home-manager-generation", gens[0].path);
    try std.testing.expectEqual(@as(u32, 764), gens[1].number);
}

// Current (newest) home generation number, or 0 if unavailable.
fn homeCurrentGen(ctx: Ctx) u32 {
    const out = exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine) catch return 0;
    defer ctx.gpa.free(out);
    const gens = parseHomeGenerations(ctx.gpa, out) catch return 0;
    defer freeHomeGens(ctx.gpa, gens);
    return if (gens.len > 0) gens[0].number else 0;
}

pub fn home(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help"))
        return output.subcommandHelp("home", &home_help, null);

    // Home Manager manages the local user's environment. Detection (which binary,
    // ~/.config/home-manager, $HOME/$USER for the flake ref) all read the LOCAL
    // host, while exec routes over SSH for a remote machine — so `home --on
    // <remote>` would decide mode/flake-ref from the wrong box. Refuse it cleanly
    // rather than acting on a mismatch.
    if (!ctx.machine.local) {
        output.homeLocalOnly(ctx.machine.name);
        return;
    }

    // init runs before mode detection: its whole purpose is bootstrapping a host
    // that has no home-manager yet, so a .none mode must not short-circuit it.
    if (std.mem.eql(u8, ctx.sub, "init")) return homeInitCmd(ctx);

    const mode = exec.detectHomeManager(ctx.gpa, ctx.io, ctx.environ);
    if (mode == .none) {
        output.homeNotInstalled();
        return;
    }

    // apply is the only command meaningful in module mode (it redirects to
    // `om apply`); everything else needs the standalone home-manager CLI.
    if (std.mem.eql(u8, ctx.sub, "apply")) return homeApply(ctx, mode);
    // edit just opens the local home.nix — fine in module mode too.
    if (std.mem.eql(u8, ctx.sub, "edit")) return homeEdit(ctx);

    if (mode == .module) {
        output.homeModuleManaged();
        return;
    }

    if (std.mem.eql(u8, ctx.sub, "back")) return homeBack(ctx);
    if (std.mem.eql(u8, ctx.sub, "history")) return homeHistory(ctx);
    if (std.mem.eql(u8, ctx.sub, "check")) return homeCheck(ctx);
    if (std.mem.eql(u8, ctx.sub, "diff")) return homeDiff(ctx);
    if (std.mem.eql(u8, ctx.sub, "packages")) return homePackages(ctx);

    return output.subcommandHelp("home", &home_help, null);
}

fn homePackages(ctx: Ctx) !void {
    const out = try exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(out);
    const gens = try parseHomeGenerations(ctx.gpa, out);
    defer freeHomeGens(ctx.gpa, gens);

    output.homePackagesHeader(ctx.machine.name);
    if (gens.len == 0 or gens[0].path.len == 0) return;

    // The generation's OWN references are home-manager's activation deps
    // (bash, coreutils, ...), not what the user installed. The user's packages
    // live one level down, in the `…-home-manager-path` env the generation
    // references — descend into it and list ITS references. Fall back to the
    // generation refs if that env isn't present (older home-manager layouts).
    const gen_refs = exec.homeGenerationReferences(ctx.gpa, ctx.io, &ctx.machine, gens[0].path) catch return;
    defer ctx.gpa.free(gen_refs);

    var refs = gen_refs;
    var env_refs: ?[]u8 = null;
    defer if (env_refs) |e| ctx.gpa.free(e);
    if (findHomeManagerPath(gen_refs)) |pkg_path| {
        if (exec.homeGenerationReferences(ctx.gpa, ctx.io, &ctx.machine, pkg_path)) |e| {
            env_refs = e;
            refs = e;
        } else |_| {}
    }

    // Dedup by name: multi-output derivations (jq, jq-lib, jq-doc) collapse to
    // the same name after the output suffix is stripped. Keys are slices into
    // `refs`, valid for this function's lifetime.
    var seen = std.StringHashMap(void).init(ctx.gpa);
    defer seen.deinit();
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const row = pkgFromStorePath(t);
        if (row.version.len == 0) continue;
        if (std.mem.indexOf(u8, row.name, "home-manager") != null) continue;
        if (seen.contains(row.name)) continue;
        seen.put(row.name, {}) catch {};
        output.listPkg(row.name, row.version);
    }
}

// The `…-home-manager-path` env among a generation's references — the buildEnv
// of the user's home.packages. Returns the full store-path line, or null.
fn findHomeManagerPath(refs: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, refs, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, t, "home-manager-path") != null) return t;
    }
    return null;
}

test "findHomeManagerPath picks the env, not the generation or infra" {
    const refs =
        \\/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bash-5.3
        \\/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-home-manager-path
        \\/nix/store/cccccccccccccccccccccccccccccccc-coreutils-9.11
    ;
    try std.testing.expectEqualStrings(
        "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-home-manager-path",
        findHomeManagerPath(refs).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), findHomeManagerPath("/nix/store/x-bash-5.3\n"));
}

fn homeDiff(ctx: Ctx) !void {
    const out = try exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(out);
    const gens = try parseHomeGenerations(ctx.gpa, out);
    defer freeHomeGens(ctx.gpa, gens);

    // Need two generations and both their store paths to diff their closures.
    if (gens.len < 2 or gens[0].path.len == 0 or gens[1].path.len == 0) {
        output.homeNothingToDiff();
        return;
    }
    const newer = gens[0];
    const older = gens[1];
    output.homeDiffHeader(older.number, newer.number, ctx.machine.name);
    if (try exec.diffClosuresPaths(ctx.io, &ctx.machine, ctx.gpa, older.path, newer.path) != 0)
        return error.ProcessFailed;
}

fn homeCheck(ctx: Ctx) !void {
    output.homeCheckStart(ctx.machine.name);
    const code = try exec.homeManagerBuild(ctx.io, &ctx.machine, ctx.gpa, ctx.passthrough);
    if (code != 0) return error.BuildFailed;
    output.homeCheckOk();
}

fn homeEdit(ctx: Ctx) !void {
    // Standalone home config lives at ~/.config/home-manager/home.nix; the same
    // path is what detection keys on for module mode, so it resolves for both.
    const path = exec.homeNixPath(ctx.gpa, ctx.environ) orelse {
        errors.error_info.setMessage("could not resolve ~/.config/home-manager/home.nix", .{});
        return error.ConfigNotFound;
    };
    defer ctx.gpa.free(path);
    output.homeEditOpen(path, ctx.cfg.editor);
    _ = try exec.openEditor(ctx.io, ctx.gpa, ctx.cfg.editor, path, null);
}

fn homeHistory(ctx: Ctx) !void {
    const out = try exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(out);
    const gens = try parseHomeGenerations(ctx.gpa, out);
    defer freeHomeGens(ctx.gpa, gens);
    output.homeHistoryHeader(ctx.machine.name);
    // Newest-first from home-manager; the first row is the current generation.
    for (gens, 0..) |g, i| output.homeHistoryRow(g.number, g.date, g.time, i == 0);
}

fn homeBack(ctx: Ctx) !void {
    const out = try exec.homeGenerations(ctx.gpa, ctx.io, &ctx.machine);
    defer ctx.gpa.free(out);
    const gens = try parseHomeGenerations(ctx.gpa, out);
    defer freeHomeGens(ctx.gpa, gens);

    // Newest-first: [0] is current, [1] is the generation to roll back to.
    if (gens.len < 2) {
        output.alreadyOldest();
        return;
    }
    const current = gens[0].number;
    const prev = gens[1].number;

    output.homeBackStart(ctx.machine.name, current, prev);
    if (ctx.cfg.confirm and !output.confirm("")) return;
    const code = try exec.homeManagerRollback(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.BuildFailed;
    output.homeBackDone(prev);
}

fn homeInitCmd(ctx: Ctx) !void {
    var switch_on_init = false;
    var dir: ?[]const u8 = null;
    for (ctx.args) |arg| {
        if (std.mem.eql(u8, arg, "--switch")) {
            switch_on_init = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            dir = arg;
        }
    }

    // Guard only the default location — a custom dir is the user's call, and
    // home-manager creates it. Never clobber an existing ~/.config/home-manager.
    if (dir == null) {
        if (exec.homeNixPath(ctx.gpa, ctx.environ)) |path| {
            defer ctx.gpa.free(path);
            if (exec.pathExists(ctx.io, path)) {
                output.homeInitExists(path);
                return;
            }
        }
    }

    output.homeInitStart(switch_on_init, dir);
    const code = try exec.homeManagerInit(ctx.io, &ctx.machine, ctx.gpa, switch_on_init, dir);
    if (code != 0) return error.BuildFailed;
    output.homeInitDone(switch_on_init);
}

fn homeApply(ctx: Ctx, mode: exec.HomeManagerMode) !void {
    // NixOS/flake module: home config is rebuilt by nixos-rebuild — redirect.
    if (mode == .module) {
        output.homeModuleManaged();
        return;
    }
    if (ctx.dry) {
        output.homeApplyDry(ctx.machine.name);
        const code = try exec.homeManagerBuild(ctx.io, &ctx.machine, ctx.gpa, ctx.passthrough);
        if (code != 0) return error.BuildFailed;
        output.homeApplyDryDone();
        return;
    }

    if (!try runPreHook(ctx, "pre-home")) {
        output.aborted();
        return error.HookAborted;
    }

    output.homeApplyStart(ctx.machine.name);

    // Flake-based home config: switch by attribute with a graceful fallback
    // chain. A channel-based config (no flake.nix) uses a plain switch.
    const dir = exec.homeFlakeDir(ctx.gpa, ctx.io, ctx.environ);
    defer if (dir) |d| ctx.gpa.free(d);
    if (dir) |d| return homeApplyFlake(ctx, d);

    output.printSubstep("home-manager switch", .{});
    const start = std.Io.Clock.awake.now(ctx.io);
    const code = try exec.homeManagerSwitch(ctx.io, &ctx.machine, ctx.gpa, ctx.passthrough);
    if (code != 0) return error.BuildFailed;

    const elapsed_ns = @max(0, start.untilNow(ctx.io, .awake).toNanoseconds());
    const elapsed: u64 = @intCast(@divFloor(elapsed_ns, 1_000_000));
    output.homeApplyDone(homeCurrentGen(ctx), elapsed);
    runPostHook(ctx, "post-home");
}

// Switch a flake-based home config, trying the most specific attribute first:
//   <dir>#<user>-<arch>-<os>  →  <dir>#<user>  →  <dir>  (home-manager resolves)
// Each fallback fires only on a missing-attribute error, never on a real build
// failure. Mirrors how ${USER}-${system} homeConfigurations keys are written.
fn homeApplyFlake(ctx: Ctx, dir: []const u8) !void {
    const user = ctx.environ.get("USER") orelse "default";

    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |r| ctx.gpa.free(r);
        refs.deinit(ctx.gpa);
    }
    if (exec.homeManagerAttr(ctx.gpa, ctx.io, &ctx.machine, ctx.environ) catch null) |attr| {
        defer ctx.gpa.free(attr);
        try refs.append(ctx.gpa, try std.fmt.allocPrint(ctx.gpa, "{s}#{s}", .{ dir, attr }));
    }
    try refs.append(ctx.gpa, try std.fmt.allocPrint(ctx.gpa, "{s}#{s}", .{ dir, user }));
    try refs.append(ctx.gpa, try ctx.gpa.dupe(u8, dir));

    const start = std.Io.Clock.awake.now(ctx.io);
    for (refs.items, 0..) |ref, i| {
        output.printSubstep("home-manager switch --flake {s}", .{ref});
        switch (try exec.homeManagerSwitchFlake(ctx.io, &ctx.machine, ctx.gpa, ref, ctx.passthrough)) {
            .ok => {
                const elapsed_ns = @max(0, start.untilNow(ctx.io, .awake).toNanoseconds());
                const elapsed: u64 = @intCast(@divFloor(elapsed_ns, 1_000_000));
                output.homeApplyDone(homeCurrentGen(ctx), elapsed);
                runPostHook(ctx, "post-home");
                return;
            },
            // Attr not defined by the flake — drop to the next candidate.
            .attr_missing => {
                if (i + 1 < refs.items.len) output.homeAttrFallback(ref);
                continue;
            },
            .failed => return error.BuildFailed,
        }
    }
    return error.BuildFailed;
}

// --- Service commands ---

const service_help = [_][2][]const u8{
    .{ "disable <svc>", "disable at boot" },
    .{ "enable <svc>", "enable at boot" },
    .{ "list", "list running services" },
    .{ "logs <svc>", "show service logs" },
    .{ "restart <svc>", "restart a service" },
    .{ "start <svc>", "start a service" },
    .{ "status <svc>", "service status" },
    .{ "stop <svc>", "stop a service" },
};

// Verbs service() is willing to forward to `sudo systemctl`. Anything else
// (mask, kill, revert, edit, isolate, ...) used to reach systemctl with no
// confirmation and without appearing in service_help, since the dispatcher
// forwarded ctx.sub verbatim after list/logs/status (NINA-011).
fn serviceVerbAllowed(verb: []const u8) bool {
    const known = [_][]const u8{ "start", "stop", "restart", "enable", "disable" };
    for (known) |v| {
        if (std.mem.eql(u8, verb, v)) return true;
    }
    return false;
}

pub fn service(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("service", &service_help, "add --user to act on user services");
    if (std.mem.eql(u8, ctx.sub, "list")) {
        output.serviceListHeader(ctx.machine.name);
        const svcs = exec.serviceList(ctx.gpa, ctx.io, &ctx.machine, ctx.user) catch &.{};
        defer ctx.gpa.free(svcs);
        for (svcs) |s| output.serviceRow(s);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "logs")) {
        const name = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        const follow = ctx.args.len > 1 and std.mem.eql(u8, ctx.args[1], "-f");
        output.serviceLogsHeader(name, ctx.last, ctx.machine.name);
        _ = try exec.serviceLogs(ctx.io, &ctx.machine, ctx.gpa, name, ctx.last, follow, ctx.user);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "status")) {
        const name = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        output.serviceVerb("status", name, ctx.machine.name);
        _ = try exec.serviceCtl(ctx.io, &ctx.machine, ctx.gpa, "status", name, ctx.user);
        return;
    }
    // start/stop/restart/enable/disable — checked against the allowlist before
    // ctx.args is even read, so an unrecognized verb never gets far enough to
    // touch a target service name.
    if (!serviceVerbAllowed(ctx.sub)) {
        output.subcommandHelp("service", &service_help, "add --user to act on user services");
        return error.Internal;
    }
    const name = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
    if (ctx.cfg.confirm and (std.mem.eql(u8, ctx.sub, "stop") or std.mem.eql(u8, ctx.sub, "disable"))) {
        if (!output.confirm("")) return;
    }
    output.serviceVerb(ctx.sub, name, ctx.machine.name);
    _ = try exec.serviceCtl(ctx.io, &ctx.machine, ctx.gpa, ctx.sub, name, ctx.user);
    output.serviceDone();
}

test "serviceVerbAllowed allows only the verbs listed in service_help" {
    try std.testing.expect(serviceVerbAllowed("start"));
    try std.testing.expect(serviceVerbAllowed("stop"));
    try std.testing.expect(serviceVerbAllowed("restart"));
    try std.testing.expect(serviceVerbAllowed("enable"));
    try std.testing.expect(serviceVerbAllowed("disable"));
}

test "serviceVerbAllowed rejects verbs systemctl accepts but om never confirmed or documented" {
    try std.testing.expect(!serviceVerbAllowed("mask"));
    try std.testing.expect(!serviceVerbAllowed("kill"));
    try std.testing.expect(!serviceVerbAllowed("revert"));
    try std.testing.expect(!serviceVerbAllowed("edit"));
    try std.testing.expect(!serviceVerbAllowed("isolate"));
    try std.testing.expect(!serviceVerbAllowed("starting")); // no substring match on "start"
}

// True when `sub` matches one of the verbs advertised in a dispatcher's help
// table, ignoring any "<arg>"/"[opt]" suffix (e.g. "add <url> [name]" -> "add").
// Shared by flake/channel/profile/pkg so an unrecognized subcommand (a typo
// like `om flake updtae`) fails loudly instead of falling off the end of the
// if-chain and exiting 0 (NINA-012).
fn subcommandKnown(help_rows: []const [2][]const u8, sub: []const u8) bool {
    for (help_rows) |row| {
        const verb = if (std.mem.indexOfScalar(u8, row[0], ' ')) |i| row[0][0..i] else row[0];
        if (std.mem.eql(u8, verb, sub)) return true;
    }
    return false;
}

// --- Flake commands ---

const flake_help = [_][2][]const u8{
    .{ "apply", "rebuild and switch to the new configuration" },
    .{ "check", "validate the flake" },
    .{ "clone <url>", "clone a flake repository" },
    .{ "init", "create a new flake.nix" },
    .{ "lock", "regenerate flake.lock" },
    .{ "pin <input> <rev>", "pin a flake input to a commit" },
    .{ "show", "inspect flake outputs" },
    .{ "unpin <input>", "release a pinned flake input" },
    .{ "update", "update flake inputs" },
    .{ "update <in>", "update a specific input" },
    .{ "upgrade", "update flake inputs and rebuild" },
};

pub fn flake(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("flake", &flake_help, null);
    if (!subcommandKnown(&flake_help, ctx.sub)) {
        output.subcommandHelp("flake", &flake_help, null);
        return error.Internal;
    }
    if (std.mem.eql(u8, ctx.sub, "update")) {
        output.flakeUpdateStart();
        const input: ?[]const u8 = if (ctx.args.len > 0) ctx.args[0] else null;
        _ = try exec.flakeUpdate(ctx.io, &ctx.machine, ctx.gpa, input, ctx.passthrough);
        output.flakeLockWritten();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "check")) {
        output.flakeCheckStart();
        const code = try exec.flakeCheck(ctx.io, &ctx.machine, ctx.gpa, ctx.passthrough);
        if (code != 0) {
            output.checkFailed("");
            return error.CheckFailed;
        }
        output.flakeValid();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "show")) {
        const json_out = exec.flakeShow(ctx.gpa, ctx.io, &ctx.machine) catch null;
        if (json_out) |j| {
            defer ctx.gpa.free(j);
            output.flakeShowHeader("flake outputs");
            // Parse and display the flake outputs
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, j, .{}) catch return;
            defer parsed.deinit();
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .object) {
                        var inner = entry.value_ptr.object.iterator();
                        while (inner.next()) |e2| {
                            const desc = if (e2.value_ptr.* == .object)
                                if (e2.value_ptr.object.get("description")) |d|
                                    if (d == .string) d.string else ""
                                else
                                    ""
                            else
                                "";
                            output.flakeShowEntry(entry.key_ptr.*, e2.key_ptr.*, desc);
                        }
                    }
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "init")) {
        _ = try exec.flakeInit(ctx.io, &ctx.machine, ctx.gpa);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "lock")) {
        _ = try exec.flakeLock(ctx.io, &ctx.machine, ctx.gpa);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "clone")) {
        const url = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        _ = try exec.flakeClone(ctx.io, &ctx.machine, ctx.gpa, url);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "apply")) return apply(ctx);
    if (std.mem.eql(u8, ctx.sub, "upgrade")) return upgrade(ctx);
    if (std.mem.eql(u8, ctx.sub, "pin")) return pin(ctx);
    if (std.mem.eql(u8, ctx.sub, "unpin")) return unpin(ctx);
}

// --- Store commands ---

const store_help = [_][2][]const u8{
    .{ "clean", "collect garbage and free store space" },
    .{ "fetch", "fetch and hash a url" },
    .{ "hash", "compute nix hash" },
    .{ "optimise", "deduplicate store paths with hard links" },
    .{ "path <attr>", "store path of a package" },
    .{ "repair", "repair corrupted paths" },
    .{ "verify", "verify store integrity" },
    .{ "weight", "store size and counts" },
};

pub fn store(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("store", &store_help, null);
    if (std.mem.eql(u8, ctx.sub, "clean")) {
        _ = try exec.storeGc(ctx.io, &ctx.machine, ctx.gpa);
        return;
    }
    // Accept both spellings — optimise (en) and optimize (us).
    if (std.mem.eql(u8, ctx.sub, "optimise") or std.mem.eql(u8, ctx.sub, "optimize")) {
        output.storeOptimiseStart(ctx.machine.name);
        _ = try exec.storeOptimise(ctx.io, &ctx.machine, ctx.gpa);
        output.storeOptimiseDone();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "verify")) {
        output.storeVerifyStart();
        _ = try exec.storeVerify(ctx.io, &ctx.machine, ctx.gpa);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "repair")) {
        if (ctx.cfg.confirm and !output.confirm("")) return;
        output.storeRepairStart();
        _ = try exec.storeRepair(ctx.io, &ctx.machine, ctx.gpa);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "weight")) {
        const si = try exec.storeInfo(ctx.gpa, ctx.io, &ctx.machine);
        output.storeInfo(si);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "path")) {
        const attr = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        const path = try exec.storePath(ctx.gpa, ctx.io, &ctx.machine, attr);
        defer ctx.gpa.free(path);
        output.storePath(path);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "fetch")) return fetch(ctx);
    if (std.mem.eql(u8, ctx.sub, "hash")) return hash(ctx);
    // default: weight
    const si = try exec.storeInfo(ctx.gpa, ctx.io, &ctx.machine);
    output.storeInfo(si);
}

// --- Top-level store aliases ---
//
// `om optimize` / `om repair` are shortcuts for the `store` subcommands, with
// verbose output (optimize) and confirmation (repair) built in.

pub fn optimizeCmd(ctx: Ctx) !void {
    output.optimizeStart(ctx.machine.name);
    const code = try exec.storeOptimiseVerbose(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.ProcessFailed;
    output.optimizeDone();
}

pub fn repairCmd(ctx: Ctx) !void {
    if (ctx.cfg.confirm and !output.confirm("")) return;
    output.repairStart();
    const code = try exec.storeRepair(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.ProcessFailed;
    output.repairDone();
}

pub fn flakeUpdateCmd(ctx: Ctx) !void {
    output.flakeUpdateStart();
    const code = try exec.flakeUpdateAtConfig(ctx.io, &ctx.machine, ctx.gpa);
    if (code != 0) return error.ProcessFailed;
    output.flakeLockWritten();
}

// --- Channel commands ---

const channel_help = [_][2][]const u8{
    .{ "list", "list channels" },
    .{ "add <url> [name]", "add a channel" },
    .{ "remove <name>", "remove a channel" },
    .{ "update", "update all channels" },
};

pub fn channel(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("channel", &channel_help, null);
    if (!subcommandKnown(&channel_help, ctx.sub)) {
        output.subcommandHelp("channel", &channel_help, null);
        return error.Internal;
    }
    // On a flake-managed system, nix-channel operations generally don't apply.
    if (flakeSystem(ctx)) output.flakeChannelNote();
    if (std.mem.eql(u8, ctx.sub, "list")) {
        output.channelListHeader(ctx.machine.name);
        const chans = try exec.channelList(ctx.gpa, ctx.io, &ctx.machine);
        defer ctx.gpa.free(chans);
        for (chans) |ch| output.channelRow(ch);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "add")) {
        const url = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        const name = if (ctx.args.len > 1) ctx.args[1] else "";
        _ = try exec.channelAdd(ctx.io, &ctx.machine, ctx.gpa, url, name);
        output.channelDone();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "remove")) {
        const name = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
        _ = try exec.channelRemove(ctx.io, &ctx.machine, ctx.gpa, name);
        output.channelDone();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "update")) {
        return channelUpdateCmd(ctx);
    }
}

// --- Profile commands ---

const profile_help = [_][2][]const u8{
    .{ "info", "list profile packages" },
    .{ "install <attr>", "install a package into your profile" },
    .{ "remove <attr>", "remove a package from your profile" },
    .{ "upgrade", "upgrade all profile packages" },
};

pub fn profile(ctx: Ctx) !void {
    if (std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("profile", &profile_help, null);
    if (ctx.sub.len > 0 and !subcommandKnown(&profile_help, ctx.sub)) {
        output.subcommandHelp("profile", &profile_help, null);
        return error.Internal;
    }
    if (std.mem.eql(u8, ctx.sub, "info") or ctx.sub.len == 0) {
        output.profileListHeader();
        const out = exec.profileList(ctx.gpa, ctx.io, &ctx.machine) catch null;
        if (out) |o| {
            defer ctx.gpa.free(o);
            var lines = std.mem.splitScalar(u8, o, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len == 0) continue;
                output.profileRow(t, "", "");
            }
        }
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "install")) {
        const attr = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
        _ = try exec.profileInstall(ctx.io, &ctx.machine, ctx.gpa, ctx.environ, attr, false);
        output.done();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "remove")) {
        const attr = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
        _ = try exec.profileRemove(ctx.io, &ctx.machine, ctx.gpa, attr);
        output.done();
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "upgrade")) {
        _ = try exec.profileUpgrade(ctx.io, &ctx.machine, ctx.gpa);
        output.done();
        return;
    }
}

// --- Pkg commands ---

const pkg_help = [_][2][]const u8{
    .{ "build", "build a package" },
    .{ "cache <pkg>", "check store cache status of a package" },
    .{ "closure <pkg>", "full closure" },
    .{ "deps <pkg>", "direct dependencies" },
    .{ "develop", "enter dev shell" },
    .{ "info", "list installed packages" },
    .{ "options <q>", "search nixos + home-manager options" },
    .{ "path <pkg>", "store path" },
    .{ "repl", "nix repl with nixpkgs" },
    .{ "run <pkg>", "run a package without installing" },
    .{ "search <q>", "find packages" },
    .{ "size <pkg>", "closure size" },
    .{ "tree <pkg>", "show what depends on a package" },
    .{ "try <pkg>", "run a package without installing" },
    .{ "why <pkg>", "what pulled it in" },
};

pub fn pkg(ctx: Ctx) !void {
    if (ctx.sub.len == 0 or std.mem.eql(u8, ctx.sub, "help")) return output.subcommandHelp("pkg", &pkg_help, null);
    if (!subcommandKnown(&pkg_help, ctx.sub)) {
        output.subcommandHelp("pkg", &pkg_help, null);
        return error.Internal;
    }
    if (std.mem.eql(u8, ctx.sub, "info")) return list(ctx);
    if (std.mem.eql(u8, ctx.sub, "build")) return build(ctx);
    if (std.mem.eql(u8, ctx.sub, "cache")) return cacheCmd(ctx);
    if (std.mem.eql(u8, ctx.sub, "why")) {
        const name = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
        if (try exec.pkgWhy(ctx.io, &ctx.machine, ctx.gpa, name) != 0) return error.PackageNotFound;
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "try")) return tryCmd(ctx);
    if (std.mem.eql(u8, ctx.sub, "tree")) return treeCmd(ctx);
    const name = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
    if (std.mem.eql(u8, ctx.sub, "deps")) {
        if (try exec.pkgDeps(ctx.io, &ctx.machine, ctx.gpa, name) != 0) return error.PackageNotFound;
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "size")) {
        const s = try exec.pkgSize(ctx.gpa, ctx.io, &ctx.machine, name);
        defer ctx.gpa.free(s);
        output.pkgResult("size", s);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "path")) {
        const p = try exec.storePath(ctx.gpa, ctx.io, &ctx.machine, name);
        defer ctx.gpa.free(p);
        output.pkgResult("path", p);
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "closure")) {
        if (try exec.pkgClosure(ctx.io, &ctx.machine, ctx.gpa, name) != 0) return error.PackageNotFound;
        return;
    }
    if (std.mem.eql(u8, ctx.sub, "search")) return searchCmd(ctx);
    if (std.mem.eql(u8, ctx.sub, "options")) return optionsCmd(ctx);
    if (std.mem.eql(u8, ctx.sub, "develop")) return develop(ctx);
    if (std.mem.eql(u8, ctx.sub, "repl")) return repl(ctx);
    if (std.mem.eql(u8, ctx.sub, "run")) return runCmd(ctx);
}

test "subcommandKnown rejects a garbage subcommand for each of flake/channel/profile/pkg" {
    try std.testing.expect(subcommandKnown(&flake_help, "update"));
    try std.testing.expect(!subcommandKnown(&flake_help, "updtae"));

    try std.testing.expect(subcommandKnown(&channel_help, "add"));
    try std.testing.expect(!subcommandKnown(&channel_help, "addd"));

    try std.testing.expect(subcommandKnown(&profile_help, "install"));
    try std.testing.expect(!subcommandKnown(&profile_help, "instal"));

    try std.testing.expect(subcommandKnown(&pkg_help, "closure"));
    try std.testing.expect(!subcommandKnown(&pkg_help, "closures"));
}

// Top-level alias for `om pkg why <pkg>` — surfaces what pulled a package in
// without the user needing to know about the `pkg` subgroup.
pub fn why(ctx: Ctx) !void {
    const name = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
    if (try exec.pkgWhy(ctx.io, &ctx.machine, ctx.gpa, name) != 0) return error.PackageNotFound;
}

pub fn treeCmd(ctx: Ctx) !void {
    const pkg_name = if (ctx.args.len > 0) ctx.args[0] else {
        errors.error_info.setMessage("usage: om tree <package>", .{});
        errors.error_info.setSuggestion("om tree firefox", .{});
        return error.Internal;
    };
    output.treeStart(pkg_name);
    const code = try exec.nixTree(ctx.io, &ctx.machine, ctx.gpa, pkg_name);
    if (code != 0) return error.ProcessFailed;
}

// --- Pin / Unpin ---

pub fn pin(ctx: Ctx) !void {
    const input = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
    const rev = if (ctx.args.len > 1) ctx.args[1] else return error.Internal;
    const flake_ref = try exec.flakeLockOverrideRef(ctx.gpa, ctx.io, &ctx.machine, input, rev);
    defer ctx.gpa.free(flake_ref);
    _ = try exec.flakeLockOverrideInput(ctx.io, &ctx.machine, ctx.gpa, input, flake_ref);
    output.pinDone(input, rev);
}

pub fn unpin(ctx: Ctx) !void {
    const input = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
    _ = try exec.flakeUpdate(ctx.io, &ctx.machine, ctx.gpa, input, &.{});
    output.unpinDone(input);
}

// --- Hash / Fetch ---

pub fn hash(ctx: Ctx) !void {
    const path = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
    const h = try exec.nixHash(ctx.gpa, ctx.io, &ctx.machine, path);
    defer ctx.gpa.free(h);
    output.hashResult(std.mem.trim(u8, h, " \t\n\r"));
}

pub fn fetch(ctx: Ctx) !void {
    const url = if (ctx.args.len > 0) ctx.args[0] else return error.Internal;
    const h = try exec.nixFetch(ctx.gpa, ctx.io, &ctx.machine, url);
    defer ctx.gpa.free(h);
    output.fetchResult(std.mem.trim(u8, h, " \t\n\r"), url);
}

// --- Build / Run ---

pub fn build(ctx: Ctx) !void {
    const attr: ?[]const u8 = if (ctx.args.len > 0) ctx.args[0] else null;
    output.buildStart(attr orelse "default");
    const code = try exec.nixBuild(ctx.io, &ctx.machine, ctx.gpa, attr, ctx.passthrough);
    if (code != 0) return error.BuildFailed;
    output.buildDone();
}

pub fn runCmd(ctx: Ctx) !void {
    const pkg_arg = if (ctx.args.len > 0) ctx.args[0] else return error.PackageNotFound;
    output.runStart(pkg_arg);
    _ = try exec.nixRun(ctx.io, &ctx.machine, ctx.gpa, pkg_arg, ctx.passthrough);
}

// --- Hello ---

pub fn hello(ctx: Ctx) !void {
    output.hello(ctx.cfg.machines);
}

const ConfigKind = enum { flake, channel, none };

// Scan the conventional /etc/nixos for a flake.nix (flake-based) or a
// configuration.nix (channel-based) to pre-fill the wizard's defaults.
fn scanConfig(io: std.Io) ConfigKind {
    if (exec.pathExists(io, "/etc/nixos/flake.nix")) return .flake;
    if (exec.pathExists(io, "/etc/nixos/configuration.nix")) return .channel;
    return .none;
}

// Runs when the config is absent on first invocation (interactive TTY only).
// Scans for an existing nixos config, detects flake vs channel, and offers a
// smart default path — flake-ness is detected, never asked.
pub fn firstRunWizard(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !void {
    output.firstRunBanner();
    output.firstRunNoConfig();

    var name_buf: [256]u8 = undefined;
    var path_buf: [256]u8 = undefined;

    const machine_name = output.firstRunPrompt("machine name", "my-machine", &name_buf);

    output.firstRunScanning();
    const kind = scanConfig(io);
    switch (kind) {
        .flake => output.firstRunDetected("/etc/nixos/flake.nix", true),
        .channel => output.firstRunDetected("/etc/nixos/configuration.nix", false),
        .none => output.firstRunNoneFound(),
    }

    // Detected systems default to /etc/nixos (press enter to confirm); when
    // nothing was found, leave the default empty so the user must type a path.
    const default_path: []const u8 = if (kind == .none) "" else "/etc/nixos";
    const config_path = output.firstRunPromptDefault("config path", default_path, kind != .none, &path_buf);

    // Re-detect at the chosen path in case the user pointed elsewhere — flake.nix
    // there means a flake system, recorded so channel commands warn appropriately.
    const use_flakes = exec.dirHasFlake(gpa, io, config_path);

    const conf_path = try config.configPath(gpa, environ);
    defer gpa.free(conf_path);
    if (std.fs.path.dirname(conf_path)) |dir| exec.ensureDir(gpa, io, dir);

    // `flake` is a top-level config field, so it must precede the [machine] block.
    const flake_line = if (use_flakes) "flake = true\n" else "";
    var content_buf: [1024]u8 = undefined;
    const content = try std.fmt.bufPrint(
        &content_buf,
        "{s}[machine]\nname = {s}\nconfig = {s}\nlocal = true\n",
        .{ flake_line, machine_name, config_path },
    );

    const file = std.Io.Dir.createFile(.cwd(), io, conf_path, .{}) catch {
        errors.error_info.setMessage("could not write {s}", .{conf_path});
        return error.Internal;
    };
    defer file.close(io);
    file.writePositionalAll(io, content, 0) catch {
        errors.error_info.setMessage("could not write {s}", .{conf_path});
        return error.Internal;
    };

    output.firstRunWritten(conf_path);
}

pub fn setup(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !void {
    // Create the config first if it doesn't exist. This makes `om setup`
    // a complete onboarding command — not just a nix-features check. Any legacy
    // ~/.om.conf is migrated to the XDG path before we decide to run the wizard.
    config.migrateLegacyConfig(gpa, io, environ);
    if (config.configPath(gpa, environ)) |conf_path| {
        defer gpa.free(conf_path);
        if (std.Io.Dir.openFile(.cwd(), io, conf_path, .{})) |f| {
            f.close(io);
        } else |_| {
            try firstRunWizard(gpa, io, environ);
            errors.error_info.reset();
        }
    } else |_| {}

    output.setupCheck();
    const status = exec.checkNixFeatures(gpa, io, environ);
    output.setupFeatures(status.nix_command, status.flakes);

    if (status.allEnabled()) {
        output.setupAllSet();
        api.ensureRegistryPinned(gpa, io, environ);
        return;
    }

    // On NixOS the features belong in configuration.nix (the declarative,
    // permanent home), not ~/.config/nix/nix.conf. Offer to add the one line;
    // the user runs the rebuild. We don't pin the registry here because the
    // features aren't live until that rebuild lands.
    if (exec.isNixOS(io)) {
        const conf_path = "/etc/nixos/configuration.nix";
        if (exec.nixosConfigEnablesFeatures(gpa, io, conf_path)) {
            output.setupNixosNeedsRebuild(conf_path);
            return;
        }
        output.setupNixosOffer(exec.NIXOS_FEATURES_LINE, conf_path);
        if (output.confirmDefaultNo("add it now?")) {
            if (exec.appendFeaturesToNixosConfig(gpa, io, environ, conf_path)) |_| {
                output.setupNixosWrote(conf_path);
            } else |_| {
                output.setupNixosManual(exec.NIXOS_FEATURES_LINE, conf_path);
            }
        } else {
            output.setupNixosManual(exec.NIXOS_FEATURES_LINE, conf_path);
        }
        return;
    }

    // Non-NixOS: a user-level nix.conf takes effect immediately, no sudo needed.
    output.setupEnabling();
    const path = try exec.enableNixFeatures(gpa, io, environ);
    defer gpa.free(path);

    output.setupDone(path);
    api.ensureRegistryPinned(gpa, io, environ);
}

// --- Log helper ---

// Escapes a string for embedding inside a JSON string literal. Truncates
// (rather than overflows `buf`) if the escaped form doesn't fit — used for a
// single log line where losing the tail of an implausibly long machine name is
// preferable to corrupting the line.
fn jsonEscape(buf: []u8, s: []const u8) []const u8 {
    var i: usize = 0;
    for (s) |ch| {
        const esc: ?u8 = switch (ch) {
            '"' => '"',
            '\\' => '\\',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            else => null,
        };
        if (esc) |e| {
            if (i + 2 > buf.len) break;
            buf[i] = '\\';
            buf[i + 1] = e;
            i += 2;
        } else {
            if (i + 1 > buf.len) break;
            buf[i] = ch;
            i += 1;
        }
    }
    return buf[0..i];
}

fn logAction(ctx: Ctx, action: []const u8, gen: u32) void {
    var ts_buf: [32]u8 = undefined;
    const ts = nowIso(ctx.io, &ts_buf);
    // machine.name is config-parsed and may legally contain `"` or `\`
    // (NINA-020) — embedding it unescaped produced an invalid JSON line that
    // renderJsonLogLine could only fall back to showing raw.
    var name_buf: [128]u8 = undefined;
    const machine_name = jsonEscape(&name_buf, ctx.machine.name);
    var buf: [256]u8 = undefined;
    const entry = std.fmt.bufPrint(&buf, "{{\"ts\":\"{s}\",\"machine\":\"{s}\",\"command\":\"{s}\",\"outcome\":\"success\",\"gen_before\":null,\"gen_after\":{d},\"duration_ms\":0}}\n", .{
        ts, machine_name, action, gen,
    }) catch return;
    exec.appendNinaLog(ctx.io, ctx.environ, entry);
}

test "jsonEscape lets a machine name containing quotes and backslashes round-trip through JSON" {
    var esc_buf: [128]u8 = undefined;
    const escaped = jsonEscape(&esc_buf, "kyoshi\" evil\\host");

    var line_buf: [256]u8 = undefined;
    const entry = std.fmt.bufPrint(&line_buf, "{{\"ts\":\"2026-01-01T00:00:00Z\",\"machine\":\"{s}\",\"command\":\"apply\",\"outcome\":\"success\",\"gen_before\":null,\"gen_after\":5,\"duration_ms\":0}}\n", .{escaped}) catch unreachable;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, entry, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("kyoshi\" evil\\host", parsed.value.object.get("machine").?.string);
}

// Wall-clock UTC as ISO-8601. Uses Io.Clock.real (the settable Unix-epoch clock);
// Io.Clock.awake is monotonic and unsuitable for timestamps. Falls back to epoch 0.
fn nowIso(io: std.Io, buf: []u8) []const u8 {
    const fallback = "1970-01-01T00:00:00Z";
    const ns = std.Io.Clock.real.now(io).toNanoseconds();
    if (ns <= 0) return fallback;
    const secs: u64 = @intCast(@divFloor(ns, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch return fallback;
}
