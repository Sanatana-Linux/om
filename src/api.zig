// api.zig — nix data access: search, eval, options
// No HTTP. No curl. nix is on PATH by definition on NixOS.
const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const output = @import("output.zig");

// Pin the nixpkgs registry once so `nix search nixpkgs` resolves locally instead
// of refetching github on every query. Gated by a ~/.om-registry-pinned flag:
// absent -> pin + announce + create the flag; present -> no-op, silent. Failure
// to pin is non-fatal — search still runs (just slower), and the flag is left
// absent so a later run retries.
pub fn ensureRegistryPinned(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) void {
    const home = environ.get("HOME") orelse return;
    const flag_path = std.fmt.allocPrint(gpa, "{s}/.om-registry-pinned", .{home}) catch return;
    defer gpa.free(flag_path);

    if (std.Io.Dir.openFile(.cwd(), io, flag_path, .{})) |f| {
        f.close(io);
        return; // already pinned
    } else |_| {}

    output.pinningRegistry();

    const r = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "registry", "pin", "nixpkgs" },
    }) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    switch (r.term) {
        .exited => |code| if (code != 0) return,
        else => return,
    }

    const file = std.Io.Dir.createFile(.cwd(), io, flag_path, .{}) catch return;
    file.close(io);
}

pub fn searchPackages(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, query: []const u8) ![]types.NixPackage {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "search", "nixpkgs", query, "--json", "--no-update-lock-file" },
    }) catch {
        errors.error_info.setSuggestion("run nix-channel --update and try again", .{});
        return error.SearchFailed;
    };
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            // nix evaluates nixpkgs.legacyPackages during search and rejects unfree
            // packages even when the user has allowUnfree set system-wide. Retry
            // with NIXPKGS_ALLOW_UNFREE=1 so the package appears in results, and
            // tag it so the install step can pass the same override.
            if (isSearchUnfreeError(result.stderr)) {
                return searchPackagesUnfree(gpa, io, environ, query);
            }
            errors.error_info.setSuggestion("run nix-channel --update and try again", .{});
            return error.SearchFailed;
        },
        else => return error.SearchFailed,
    }

    return parseSearchJson(gpa, result.stdout, false);
}

fn isSearchUnfreeError(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "requires unfree license") != null or
        std.mem.indexOf(u8, stderr, "has an unfree license") != null;
}

fn searchPackagesUnfree(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, query: []const u8) ![]types.NixPackage {
    var env = try environ.clone(gpa);
    defer env.deinit();
    try env.put("NIXPKGS_ALLOW_UNFREE", "1");

    const result = std.process.run(gpa, io, .{
        // --impure allows builtins.getEnv in nixpkgs's unfree check to read
        // NIXPKGS_ALLOW_UNFREE from the environment; pure flake eval ignores it.
        .argv = &.{ "nix", "search", "nixpkgs", query, "--json", "--no-update-lock-file", "--impure" },
        .environ_map = &env,
    }) catch {
        errors.error_info.setSuggestion("run nix-channel --update and try again", .{});
        return error.SearchFailed;
    };
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            errors.error_info.setSuggestion("run nix-channel --update and try again", .{});
            return error.SearchFailed;
        },
        else => return error.SearchFailed,
    }

    return parseSearchJson(gpa, result.stdout, true);
}

fn parseSearchJson(gpa: std.mem.Allocator, json_str: []const u8, unfree: bool) ![]types.NixPackage {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{}) catch return error.SearchFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return error.SearchFailed;

    var packages: std.ArrayList(types.NixPackage) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (val != .object) continue;

        // Key format: "legacyPackages.x86_64-linux.firefox"
        const last_dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse continue;
        const attr = key[last_dot + 1 ..];

        const pname = if (val.object.get("pname")) |v|
            if (v == .string) v.string else attr
        else
            attr;

        const version = if (val.object.get("version")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const description = if (val.object.get("description")) |v|
            if (v == .string) v.string else ""
        else
            "";

        try packages.append(gpa, .{
            .attr = try gpa.dupe(u8, attr),
            .pname = try gpa.dupe(u8, pname),
            .version = try gpa.dupe(u8, version),
            .description = try gpa.dupe(u8, description),
            .unfree = unfree,
        });
    }

    return packages.toOwnedSlice(gpa);
}

pub const PkgMeta = struct {
    homepage: []const u8 = "",
    license: []const u8 = "",
};

// Evaluate a package's meta for the expanded search detail pane. One
// `nix eval --json .meta` call; returns null if the package can't be evaluated
// (broken, renamed, etc.). Returned strings are duped into `arena`.
pub fn packageMeta(arena: std.mem.Allocator, io: std.Io, attr: []const u8) ?PkgMeta {
    const ref = std.fmt.allocPrint(arena, "nixpkgs#{s}.meta", .{attr}) catch return null;
    const result = std.process.run(arena, io, .{
        .argv = &.{ "nix", "eval", "--json", ref },
    }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const parsed = std.json.parseFromSlice(std.json.Value, arena, result.stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    return .{
        .homepage = jsonFirstString(arena, o.get("homepage")),
        .license = licenseStr(arena, o.get("license")),
    };
}

// homepage is usually a string but occasionally a list — take the first string.
fn jsonFirstString(arena: std.mem.Allocator, v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    switch (val) {
        .string => |s| return arena.dupe(u8, s) catch "",
        .array => |arr| {
            if (arr.items.len > 0 and arr.items[0] == .string) return arena.dupe(u8, arr.items[0].string) catch "";
            return "";
        },
        else => return "",
    }
}

// license may be a single attrset, a list of attrsets, or a bare string. Join the
// fullName (or shortName) fields into one readable line. Result is duped into arena.
fn licenseStr(arena: std.mem.Allocator, v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    switch (val) {
        .string => |s| return arena.dupe(u8, s) catch "",
        .object => |obj| return arena.dupe(u8, licenseName(obj)) catch "",
        .array => |arr| {
            var buf: std.ArrayList(u8) = .empty;
            for (arr.items) |item| {
                if (item != .object) continue;
                const name = licenseName(item.object);
                if (name.len == 0) continue;
                if (buf.items.len > 0) buf.appendSlice(arena, ", ") catch {};
                buf.appendSlice(arena, name) catch {};
            }
            return buf.toOwnedSlice(arena) catch "";
        },
        else => return "",
    }
}

// Returns a slice into the parsed JSON arena (caller dupes before that frees).
fn licenseName(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("fullName")) |n| {
        if (n == .string) return n.string;
    }
    if (obj.get("shortName")) |n| {
        if (n == .string) return n.string;
    }
    return "";
}

// nix eval takes exactly one installable/expression and its result must be
// JSON-serializable, so (unlike searchPackages) this can't point straight at a
// flake attribute: lib.optionAttrSetToDocList is a function, not a value, and
// nixpkgs#nixosModules isn't an output path nix eval can resolve at all. This
// builds a minimal NixOS system from an empty module list and feeds its
// accumulated options tree to optionAttrSetToDocList ourselves — the same
// technique nixos-option and the NixOS manual generator use. --impure is
// required for builtins.getFlake on the bare registry name and for
// builtins.currentSystem.
fn nixStringLiteral(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '"' => try out.appendSlice(gpa, "\\\""),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '$' => if (i + 1 < s.len and s[i + 1] == '{') {
                try out.appendSlice(gpa, "\\${");
                i += 1;
            } else {
                try out.append(gpa, s[i]);
            },
            else => |ch| try out.append(gpa, ch),
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn optionsDocListExpr(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    const q = try nixStringLiteral(gpa, query);
    defer gpa.free(q);
    return std.fmt.allocPrint(gpa,
        \\let
        \\  flake = builtins.getFlake "nixpkgs";
        \\  query = {s};
        \\  queryRegex = ".*" + flake.lib.escapeRegex query + ".*";
        \\  eval = flake.lib.nixosSystem {{
        \\    system = builtins.currentSystem;
        \\    modules = [ {{ }} ];
        \\  }};
        \\  docs = flake.lib.optionAttrSetToDocList eval.options;
        \\in
        \\  builtins.filter (opt: builtins.match queryRegex opt.name != null) docs
    , .{q});
}

pub fn searchOptions(gpa: std.mem.Allocator, io: std.Io, query: []const u8) ![]NixOption {
    const expr = try optionsDocListExpr(gpa, query);
    defer gpa.free(expr);
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "eval", "--json", "--impure", "--expr", expr },
    }) catch return error.SearchFailed;
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SearchFailed,
        else => return error.SearchFailed,
    }

    return filterOptions(gpa, result.stdout, query);
}

pub const NixOption = struct {
    name: []const u8,
    type_str: []const u8,
    default: ?[]const u8,
    description: []const u8,
};

// optionAttrSetToDocList's "default" field is a plain string on older
// nixpkgs, or a { _type = "literalExpression"; text = "..."; } wrapper on
// nixos-render-docs era nixpkgs. Handle both; anything else (e.g. a
// submodule's structured default) renders as "no default" rather than
// guessing at a representation.
fn optionDefaultText(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |obj| if (obj.get("text")) |t| (if (t == .string) t.string else null) else null,
        else => null,
    };
}

fn filterOptions(gpa: std.mem.Allocator, json_str: []const u8, query: []const u8) ![]NixOption {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_str, .{}) catch return error.SearchFailed;
    defer parsed.deinit();

    if (parsed.value != .array) return error.SearchFailed;

    var opts: std.ArrayList(NixOption) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name = if (item.object.get("name")) |v| if (v == .string) v.string else continue else continue;
        if (query.len > 0 and std.mem.indexOf(u8, name, query) == null) continue;

        const type_str = if (item.object.get("type")) |v| if (v == .string) v.string else "any" else "any";
        const description = if (item.object.get("description")) |v| if (v == .string) v.string else "" else "";
        const default_val: ?[]const u8 = if (item.object.get("default")) |v| optionDefaultText(v) else null;

        try opts.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .type_str = try gpa.dupe(u8, type_str),
            .default = if (default_val) |d| try gpa.dupe(u8, d) else null,
            .description = try gpa.dupe(u8, description),
        });
    }

    return opts.toOwnedSlice(gpa);
}

pub fn findSystemPackagesLine(io: std.Io, config_path: []const u8) ?u32 {
    var buf: [65536]u8 = undefined;
    const content = std.Io.Dir.readFile(.cwd(), io, config_path, &buf) catch return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 1;
    while (lines.next()) |line| : (line_num += 1) {
        if (std.mem.indexOf(u8, line, "systemPackages") != null) return line_num;
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// searchOptions itself is not exercised here (no nix on this host); these
// pin filterOptions's parsing against JSON shaped like optionAttrSetToDocList's
// real output (NINA-009), covering both the modern literalExpression-wrapped
// default and the older plain-string default.

test "filterOptions extracts a known option from realistic doc-list JSON (NINA-009)" {
    const fixture =
        \\[
        \\  {
        \\    "name": "services.openssh.enable",
        \\    "type": "boolean",
        \\    "default": { "_type": "literalExpression", "text": "false" },
        \\    "description": "Whether to enable the OpenSSH secure shell daemon."
        \\  },
        \\  {
        \\    "name": "services.nginx.enable",
        \\    "type": "boolean",
        \\    "default": { "_type": "literalExpression", "text": "false" },
        \\    "description": "Whether to enable nginx."
        \\  }
        \\]
    ;

    const opts = try filterOptions(std.testing.allocator, fixture, "openssh");
    defer {
        for (opts) |o| {
            std.testing.allocator.free(o.name);
            std.testing.allocator.free(o.type_str);
            std.testing.allocator.free(o.description);
            if (o.default) |d| std.testing.allocator.free(d);
        }
        std.testing.allocator.free(opts);
    }

    try std.testing.expectEqual(@as(usize, 1), opts.len);
    try std.testing.expectEqualStrings("services.openssh.enable", opts[0].name);
    try std.testing.expectEqualStrings("boolean", opts[0].type_str);
    try std.testing.expect(opts[0].default != null);
    try std.testing.expectEqualStrings("false", opts[0].default.?);
    try std.testing.expect(std.mem.indexOf(u8, opts[0].description, "OpenSSH") != null);
}

test "optionsDocListExpr escapes query text inside Nix string literal" {
    const expr = try optionsDocListExpr(std.testing.allocator, "foo\"${bar}\\baz");
    defer std.testing.allocator.free(expr);

    try std.testing.expect(std.mem.indexOf(u8, expr, "query = \"foo\\\"\\${bar}\\\\baz\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, expr, "builtins.filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, expr, "escapeRegex") != null);
}

test "filterOptions still reads a plain-string default (pre-literalExpression nixpkgs)" {
    const fixture =
        \\[
        \\  {
        \\    "name": "services.openssh.ports",
        \\    "type": "list of signed integer",
        \\    "default": "[ 22 ]",
        \\    "description": "Ports on which to listen."
        \\  }
        \\]
    ;

    const opts = try filterOptions(std.testing.allocator, fixture, "");
    defer {
        for (opts) |o| {
            std.testing.allocator.free(o.name);
            std.testing.allocator.free(o.type_str);
            std.testing.allocator.free(o.description);
            if (o.default) |d| std.testing.allocator.free(d);
        }
        std.testing.allocator.free(opts);
    }

    try std.testing.expectEqual(@as(usize, 1), opts.len);
    try std.testing.expectEqualStrings("[ 22 ]", opts[0].default.?);
}

test "filterOptions returns no match for a query that isn't a substring of any option name" {
    const fixture =
        \\[
        \\  { "name": "services.openssh.enable", "type": "boolean", "default": null, "description": "" }
        \\]
    ;

    const opts = try filterOptions(std.testing.allocator, fixture, "postgres");
    defer std.testing.allocator.free(opts);
    try std.testing.expectEqual(@as(usize, 0), opts.len);
}
