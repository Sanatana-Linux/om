const std = @import("std");

// ─── Public error types ───────────────────────────────────────────────────────

pub const NinaError = error{
    PackageNotFound,
    MachineNotFound,
    GenerationNotFound,
    ConfigNotFound,
    ConfigParseError,
    BuildFailed,
    SshFailed,
    SearchFailed,
    NetworkError,
    OutOfMemory,
    ProcessFailed,
    Internal,
    FileNotFound,
    AccessDenied,
    SystemResources,
    Unexpected,
    NotImplemented,
};

// ─── ErrorInfo (used for non-build errors) ───────────────────────────────────

pub var error_info: ErrorInfo = .{};

pub const ErrorInfo = struct {
    message: [512]u8 = undefined,
    message_len: usize = 0,
    detail: [512]u8 = undefined,
    detail_len: usize = 0,
    suggestion: [256]u8 = undefined,
    suggestion_len: usize = 0,

    pub fn setMessage(self: *ErrorInfo, comptime fmt: []const u8, args: anytype) void {
        const r = std.fmt.bufPrint(&self.message, fmt, args) catch return;
        self.message_len = r.len;
    }

    pub fn setDetail(self: *ErrorInfo, comptime fmt: []const u8, args: anytype) void {
        const r = std.fmt.bufPrint(&self.detail, fmt, args) catch return;
        self.detail_len = r.len;
    }

    pub fn setSuggestion(self: *ErrorInfo, comptime fmt: []const u8, args: anytype) void {
        const r = std.fmt.bufPrint(&self.suggestion, fmt, args) catch return;
        self.suggestion_len = r.len;
    }

    pub fn getMessage(self: *const ErrorInfo) ?[]const u8 {
        if (self.message_len == 0) return null;
        return self.message[0..self.message_len];
    }

    pub fn getDetail(self: *const ErrorInfo) ?[]const u8 {
        if (self.detail_len == 0) return null;
        return self.detail[0..self.detail_len];
    }

    pub fn getSuggestion(self: *const ErrorInfo) ?[]const u8 {
        if (self.suggestion_len == 0) return null;
        return self.suggestion[0..self.suggestion_len];
    }

    pub fn reset(self: *ErrorInfo) void {
        self.message_len = 0;
        self.detail_len = 0;
        self.suggestion_len = 0;
    }
};

pub fn staticMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ConfigNotFound => "~/.config/om/config not found",
        error.ConfigParseError => "could not parse ~/.config/om/config",
        error.SearchFailed => "nix search failed",
        error.NetworkError => "network unavailable",
        error.OutOfMemory => "out of memory",
        error.ProcessFailed => "process failed",
        error.SshFailed => "ssh connection failed",
        error.MachineNotFound => "machine not found in config",
        error.PackageNotFound => "package not found",
        error.GenerationNotFound => "generation not found",
        error.BuildFailed => "build failed",
        error.NotImplemented => "not implemented yet",
        else => "internal error",
    };
}

// ─── Build stderr capture ─────────────────────────────────────────────────────
//
// nixosRebuildRun (and home manager commands) capture stderr into this buffer
// before returning so translateError can read it in reportError.

var build_stderr_buf: [65536]u8 = undefined;
var build_stderr_len: usize = 0;

pub fn setBuildStderr(stderr: []const u8) void {
    const n = @min(stderr.len, build_stderr_buf.len);
    @memcpy(build_stderr_buf[0..n], stderr[0..n]);
    build_stderr_len = n;
}

pub fn getBuildStderr() []const u8 {
    return build_stderr_buf[0..build_stderr_len];
}

// ─── TranslatedError ──────────────────────────────────────────────────────────

pub const TranslatedError = struct {
    title: []const u8,
    body: []const u8,
    // May contain multiple lines separated by '\n'. buildError prints the first
    // with "-> " and subsequent lines with "   " indentation.
    suggestion: []const u8,
    is_system: bool = false,
    // Dim location shown below body: "configuration.nix  line 47"
    location: ?[]const u8 = null,
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

// Return the single-quoted content at the first occurrence in s.
fn extractQuoted(s: []const u8) ?[]const u8 {
    const a = std.mem.indexOf(u8, s, "'") orelse return null;
    const b = std.mem.indexOfPos(u8, s, a + 1, "'") orelse return null;
    const v = s[a + 1 .. b];
    return if (v.len > 0) v else null;
}

// Return the first line in text that contains pattern.
fn lineWith(text: []const u8, pattern: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, pattern) != null) return line;
    }
    return null;
}

// Extract the innermost error: last "error: ..." line before "For full logs".
pub fn innermostError(text: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "error:")) last = t;
        if (std.mem.startsWith(u8, t, "For full logs")) break;
    }
    return last;
}

fn isUserPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/etc/nixos/") or
        std.mem.startsWith(u8, path, "/home/") or
        std.mem.startsWith(u8, path, "~");
}

fn justFilename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, path, "/")) |i| path[i + 1 ..] else path;
}

fn findLocationInLine(allocator: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const nix_pos = std.mem.indexOf(u8, line, ".nix:") orelse return null;
    const before = line[0 .. nix_pos + 4]; // includes ".nix"
    const rest = line[nix_pos + 5 ..]; // "47:3" or "47"
    const colon_or_end = std.mem.indexOf(u8, rest, ":") orelse rest.len;
    const line_num_str = rest[0..colon_or_end];
    if (line_num_str.len == 0 or line_num_str.len > 6) return null;
    for (line_num_str) |ch| if (ch < '0' or ch > '9') return null;

    // Extract the actual path from context (after " /" or after "(")
    const full_path = blk: {
        if (std.mem.indexOf(u8, before, " /")) |sp| break :blk before[sp + 1 ..];
        if (std.mem.indexOf(u8, before, "(")) |paren| break :blk before[paren + 1 ..];
        break :blk before;
    };

    const display = if (isUserPath(full_path)) full_path else justFilename(full_path);
    return std.fmt.allocPrint(allocator, "{s}  line {s}", .{ display, line_num_str }) catch null;
}

pub fn extractLocation(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (findLocationInLine(allocator, line)) |loc| return loc;
    }
    return null;
}

// Find a /nix/store/xxx.drv path in stderr for the "nix log" suggestion.
fn extractDrvPath(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "/nix/store/")) |start| {
            const after = line[start..];
            if (std.mem.indexOf(u8, after, ".drv")) |end| {
                return after[0 .. end + 4];
            }
        }
    }
    return null;
}

// ─── Layer 1: Known pattern matching ─────────────────────────────────────────
//
// 25 nixos-rebuild patterns + home manager patterns. First match wins.

pub fn matchKnownPattern(allocator: std.mem.Allocator, stderr: []const u8) ?TranslatedError {
    // ── nixos-rebuild patterns ────────────────────────────────────────────────

    if (std.mem.indexOf(u8, stderr, "undefined variable '") != null) {
        const var_name = blk: {
            if (lineWith(stderr, "undefined variable '")) |l| {
                const pos = std.mem.indexOf(u8, l, "undefined variable '") orelse break :blk "this package";
                break :blk extractQuoted(l[pos..]) orelse "this package";
            }
            break :blk "this package";
        };
        return .{
            .title = std.fmt.allocPrint(allocator, "'{s}' is not defined", .{var_name}) catch "package is not defined",
            .body = std.fmt.allocPrint(allocator, "nixpkgs doesn't know about '{s}'.", .{var_name}) catch "nixpkgs doesn't know about this package.",
            .suggestion = std.fmt.allocPrint(allocator, "om search {s}", .{var_name}) catch "om search",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "has been renamed to") != null) {
        const body = blk: {
            if (lineWith(stderr, "has been renamed to")) |l| {
                const old = extractQuoted(l) orelse break :blk "the package has a new name.";
                if (std.mem.indexOf(u8, l, "renamed to")) |rp| {
                    const new_name = extractQuoted(l[rp..]) orelse break :blk std.fmt.allocPrint(allocator, "'{s}' has a new name.", .{old}) catch "the package has a new name.";
                    break :blk std.fmt.allocPrint(allocator, "'{s}' has been renamed to '{s}'.", .{ old, new_name }) catch "the package has a new name.";
                }
                break :blk std.fmt.allocPrint(allocator, "'{s}' has a new name.", .{old}) catch "the package has a new name.";
            }
            break :blk "the package has been renamed.";
        };
        return .{
            .title = "package was renamed",
            .body = body,
            .suggestion = "update your config to use the new name",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "attribute '") != null and
        std.mem.indexOf(u8, stderr, "' missing") != null)
    {
        const attr = if (lineWith(stderr, "' missing")) |l| extractQuoted(l) orelse "this attribute" else "this attribute";
        return .{
            .title = std.fmt.allocPrint(allocator, "'{s}' not found", .{attr}) catch "attribute not found",
            .body = "this attribute doesn't exist in your nixpkgs version.",
            .suggestion = std.fmt.allocPrint(allocator, "check spelling or try: om search {s}", .{attr}) catch "om search",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "collision between") != null) {
        const is_hm = std.mem.indexOf(u8, stderr, "home-manager") != null;
        return .{
            .title = if (is_hm) "two home packages share a file" else "two packages share a file",
            .body = if (is_hm)
                "two home-manager packages are trying to provide the same file."
            else
                "two installed packages are trying to provide the same file.",
            .suggestion = "remove one of the conflicting packages",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "infinite recursion encountered") != null) {
        return .{
            .title = "circular reference in config",
            .body = "two options reference each other indefinitely.",
            .suggestion = "check your recent config edits",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "No space left on device") != null) {
        return .{
            .title = "disk is full",
            .body = "the nix store has no room to build.",
            .suggestion = "om clean",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "hash mismatch") != null) {
        return .{
            .title = "download checksum mismatch",
            .body = "the downloaded file doesn't match its expected hash.",
            .suggestion = "try again — this is usually temporary",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "cannot write lock file") != null) {
        return .{
            .title = "can't write flake.lock",
            .body = "the lock file can't be updated in this directory.",
            .suggestion = "run with --no-write-lock-file",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "SSL certificate") != null) {
        return .{
            .title = "ssl error",
            .body = "the connection couldn't be verified.",
            .suggestion = "check your network connection",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "permission denied") != null) {
        return .{
            .title = "permission denied",
            .body = "om needs elevated access for this operation.",
            .suggestion = "check that sudo is available",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "is not allowed by the 'allowed-uris'") != null) {
        return .{
            .title = "url not in allowed list",
            .body = "this fetch is blocked by nix's allowed-uris setting.",
            .suggestion = "add the url to nix.settings.allowed-uris in your config",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "top-level") != null and
        std.mem.indexOf(u8, stderr, "is not available") != null)
    {
        const pkg = if (lineWith(stderr, "is not available")) |l| extractQuoted(l) orelse "this package" else "this package";
        return .{
            .title = std.fmt.allocPrint(allocator, "'{s}' is not available", .{pkg}) catch "package is not available",
            .body = "this package doesn't exist in your current nixpkgs.",
            .suggestion = std.fmt.allocPrint(allocator, "om search {s}  to find the right name", .{pkg}) catch "om search",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "is marked as broken") != null) {
        const pkg = if (lineWith(stderr, "is marked as broken")) |l| extractQuoted(l) orelse "this package" else "this package";
        return .{
            .title = "package is marked broken",
            .body = std.fmt.allocPrint(allocator, "'{s}' is marked broken in nixpkgs.", .{pkg}) catch "this package is marked broken in nixpkgs.",
            .suggestion = std.fmt.allocPrint(allocator, "check if there's a working alternative: om search {s}", .{pkg}) catch "om search",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "requires unfree license") != null or
        std.mem.indexOf(u8, stderr, "has an unfree license") != null)
    {
        const pkg = blk: {
            if (lineWith(stderr, "unfree")) |l| break :blk extractQuoted(l) orelse "this package";
            break :blk "this package";
        };
        return .{
            .title = "package has an unfree license",
            .body = std.fmt.allocPrint(allocator, "'{s}' uses a license that nix won't install by default.", .{pkg}) catch "this package uses an unfree license.",
            .suggestion = "add nixpkgs.config.allowUnfree = true; to your config",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "sandbox violation") != null) {
        return .{
            .title = "sandbox access denied",
            .body = "a build tried to access something outside its sandbox.",
            .suggestion = "check the package derivation for network/filesystem access",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "output path") != null and
        std.mem.indexOf(u8, stderr, "already exists") != null)
    {
        return .{
            .title = "output path conflict",
            .body = "a store path from a previous failed build is in the way.",
            .suggestion = "om store gc  then try again",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "cannot connect to daemon") != null) {
        return .{
            .title = "nix daemon is not running",
            .body = "the nix daemon isn't available.",
            .suggestion = "sudo systemctl start nix-daemon",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "does not provide attribute") != null) {
        const attr = blk: {
            if (lineWith(stderr, "does not provide attribute")) |l| {
                if (std.mem.indexOf(u8, l, "provide attribute")) |pos| {
                    break :blk extractQuoted(l[pos..]) orelse "the requested output";
                }
            }
            break :blk "the requested output";
        };
        return .{
            .title = "flake attribute not found",
            .body = std.fmt.allocPrint(allocator, "'{s}' doesn't exist in this flake.", .{attr}) catch "the flake attribute doesn't exist.",
            .suggestion = "run om flake show  to see available outputs",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "is not valid") != null and
        std.mem.indexOf(u8, stderr, "/nix/store/") != null)
    {
        return .{
            .title = "store path is invalid",
            .body = "a referenced path doesn't exist in the store.",
            .suggestion = "om store repair",
            .is_system = true,
        };
    }

    if (std.mem.indexOf(u8, stderr, "missing input 'nixpkgs'") != null) {
        return .{
            .title = "nixpkgs input missing",
            .body = "the flake can't find its nixpkgs input.",
            .suggestion = "om flake update",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "getting status of") != null and
        std.mem.indexOf(u8, stderr, "flake.nix") != null)
    {
        return .{
            .title = "flake.nix not found",
            .body = "no flake.nix in this directory.",
            .suggestion = "om flake init  to create one",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "syntax error") != null and
        std.mem.indexOf(u8, stderr, "unexpected") != null)
    {
        return .{
            .title = "syntax error in config",
            .body = "there's a syntax error in your NixOS config.",
            .suggestion = "run om edit  to fix it",
            .is_system = false,
            .location = extractLocation(allocator, stderr),
        };
    }

    if (std.mem.indexOf(u8, stderr, "while evaluating") != null and
        std.mem.indexOf(u8, stderr, "configuration.nix") != null)
    {
        const inner = innermostError(stderr) orelse "evaluation failed";
        const body = if (std.mem.startsWith(u8, inner, "error: ")) inner[7..] else inner;
        return .{
            .title = "config evaluation failed",
            .body = body,
            .suggestion = "run om check  for details",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "type error") != null) {
        return .{
            .title = "type mismatch in config",
            .body = "a config option received a value of the wrong type.",
            .suggestion = "check the option type in the NixOS manual",
            .is_system = false,
            .location = extractLocation(allocator, stderr),
        };
    }

    if (std.mem.indexOf(u8, stderr, "does not match") != null and
        std.mem.indexOf(u8, stderr, "option") != null)
    {
        const opt = if (lineWith(stderr, "does not match")) |l| extractQuoted(l) orelse "this option" else "this option";
        return .{
            .title = "wrong value for option",
            .body = std.fmt.allocPrint(allocator, "'{s}' received an unexpected value.", .{opt}) catch "an option received an unexpected value.",
            .suggestion = "check the option documentation: man configuration.nix",
            .is_system = false,
        };
    }

    // "warning: the following units failed: svc.service"
    // switch-to-configuration exits 4 when one or more units fail to start.
    if (std.mem.indexOf(u8, stderr, "the following units failed:") != null) {
        const svc = blk: {
            if (lineWith(stderr, "the following units failed:")) |l| {
                if (std.mem.indexOf(u8, l, "failed:")) |p| {
                    const rest = std.mem.trim(u8, l[p + 7 ..], " \t");
                    if (rest.len > 0 and rest.len <= 80) break :blk rest;
                }
            }
            break :blk "a service";
        };
        return .{
            .title = "service failed after upgrade",
            .body = std.fmt.allocPrint(allocator, "{s} failed to start after activation.", .{svc}) catch "a service failed to start after activation.",
            .suggestion = std.fmt.allocPrint(allocator, "systemctl status {s}", .{svc}) catch "systemctl status <service>",
            .is_system = true,
        };
    }

    // ── home manager patterns ─────────────────────────────────────────────────

    if (std.mem.indexOf(u8, stderr, "The option") != null and
        std.mem.indexOf(u8, stderr, "does not exist") != null)
    {
        const opt = if (lineWith(stderr, "does not exist")) |l| extractQuoted(l) orelse "this option" else "this option";
        return .{
            .title = "unknown home-manager option",
            .body = std.fmt.allocPrint(allocator, "'{s}' is not a valid home-manager option.", .{opt}) catch "this option doesn't exist in home-manager.",
            .suggestion = "check the home-manager option name",
            .is_system = false,
        };
    }

    if (std.mem.indexOf(u8, stderr, "is used but not defined") != null) {
        const mod = if (lineWith(stderr, "is used but not defined")) |l| extractQuoted(l) orelse "a module" else "a module";
        return .{
            .title = "module not imported",
            .body = std.fmt.allocPrint(allocator, "'{s}' is used but not imported.", .{mod}) catch "a module is used but not imported.",
            .suggestion = "add the module import to your home.nix",
            .is_system = false,
        };
    }

    return null;
}

// ─── Layer 2: Structured extraction ──────────────────────────────────────────
//
// When no pattern matches, extract the innermost error from nix's nested output
// and present it with any available location information.

pub fn extractStructured(allocator: std.mem.Allocator, stderr: []const u8) ?TranslatedError {
    if (stderr.len == 0) return null;

    const inner = innermostError(stderr) orelse return null;
    if (inner.len == 0) return null;

    // Strip "error: " prefix, cap at 3 lines, skip store paths and note: lines.
    const raw_msg = if (std.mem.startsWith(u8, inner, "error: ")) inner[7..] else inner;
    const body = cleanExtractedBody(allocator, raw_msg);
    if (body.len == 0) return null;

    const loc = extractLocation(allocator, stderr);
    const drv = extractDrvPath(stderr);
    const suggestion = if (drv) |path|
        std.fmt.allocPrint(allocator, "om doctor  for a full diagnostic\nnix log {s}", .{path}) catch "om doctor  for a full diagnostic"
    else
        "om doctor  for a full diagnostic";

    return .{
        .title = "build failed",
        .body = body,
        .suggestion = suggestion,
        .is_system = true,
        .location = loc,
    };
}

fn cleanExtractedBody(allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (count >= 3) break;
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) continue;
        // Skip pure store paths and builder output lines
        if (std.mem.startsWith(u8, t, "/nix/store/")) continue;
        if (std.mem.startsWith(u8, t, "note:") and std.mem.indexOf(u8, t, "/nix/store/") != null) continue;
        if (std.mem.startsWith(u8, t, "> ")) continue;
        parts[count] = t;
        count += 1;
    }
    if (count == 0) return "";
    if (count == 1) return allocator.dupe(u8, parts[0]) catch "";
    return std.mem.join(allocator, "\n", parts[0..count]) catch "";
}

// ─── Layer 3: Graceful fallback ───────────────────────────────────────────────

pub fn fallback(allocator: std.mem.Allocator, stderr: []const u8) TranslatedError {
    const drv = extractDrvPath(stderr);
    const suggestion = if (drv) |path|
        std.fmt.allocPrint(allocator, "om doctor  for diagnostics\nnix log {s}", .{path}) catch "om doctor  for diagnostics"
    else
        "om doctor  for diagnostics";
    return .{
        .title = "build failed",
        .body = "something went wrong that om couldn't translate.",
        .suggestion = suggestion,
        .is_system = true,
    };
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn translateError(allocator: std.mem.Allocator, stderr: []const u8) TranslatedError {
    if (matchKnownPattern(allocator, stderr)) |t| return t;
    if (extractStructured(allocator, stderr)) |t| return t;
    return fallback(allocator, stderr);
}

// ─── Warning extraction ───────────────────────────────────────────────────────

const warning_translations = [_][2][]const u8{
    .{ "is too new", "nixpkgs version is ahead of your channel" },
    .{ "unknown setting", "unknown nix setting — check nix.conf" },
    .{ "Git tree", "uncommitted changes in your flake directory" },
    .{ "not writing modified lock file", "flake.lock is out of date — run om flake update" },
};

fn translateWarning(msg: []const u8) []const u8 {
    for (warning_translations) |pair| {
        if (std.mem.indexOf(u8, msg, pair[0]) != null) return pair[1];
    }
    return msg;
}

// Extract and translate warning lines from captured stderr.
// Caller owns the returned slice and each string within it.
pub fn extractWarnings(allocator: std.mem.Allocator, stderr: []const u8) ![][]const u8 {
    var warnings: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "warning:")) continue;
        const msg = std.mem.trim(u8, t[8..], " \t");
        if (msg.len == 0) continue;
        const translated = translateWarning(msg);
        try warnings.append(allocator, try allocator.dupe(u8, translated));
    }
    return warnings.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "layer 1: undefined variable" {
    const t = matchKnownPattern(std.testing.allocator, "error: undefined variable 'pkgs.notexist'");
    try std.testing.expect(t != null);
    defer std.testing.allocator.free(t.?.title);
    defer std.testing.allocator.free(t.?.body);
    defer std.testing.allocator.free(t.?.suggestion);
    try std.testing.expect(std.mem.indexOf(u8, t.?.title, "notexist") != null);
}

test "layer 1: disk full" {
    const t = matchKnownPattern(std.testing.allocator, "error: No space left on device");
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("disk is full", t.?.title);
    try std.testing.expect(t.?.is_system);
}

test "layer 1: unfree" {
    const t = matchKnownPattern(std.testing.allocator, "error: Package 'discord' has an unfree license");
    try std.testing.expect(t != null);
    defer std.testing.allocator.free(t.?.body);
    try std.testing.expectEqualStrings("package has an unfree license", t.?.title);
}

test "layer 1: no match returns null" {
    const t = matchKnownPattern(std.testing.allocator, "some unrecognized error text");
    try std.testing.expect(t == null);
}

test "layer 1: service activation failure" {
    const t = matchKnownPattern(std.testing.allocator, "warning: the following units failed: rtorrent.service\n" ++
        "Command 'systemd-run ...' returned non-zero exit status 4.");
    try std.testing.expect(t != null);
    defer std.testing.allocator.free(t.?.body);
    defer std.testing.allocator.free(t.?.suggestion);
    try std.testing.expectEqualStrings("service failed after upgrade", t.?.title);
    try std.testing.expect(std.mem.indexOf(u8, t.?.body, "rtorrent.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.?.suggestion, "rtorrent.service") != null);
}

test "layer 3: fallback always returns" {
    const t = fallback(std.testing.allocator, "");
    try std.testing.expectEqualStrings("build failed", t.title);
    try std.testing.expect(t.is_system);
}

test "translateError: falls through to fallback" {
    const t = translateError(std.testing.allocator, "unrecognized garbage stderr");
    try std.testing.expectEqualStrings("build failed", t.title);
}

test "staticMessage" {
    try std.testing.expectEqualStrings("~/.config/om/config not found", staticMessage(error.ConfigNotFound));
}

test "extractWarnings: translates known warnings" {
    const stderr = "warning: Git tree '/home/user/config' is dirty\nwarning: unknown setting 'foo'\n";
    const ws = try extractWarnings(std.testing.allocator, stderr);
    defer {
        for (ws) |w| std.testing.allocator.free(w);
        std.testing.allocator.free(ws);
    }
    try std.testing.expectEqual(@as(usize, 2), ws.len);
    try std.testing.expectEqualStrings("uncommitted changes in your flake directory", ws[0]);
    try std.testing.expectEqualStrings("unknown nix setting — check nix.conf", ws[1]);
}
