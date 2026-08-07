// api.zig — nix data access: search, eval, options
// No HTTP. No curl. nix is on PATH by definition on NixOS.
const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const output = @import("output.zig");

// ─── Persistent package index ──────────────────────────────────────────────
//
// `nix search nixpkgs <query>` re-evaluates the entire nixpkgs attrset on every
// invocation — several seconds of work per keystroke. To make search feel
// instant, we build the FULL package index once (`nix search nixpkgs --json`
// with no query), cache it to disk keyed by the nixpkgs revision, and serve all
// searches by substring-matching against the in-memory index. Subsequent runs
// load the cached index from disk instead of re-evaluating nixpkgs.
//
// Cache layout: ~/.cache/om/packages-<rev>.json
// The <rev> is the nixpkgs flake revision, so the cache auto-invalidates when
// nixpkgs updates.

// The in-memory index, once loaded. The index and ALL its strings are allocated
// with std.heap.page_allocator and owned for the process lifetime (a one-shot CLI,
// so never freed). This is essential: the caller's arena resets on every keystroke,
// so the strings must NOT borrow from it.
var index_cache: ?[]types.NixPackage = null;
const index_alloc = std.heap.page_allocator;

// The nixpkgs revision used to key the cache. Reads a marker file first
// (~/.cache/om/rev) — written when the index is built — so the load path never
// invokes nix (nix flake metadata costs ~2s per call). Only when the marker is
// absent do we fall back to querying nix to derive the rev (e.g. first build).
fn nixpkgsRev(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) []const u8 {
    const home = environ.get("HOME") orelse return gpa.dupe(u8, "unknown") catch "unknown";
    const dir = std.fmt.allocPrint(gpa, "{s}/.cache/om", .{home}) catch return gpa.dupe(u8, "unknown") catch "unknown";
    _ = std.process.run(gpa, io, .{ .argv = &.{ "mkdir", "-p", dir } }) catch {};
    defer gpa.free(dir);
    const rev_path = std.fmt.allocPrint(gpa, "{s}/rev", .{dir}) catch return gpa.dupe(u8, "unknown") catch "unknown";
    defer gpa.free(rev_path);

    // Fast path: read the recorded rev marker (no nix invocation).
    if (std.Io.Dir.readFileAlloc(.cwd(), io, rev_path, gpa, .unlimited) catch null) |content| {
        defer gpa.free(content);
        const rev = std.mem.trim(u8, content, " \t\r\n");
        if (rev.len > 0) return gpa.dupe(u8, rev) catch gpa.dupe(u8, "unknown") catch "unknown";
    }

    // Slow path (first build only): derive the rev from nix.
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "flake", "metadata", "nixpkgs", "--json" },
    }) catch return gpa.dupe(u8, "unknown") catch "unknown";
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return gpa.dupe(u8, "unknown") catch "unknown",
        else => return gpa.dupe(u8, "unknown") catch "unknown",
    }
    // "locked": { "rev":"...", ... } — nix emits no space after the colon.
    const needle = "\"rev\":\"";
    const start = (std.mem.indexOf(u8, result.stdout, needle) orelse
        return gpa.dupe(u8, "unknown") catch "unknown") + needle.len;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse
        return gpa.dupe(u8, "unknown") catch "unknown";
    const rev = result.stdout[start..end];
    if (rev.len == 0) return gpa.dupe(u8, "unknown") catch "unknown";
    const owned = gpa.dupe(u8, rev) catch gpa.dupe(u8, "unknown") catch "unknown";
    // Record it for next time.
    if (std.Io.Dir.createFile(.cwd(), io, rev_path, .{})) |f| {
        defer f.close(io);
        f.writePositionalAll(io, owned, 0) catch {};
    } else |_| {}
    return owned;
}

// Cache file paths for the given revision (caller frees).
fn jsonCachePath(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, rev: []const u8) []const u8 {
    const home = environ.get("HOME") orelse return gpa.dupe(u8, "") catch "";
    const dir = std.fmt.allocPrint(gpa, "{s}/.cache/om", .{home}) catch return gpa.dupe(u8, "") catch "";
    _ = std.process.run(gpa, io, .{ .argv = &.{ "mkdir", "-p", dir } }) catch {};
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/packages-{s}.json", .{ dir, rev }) catch gpa.dupe(u8, "") catch "";
}

fn binCachePath(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, rev: []const u8) []const u8 {
    const home = environ.get("HOME") orelse return gpa.dupe(u8, "") catch "";
    const dir = std.fmt.allocPrint(gpa, "{s}/.cache/om", .{home}) catch return gpa.dupe(u8, "") catch "";
    _ = std.process.run(gpa, io, .{ .argv = &.{ "mkdir", "-p", dir } }) catch {};
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/packages-{s}.bin", .{ dir, rev }) catch gpa.dupe(u8, "") catch "";
}

// Load the full package index from cache, or build it fresh if the cache is
// missing/stale. The returned slice (and its strings) are owned for the process
// lifetime (page allocator); callers must not free them.
fn loadOrBuildIndex(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ![]types.NixPackage {
    if (index_cache) |c| return c;

    const rev = nixpkgsRev(gpa, io, environ);
    defer gpa.free(rev);
    const bpath = binCachePath(gpa, io, environ, rev);
    defer if (bpath.len > 0) gpa.free(bpath);

    // Fast path: load the compact binary cache (milliseconds).
    if (bpath.len > 0) {
        if (loadBinIndex(io, bpath) catch null) |pkgs| {
            if (pkgs.len > 0) {
                index_cache = pkgs;
                return pkgs;
            }
        }
    }

    // Fall back to the raw JSON cache (slower to parse, ~seconds).
    const jpath = jsonCachePath(gpa, io, environ, rev);
    defer if (jpath.len > 0) gpa.free(jpath);
    if (jpath.len > 0) {
        if (std.Io.Dir.readFileAlloc(.cwd(), io, jpath, gpa, .unlimited) catch null) |content| {
            defer gpa.free(content);
            if (parseSearchJson(index_alloc, content, false) catch null) |pkgs| {
                index_cache = pkgs;
                return pkgs;
            }
        }
    }

    // Cache miss: build the full index. ".*" matches the whole catalog.
    output.searchIndexBuilding();
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "search", "nixpkgs", ".*", "--json", "--no-update-lock-file" },
    }) catch {
        errors.error_info.setSuggestion("run nix-channel --update and try again", .{});
        return error.SearchFailed;
    };
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (isSearchUnfreeError(result.stderr)) {
                var env = try environ.clone(gpa);
                defer env.deinit();
                try env.put("NIXPKGS_ALLOW_UNFREE", "1");
                const r2 = std.process.run(gpa, io, .{
                    .argv = &.{ "nix", "search", "nixpkgs", ".*", "--json", "--no-update-lock-file", "--impure" },
                    .environ_map = &env,
                }) catch return error.SearchFailed;
                defer gpa.free(r2.stderr);
                defer gpa.free(r2.stdout);
                switch (r2.term) {
                    .exited => |c| if (c != 0) return error.SearchFailed,
                    else => return error.SearchFailed,
                }
                const pkgs = try parseSearchJson(index_alloc, r2.stdout, true);
                index_cache = pkgs;
                persistIndex(io, jpath, r2.stdout);
                saveBinIndex(io, bpath, pkgs);
                return pkgs;
            }
            return error.SearchFailed;
        },
        else => return error.SearchFailed,
    }
    const pkgs = try parseSearchJson(index_alloc, result.stdout, false);
    index_cache = pkgs;

    persistIndex(io, jpath, result.stdout);
    saveBinIndex(io, bpath, pkgs);
    return pkgs;
}

// Write the raw nix search JSON to the cache file (best-effort).
fn persistIndex(io: std.Io, path: []const u8, raw: []const u8) void {
    if (path.len == 0) return;
    const file = std.Io.Dir.createFile(.cwd(), io, path, .{}) catch return;
    defer file.close(io);
    file.writePositionalAll(io, raw, 0) catch {};
}

// ─── Compact text index format ─────────────────────────────────────────────
// One package per line, fields separated by the unit separator byte (0x1f),
// which cannot appear in nix attribute names, versions, or descriptions:
//
//   <attr>\x1f<pname>\x1f<version>\x1f<description>\x1f<unfree:0|1>\n
//
// This loads in microseconds vs re-parsing the 18MB JSON, and uses only plain
// byte I/O (no uncertain int-serialization APIs).

fn saveBinIndex(io: std.Io, path: []const u8, pkgs: []const types.NixPackage) void {
    if (path.len == 0) return;
    const file = std.Io.Dir.createFile(.cwd(), io, path, .{}) catch return;
    defer file.close(io);
    var off: u64 = 0;
    for (pkgs) |p| {
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}\n", .{
            p.attr, p.pname, p.version, p.description, @intFromBool(p.unfree),
        }) catch continue;
        file.writePositionalAll(io, line, off) catch return;
        off += line.len;
    }
}

fn loadBinIndex(io: std.Io, path: []const u8) ![]types.NixPackage {
    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, path, index_alloc, .unlimited);
    if (content.len == 0) return error.InvalidFormat;
    var pkgs: std.ArrayList(types.NixPackage) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, 0x1f);
        const attr = fields.next() orelse continue;
        const pname = fields.next() orelse continue;
        const version = fields.next() orelse continue;
        const description = fields.next() orelse continue;
        const unfree_str = fields.next() orelse "0";
        const unfree = std.mem.eql(u8, unfree_str, "1");
        try pkgs.append(index_alloc, .{
            .attr = attr,
            .pname = pname,
            .version = version,
            .description = description,
            .unfree = unfree,
        });
    }
    return pkgs.toOwnedSlice(index_alloc);
}

// Substring-filter the in-memory index for a query. Matches attr, pname, and
// description. Case-insensitive. The returned slice is allocated with `allocator`
// (strings are borrowed from the long-lived index, so only the slice is freed).
fn filterIndex(allocator: std.mem.Allocator, index: []types.NixPackage, query: []const u8) ![]types.NixPackage {
    var out: std.ArrayList(types.NixPackage) = .empty;
    for (index) |pkg| {
        if (matchesQuery(pkg, query)) {
            try out.append(allocator, pkg);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn matchesQuery(pkg: types.NixPackage, query: []const u8) bool {
    return containsInsensitive(pkg.attr, query) or
        containsInsensitive(pkg.pname, query) or
        containsInsensitive(pkg.description, query);
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

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
    // Serve from the persistent in-memory/on-disk index — instant per-keystroke,
    // no re-evaluation of nixpkgs. The index is keyed by nixpkgs revision.
    const index = loadOrBuildIndex(gpa, io, environ) catch return error.SearchFailed;
    return filterIndex(gpa, index, query);
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
