const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const exec = @import("exec.zig");
const output = @import("output.zig");

// Resolve the config file path: $XDG_CONFIG_HOME/om/config, falling back to
// ~/.config/om/config. om historically stored ~/.om.conf; that legacy
// location is auto-migrated to this path on load (see migrateLegacyConfig).
pub fn configPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "om", "config" });
    }
    const home = environ.get("HOME") orelse {
        errors.error_info.setSuggestion("set HOME environment variable", .{});
        return error.ConfigNotFound;
    };
    return std.fs.path.join(arena, &.{ home, ".config", "om", "config" });
}

fn legacyPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.om.conf", .{home}) catch null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// One-time migration of the legacy ~/.om.conf to the XDG path. Runs only when
// the old file exists and the new one does not, so it's idempotent and a no-op
// for fresh installs. Best-effort: any failure leaves the legacy file in place
// so the next load still finds it.
pub fn migrateLegacyConfig(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    const new_path = configPath(arena, environ) catch return;
    if (fileExists(io, new_path)) return;
    const legacy = legacyPath(arena, environ) orelse return;
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, legacy, arena, .unlimited) catch return;

    if (std.fs.path.dirname(new_path)) |dir| exec.ensureDir(arena, io, dir);
    const f = std.Io.Dir.createFile(.cwd(), io, new_path, .{}) catch return;
    f.writePositionalAll(io, content, 0) catch {
        f.close(io);
        return;
    };
    f.close(io);
    std.Io.Dir.deleteFile(.cwd(), io, legacy) catch {};
    output.configMigrated(homeShort(arena, new_path, environ));
}

// Collapse a leading $HOME to ~ for display only. Returns the input unchanged on
// any mismatch or allocation failure.
fn homeShort(arena: std.mem.Allocator, path: []const u8, environ: *const std.process.Environ.Map) []const u8 {
    const home = environ.get("HOME") orelse return path;
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
}

pub fn load(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !types.NinaConfig {
    migrateLegacyConfig(arena, io, environ);

    const path = try configPath(arena, environ);
    const home = environ.get("HOME") orelse "";

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, arena, .unlimited) catch {
        errors.error_info.setSuggestion("run om to set up", .{});
        return error.ConfigNotFound;
    };
    const cfg = try parse(arena, content, home);
    if (environ.contains("NINA_DEBUG")) debugDumpConfig(cfg);
    return cfg;
}

fn parse(arena: std.mem.Allocator, input: []const u8, home: []const u8) !types.NinaConfig {
    var config = types.NinaConfig{};
    var machines: std.ArrayList(types.Machine) = .empty;
    var current: ?types.Machine = null;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.eql(u8, trimmed, "[machine]")) {
            if (current) |m| try machines.append(arena, m);
            current = .{};
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        if (current) |*m| {
            setMachineField(arena, m, key, val, home) catch {};
        } else {
            setConfigField(arena, &config, key, val) catch {};
        }
    }

    if (current) |m| try machines.append(arena, m);
    config.machines = try machines.toOwnedSlice(arena);
    return config;
}

fn setConfigField(arena: std.mem.Allocator, config: *types.NinaConfig, key: []const u8, val: []const u8) !void {
    if (std.mem.eql(u8, key, "editor")) {
        config.editor = try arena.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "generations")) {
        config.generations = std.fmt.parseInt(u32, val, 10) catch 5;
    } else if (std.mem.eql(u8, key, "confirm")) {
        config.confirm = parseBool(val, true);
    } else if (std.mem.eql(u8, key, "teach")) {
        config.teach = parseBool(val, false);
    } else if (std.mem.eql(u8, key, "color")) {
        config.color = parseBool(val, true);
    } else if (std.mem.eql(u8, key, "flake")) {
        config.flake = parseBool(val, false);
    }
}

fn setMachineField(arena: std.mem.Allocator, m: *types.Machine, key: []const u8, val: []const u8, home: []const u8) !void {
    if (std.mem.eql(u8, key, "name")) {
        m.name = try arena.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "config")) {
        m.config_path = try arena.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "local")) {
        m.local = parseBool(val, true);
    } else if (std.mem.eql(u8, key, "default")) {
        m.default = parseBool(val, false);
    } else if (std.mem.eql(u8, key, "host")) {
        m.host = try arena.dupe(u8, val);
        // A machine with a host is remote unless explicitly marked local. The
        // Machine struct defaults local=true, so without this a [machine] block
        // that only sets host/user/ssh_key would render as "local".
        m.local = false;
    } else if (std.mem.eql(u8, key, "user")) {
        m.user = try arena.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "ssh_key")) {
        m.ssh_key = try expandHome(arena, val, home);
    }
}

fn parseBool(val: []const u8, default: bool) bool {
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "y") or std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1")) {
        return true;
    }
    if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "n") or std.mem.eql(u8, val, "off") or std.mem.eql(u8, val, "0")) {
        return false;
    }
    return default;
}

fn debugDumpConfig(cfg: types.NinaConfig) void {
    std.debug.print("NINA_DEBUG config\n", .{});
    std.debug.print("editor={s}\n", .{cfg.editor});
    std.debug.print("generations={d}\n", .{cfg.generations});
    std.debug.print("confirm={}\n", .{cfg.confirm});
    std.debug.print("teach={}\n", .{cfg.teach});
    std.debug.print("color={}\n", .{cfg.color});
    std.debug.print("flake={}\n", .{cfg.flake});
    for (cfg.machines, 0..) |m, i| {
        std.debug.print("machine[{d}].name={s}\n", .{ i, m.name });
        std.debug.print("machine[{d}].config={s}\n", .{ i, m.config_path });
        std.debug.print("machine[{d}].local={}\n", .{ i, m.local });
        std.debug.print("machine[{d}].default={}\n", .{ i, m.default });
        if (m.host) |host| std.debug.print("machine[{d}].host={s}\n", .{ i, host });
        if (m.user) |user| std.debug.print("machine[{d}].user={s}\n", .{ i, user });
    }
}

fn expandHome(arena: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "~")) return arena.dupe(u8, path);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] });
}

pub fn resolveMachine(config: *const types.NinaConfig, name: ?[]const u8) !types.Machine {
    if (name) |n| {
        for (config.machines) |m| {
            if (std.mem.eql(u8, m.name, n)) return m;
        }
        errors.error_info.setMessage("'{s}' is not in your config", .{n});
        errors.error_info.setSuggestion("check ~/.config/om/config", .{});
        return error.MachineNotFound;
    }
    for (config.machines) |m| {
        if (m.default) return m;
    }
    if (config.machines.len > 0) return config.machines[0];
    // No machines defined — return a default local machine
    return .{};
}

test "parse basic config" {
    const input =
        \\editor = hx
        \\generations = 3
        \\confirm = false
        \\teach = true
        \\
        \\[machine]
        \\name = test-box
        \\local = true
        \\default = true
    ;
    const config = try parse(std.testing.allocator, input, "/home/test");
    defer std.testing.allocator.free(config.machines);
    defer std.testing.allocator.free(config.editor);
    defer std.testing.allocator.free(config.machines[0].name);

    try std.testing.expectEqualStrings("hx", config.editor);
    try std.testing.expectEqual(@as(u32, 3), config.generations);
    try std.testing.expect(!config.confirm);
    try std.testing.expect(config.teach);
    try std.testing.expectEqual(@as(usize, 1), config.machines.len);
    try std.testing.expectEqualStrings("test-box", config.machines[0].name);
}

test "parse alternate booleans" {
    const input =
        \\confirm = y
        \\teach = no
        \\color = 1
        \\
        \\[machine]
        \\name = test-box
        \\local = n
        \\default = on
    ;
    const config = try parse(std.testing.allocator, input, "/home/test");
    defer std.testing.allocator.free(config.machines);
    defer std.testing.allocator.free(config.machines[0].name);

    try std.testing.expect(config.confirm);
    try std.testing.expect(!config.teach);
    try std.testing.expect(config.color);
    try std.testing.expect(!config.machines[0].local);
    try std.testing.expect(config.machines[0].default);
}

test "parse flake flag" {
    const with =
        \\flake = true
        \\
        \\[machine]
        \\name = box
    ;
    const cfg_with = try parse(std.testing.allocator, with, "/home/test");
    defer std.testing.allocator.free(cfg_with.machines);
    defer std.testing.allocator.free(cfg_with.machines[0].name);
    try std.testing.expect(cfg_with.flake);

    const without =
        \\[machine]
        \\name = box
    ;
    const cfg_without = try parse(std.testing.allocator, without, "/home/test");
    defer std.testing.allocator.free(cfg_without.machines);
    defer std.testing.allocator.free(cfg_without.machines[0].name);
    try std.testing.expect(!cfg_without.flake);
}

test "resolve machine by name" {
    var machines = [_]types.Machine{
        .{ .name = "alpha", .default = true },
        .{ .name = "beta" },
    };
    const config = types.NinaConfig{ .machines = &machines };
    const m = try resolveMachine(&config, "beta");
    try std.testing.expectEqualStrings("beta", m.name);
}

test "resolve default machine" {
    var machines = [_]types.Machine{
        .{ .name = "alpha", .default = true },
        .{ .name = "beta" },
    };
    const config = types.NinaConfig{ .machines = &machines };
    const m = try resolveMachine(&config, null);
    try std.testing.expectEqualStrings("alpha", m.name);
}
