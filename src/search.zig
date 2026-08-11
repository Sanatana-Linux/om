// search.zig — inline TUI widget, no alternate screen
// Raw terminal mode for interactive key handling (POSIX: linux + macos).
//
// The widget ALWAYS occupies exactly WIDGET_LINES physical rows. Every line it
// draws is truncated to fit WIDGET_WIDTH columns so nothing ever wraps to a
// second row — a wrapped line would break cursorUp(WIDGET_LINES), and each
// re-render would drift the cursor further down, piling up garbage. All the
// text is clamped here, never downstream.
//
// Both dimensions are read from the terminal at startup (TIOCGWINSZ) so the
// widget fills the screen: more result rows on a tall terminal, wider columns
// on a wide one. Falls back to sensible defaults when the size can't be read.
const std = @import("std");
const types = @import("types.zig");
const output = @import("output.zig");
const api = @import("api.zig");
const rawterm = @import("rawterm.zig");

const DEFAULT_LINES: usize = 18;
const DEFAULT_WIDTH: usize = 80;
const MIN_LINES: usize = 10;
const MIN_WIDTH: usize = 40;
const STDIN_FD = rawterm.STDIN_FD;

// Widget layout budget, in rows, excluding the result list and detail pane:
// header(1) + blank(1) + rule(1) + blank(1) + controls(1). Everything else is
// split between the result rows and the detail pane so the widget always sums
// to exactly WIDGET_LINES.
const FIXED_LINES: usize = 5;
const MIN_RESULT_ROWS: usize = 3;
const MIN_DETAIL_LINES: usize = 4;

// Set from the terminal size at startup (see detectSize). Mutable globals so
// the render loop and cursor arithmetic all agree on one value.
var WIDGET_LINES: usize = DEFAULT_LINES;
var WIDGET_WIDTH: usize = DEFAULT_WIDTH;
var RESULT_ROWS: usize = 5;
var DETAIL_LINES: usize = MIN_DETAIL_LINES;

// Read the terminal's row/column count via TIOCGWINSZ. On any failure (not a
// tty, ioctl error, absurdly small window) fall back to the defaults.
fn detectSize(io: std.Io) void {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return;
    if (result.device_io_control < 0) return;
    if (ws.row > 0 and ws.row >= MIN_LINES) WIDGET_LINES = ws.row;
    if (ws.col > 0 and ws.col >= MIN_WIDTH) WIDGET_WIDTH = ws.col;
    // The result list occupies 3/4 of the widget height; the detail pane gets
    // the remaining rows. RESULT_ROWS is capped so the detail pane keeps at
    // least MIN_DETAIL_LINES (room for the wrapped description + attr row) when
    // the terminal is tall enough to fit it, and floored at MIN_RESULT_ROWS on
    // very short terminals. On a terminal too short to hold both minimums the
    // pane simply shrinks below its minimum — nothing underflows because
    // WIDGET_LINES is always >= MIN_LINES.
    const desired: usize = (WIDGET_LINES * 3) / 4;
    const max_for_detail: usize = WIDGET_LINES -| (FIXED_LINES + MIN_DETAIL_LINES);
    RESULT_ROWS = @max(MIN_RESULT_ROWS, @min(desired, max_for_detail));
    DETAIL_LINES = WIDGET_LINES - (FIXED_LINES + RESULT_ROWS);
}

// Truncate `s` to fit `width` columns (best-effort UTF-8-safe cut at a safe
// boundary — nix metadata is ASCII in practice, so a byte cut is fine).
fn clamp(s: []const u8, width: usize) []const u8 {
    if (s.len <= width) return s;
    if (width == 0) return "";
    return s[0..width];
}

// Wrap `s` to `width` columns on word boundaries, writing each line through
// `output.p`. A word wider than `width` is hard-broken so the row still fits and
// never spills onto a second physical row. `indent` is a literal prefix printed
// before every line (the 3-space list/detail gutter). At most `max_lines` lines
// are emitted — extra content is dropped and the caller pads with blanks — and
// the number of lines actually emitted is returned.
fn printWrapped(indent: []const u8, s: []const u8, width: usize, max_lines: usize) usize {
    var line_start: usize = 0; // byte index of the current line's first char
    var last_space: ?usize = null; // index of the most recent wrap-capable space
    var col: usize = 0; // columns consumed on the current line
    var lines_out: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\n') {
            lines_out += 1;
            if (lines_out >= max_lines) return lines_out;
            output.p("{s}{s}{s}\n", .{ indent, clamp(s[line_start..i], width), output.C_RESET });
            i += 1;
            line_start = i;
            last_space = null;
            col = 0;
            continue;
        }
        if (c == ' ') last_space = i;
        col += 1;
        if (col > width) {
            const wrap_at = if (last_space) |ls| (if (ls < i) ls else null) else null;
            const end = wrap_at orelse line_start + width;
            lines_out += 1;
            if (lines_out >= max_lines) return lines_out;
            output.p("{s}{s}{s}\n", .{ indent, clamp(s[line_start..end], width), output.C_RESET });
            line_start = if (wrap_at) |ls| ls + 1 else end;
            last_space = null;
            col = i + 1 - line_start;
        }
    }
    // Trailing partial line (no newline at the end).
    if (line_start < s.len) {
        lines_out += 1;
        if (lines_out > max_lines) return max_lines;
        output.p("{s}{s}{s}\n", .{ indent, clamp(s[line_start..s.len], width), output.C_RESET });
    }
    return lines_out;
}

// Emit `n` blank, cleared rows. Used to pad the widget to exactly WIDGET_LINES
// so the cursor-up count in the key loop always lines up with what was drawn.
fn emitBlanks(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        output.raw(output.C_CLEAR_EOL ++ "\n");
    }
}

// Debounce window: a keystroke defers the nix search until typing pauses this
// long. nix search is synchronous and blocks the widget for ~1s, so the window
// must be long enough that a normal between-keystroke pause doesn't trigger it —
// it should only fire once you've actually stopped typing.
const DEBOUNCE_MS: i64 = 500;

// Milliseconds elapsed since `since` on the monotonic (awake) clock. std has no
// milliTimestamp in 0.16; this mirrors the Io.Clock pattern used in apply().
fn elapsedMs(io: std.Io, since: std.Io.Timestamp) i64 {
    const ns = @max(0, since.untilNow(io, .awake).toNanoseconds());
    return @intCast(@divFloor(ns, 1_000_000));
}

// What the detail pane shows for the selected package. Tab toggles between the
// collapsed (description) view and the expanded meta view; the latter is fetched
// on demand, so it passes through loading and (on eval failure) unavailable.
const Detail = union(enum) {
    collapsed,
    loading,
    unavailable,
    meta: api.PkgMeta,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    initial_query: []const u8,
    mode: Mode,
    environ: *const std.process.Environ.Map,
) !?types.NixPackage {
    // Non-interactive fallback: when stdin isn't a terminal (piped, scripted,
    // CI), print plain results and return instead of the raw-mode widget, which
    // needs a real tty and would block waiting for keys.
    if (!stdinIsTty(io)) return runPlain(gpa, io, initial_query, mode, environ);

    var saved: std.posix.termios = undefined;
    try rawterm.rawModeEnable(STDIN_FD, &saved);
    defer rawterm.rawModeDisable(STDIN_FD, saved);

    // Size the widget to the terminal before the first render.
    detectSize(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var query_buf: [256]u8 = undefined;
    var query_len: usize = @min(initial_query.len, query_buf.len - 1);
    @memcpy(query_buf[0..query_len], initial_query[0..query_len]);

    var packages: []types.NixPackage = &.{};
    var opts: []api.NixOption = &.{};
    var selection: usize = 0;

    // Expanded detail (Tab): the selected package's meta, fetched on demand into
    // its own arena and cached by attr so re-visiting is instant. Kept separate
    // from the search arena, which is reset on every new search.
    var expanded = false;
    var meta_arena = std.heap.ArenaAllocator.init(gpa);
    defer meta_arena.deinit();
    var meta: ?api.PkgMeta = null;
    var meta_attr: []const u8 = "";

    // Initial search
    _ = arena.reset(.free_all);
    packages = doSearch(arena.allocator(), io, query_buf[0..query_len], mode, &opts, environ);

    // Initial render (prints WIDGET_LINES lines)
    renderWidget(query_buf[0..query_len], packages, opts, selection, mode, false, .collapsed);
    output.flush();

    // Key loop with debounced search. A keystroke marks the query dirty and
    // stamps the time; the nix search fires only once typing pauses for
    // DEBOUNCE_MS. Stale results stay on screen until the new search returns, so
    // there is no blank flash mid-typing.
    var chosen: ?types.NixPackage = null;
    var query_dirty = false;
    var query_changed_at = std.Io.Clock.awake.now(io);
    loop: while (true) {
        // Block until a key arrives, unless a search is pending — then wake when
        // the debounce window closes so we can fire it.
        var timeout_ms: i32 = -1;
        if (query_dirty) {
            const remaining = DEBOUNCE_MS - elapsedMs(io, query_changed_at);
            timeout_ms = if (remaining <= 0) 0 else @intCast(remaining);
        }

        var pfd = [_]std.posix.pollfd{.{ .fd = STDIN_FD, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, timeout_ms) catch 0;

        if (ready == 0) {
            // Poll timed out. If no search is pending, nothing changed — keep waiting.
            if (!(query_dirty and elapsedMs(io, query_changed_at) >= DEBOUNCE_MS)) continue;
            query_dirty = false;
            // Paint "searching..." over the stale results before the blocking nix
            // search, so the ~1s pause reads as progress, not a freeze.
            output.cursorUp(WIDGET_LINES);
            renderWidget(query_buf[0..query_len], packages, opts, selection, mode, true, .collapsed);
            output.flush();

            _ = arena.reset(.free_all);
            packages = doSearch(arena.allocator(), io, query_buf[0..query_len], mode, &opts, environ);
            // New result set: reset to the top and drop cached meta (it belonged to
            // the previous results). Navigating during the window could otherwise
            // leave selection past the new end and renderWidget would index OOB.
            selection = 0;
            meta = null;
            // fall through to the common render below
        } else {
            var buf: [4]u8 = undefined;
            const n = std.posix.read(STDIN_FD, &buf) catch break;
            if (n == 0) break;

            // The query is a live text field, so every printable key types into it —
            // single-letter actions would collide with package names (the 'i' in
            // "ripgrep" must not trigger install). Only non-text keys act: Enter
            // selects, Tab expands detail, arrows navigate, Esc cancels.
            if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
                switch (buf[2]) {
                    'A' => if (selection > 0) { selection -= 1; }, // up
                    'B' => if (selection + 1 < resultCount(packages, opts, mode)) { selection += 1; }, // down
                    else => {},
                }
            } else switch (buf[0]) {
                0x1b => break :loop, // Esc: cancel (chosen stays null)
                '\t' => expanded = !expanded, // Tab: toggle package detail
                '\r', '\n' => { // Enter: select the highlighted package
                    if (mode == .packages and packages.len > selection) {
                        chosen = packages[selection];
                    }
                    break :loop;
                },
                127, 8 => { // backspace
                    if (query_len > 0) {
                        query_len -= 1;
                        query_dirty = true;
                        query_changed_at = std.Io.Clock.awake.now(io);
                        selection = 0;
                    }
                },
                else => |ch| {
                    if (ch >= 32 and ch < 127 and query_len < query_buf.len - 1) {
                        query_buf[query_len] = ch;
                        query_len += 1;
                        query_dirty = true;
                        query_changed_at = std.Io.Clock.awake.now(io);
                        selection = 0;
                    }
                },
            }
        }

        // Common render after a search or a key. When expanded, resolve the detail
        // pane by fetching the selected package's meta on demand (blocking eval),
        // painting a "loading" frame first and caching by attr so re-visiting is
        // instant.
        const count = resultCount(packages, opts, mode);
        const sel = if (count == 0) 0 else @min(selection, count - 1);
        var detail: Detail = .collapsed;
        if (expanded and mode == .packages and count > 0) {
            const cur = packages[sel].attr;
            if (meta == null or !std.mem.eql(u8, meta_attr, cur)) {
                output.cursorUp(WIDGET_LINES);
                renderWidget(query_buf[0..query_len], packages, opts, selection, mode, false, .loading);
                output.flush();
                _ = meta_arena.reset(.free_all);
                meta_attr = meta_arena.allocator().dupe(u8, cur) catch "";
                meta = api.packageMeta(meta_arena.allocator(), io, cur);
            }
            detail = if (meta) |mm| Detail{ .meta = mm } else Detail.unavailable;
        }
        output.cursorUp(WIDGET_LINES);
        renderWidget(query_buf[0..query_len], packages, opts, selection, mode, false, detail);
        output.flush();
    }

    // Clear the widget area
    output.cursorUp(WIDGET_LINES);
    var i: usize = 0;
    while (i < WIDGET_LINES) : (i += 1) {
        output.raw(output.C_CLEAR_EOL ++ "\n");
    }
    output.cursorUp(WIDGET_LINES);
    output.flush();

    // The chosen package's strings live in the search arena, which deinits as this
    // function returns — dupe into the caller's allocator so it survives.
    if (chosen) |pkg| return dupePackage(gpa, pkg);
    return null;
}

fn dupePackage(gpa: std.mem.Allocator, pkg: types.NixPackage) types.NixPackage {
    return .{
        .attr = gpa.dupe(u8, pkg.attr) catch "",
        .pname = gpa.dupe(u8, pkg.pname) catch "",
        .version = gpa.dupe(u8, pkg.version) catch "",
        .description = gpa.dupe(u8, pkg.description) catch "",
    };
}

pub const Mode = enum { packages, options };

fn doSearch(arena: std.mem.Allocator, io: std.Io, query: []const u8, mode: Mode, opts: *[]api.NixOption, environ: *const std.process.Environ.Map) []types.NixPackage {
    // An empty query matches the entire catalog (100k+ rows) — a multi-second
    // fetch that would freeze the widget. Show nothing until there's a query.
    if (std.mem.trim(u8, query, " \t").len == 0) {
        opts.* = &.{};
        return &.{};
    }
    switch (mode) {
        .packages => {
            const packages: []types.NixPackage = api.searchPackages(arena, io, environ, query) catch &.{};
            sanitizeDescriptions(arena, packages);
            return packages;
        },
        .options => {
            const options: []api.NixOption = api.searchOptions(arena, io, query) catch &.{};
            sanitizeOptionDescriptions(arena, options);
            opts.* = options;
            return &.{};
        },
    }
}

// nix search's JSON descriptions come from nixpkgs/NixOS module metadata, which
// upstream authors control — a malicious description could otherwise smuggle
// escape sequences into both the TUI widget and the plain (piped) renderer,
// since both read straight from this shared result set (NINA-016). pname/attr
// are Nix identifiers and version strings are not free text, so only the
// free-form description needs sanitizing.
fn sanitizeDescriptions(arena: std.mem.Allocator, packages: []types.NixPackage) void {
    for (packages) |*pkg| {
        pkg.description = output.sanitize(arena, pkg.description) catch pkg.description;
    }
}

fn sanitizeOptionDescriptions(arena: std.mem.Allocator, options: []api.NixOption) void {
    for (options) |*opt| {
        opt.description = output.sanitize(arena, opt.description) catch opt.description;
    }
}

fn resultCount(packages: []types.NixPackage, opts: []api.NixOption, mode: Mode) usize {
    return switch (mode) {
        .packages => packages.len,
        .options => opts.len,
    };
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

// Plain, non-interactive rendering for non-tty stdin. Same pink :: header and
// result count the widget shows, then one line per result; no cursor control.
fn runPlain(gpa: std.mem.Allocator, io: std.Io, query: []const u8, mode: Mode, environ: *const std.process.Environ.Map) !?types.NixPackage {
    // An empty query matches the entire catalog (100k+ rows); refuse it cleanly.
    if (std.mem.trim(u8, query, " \t").len == 0) {
        output.searchEmptyQuery();
        output.flush();
        return null;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var opts: []api.NixOption = &.{};
    const packages = doSearch(arena.allocator(), io, query, mode, &opts, environ);
    const count = resultCount(packages, opts, mode);
    const mode_str = if (mode == .packages) "nixpkgs" else "options";
    output.searchPlainHeader(mode_str, query, count);
    if (count == 0) {
        output.searchPlainNoResults();
        output.flush();
        return null;
    }
    switch (mode) {
        // unfree=false: per-result meta.unfree would need an eval per package (too
        // slow for the list); the TUI detail pane is the place to surface it.
        .packages => for (packages) |pkg| output.searchPlainPackage(pkg.pname, pkg.version, pkg.description, false),
        .options => for (opts) |opt| output.searchPlainOption(opt.name, opt.type_str),
    }
    // NUR packages live in a separate flake and never appear in nixpkgs results —
    // point scripted users at the NUR one-liner instead of leaving them to wonder.
    if (mode == .packages) output.searchNurNote(query);
    output.flush();
    return null;
}

// A key hint with dim brackets and a pink letter: dim '[', pink label, dim ']'.
// Comptime-built so it's a plain string literal — the widget always renders raw
// ANSI (it only runs on a real tty).
fn keyHint(comptime label: []const u8) []const u8 {
    return output.C_DIM ++ "[" ++ output.C_RESET ++ output.C_PINK ++ label ++ output.C_RESET ++ output.C_DIM ++ "]" ++ output.C_RESET;
}

fn renderWidget(query: []const u8, packages: []types.NixPackage, opts: []api.NixOption, selection: usize, mode: Mode, searching: bool, detail: Detail) void {
    const count = resultCount(packages, opts, mode);
    const CLR = output.C_CLEAR_EOL;
    const RST = output.C_RESET;
    const PKN = output.C_PINK;
    const BLD = output.C_BOLD;
    const DIM = output.C_DIM;
    const CYN = output.C_CYAN;

    // Clamp to the current result count: a caller could hand us a selection from a
    // larger, now-replaced result set. Never index past the end.
    const sel = if (count == 0) 0 else @min(selection, count - 1);

    // Line 1: header. While the (blocking) search runs, show "searching..." so the
    // pause reads as work-in-progress, not a frozen widget.
    output.raw(CLR);
    const mode_str = if (mode == .packages) "nixpkgs" else "options";
    if (searching) {
        output.p("{s}:: {s}search {s} {s}  {s}searching...{s}\n", .{
            PKN, RST, mode_str, clamp(query, WIDGET_WIDTH -| 24), DIM, RST,
        });
    } else {
        output.p("{s}:: {s}search {s} {s}  {s}{d} results{s}\n", .{
            PKN, RST, mode_str, clamp(query, WIDGET_WIDTH -| 24), DIM, count, RST,
        });
    }

    // Line 2: blank
    output.raw(CLR ++ "\n");

    // Lines 3-7: results (up to RESULT_ROWS), scrolled so selection stays visible
    const scroll: usize = if (sel >= RESULT_ROWS) sel - RESULT_ROWS + 1 else 0;
    var i: usize = 0;
    while (i < RESULT_ROWS) : (i += 1) {
        const idx = scroll + i;
        output.raw(CLR);
        if (idx < count) {
            const selected = (idx == sel);
            switch (mode) {
                .packages => {
                    const pkg = packages[idx];
                    const marker = if (selected) PKN ++ "> " ++ RST else "  ";
                    const name_pre = if (selected) PKN ++ BLD else "";
                    const name_suf = if (selected) RST else "";
                    // Every field is clamped so the row never wraps.
                    const name = clamp(pkg.pname, 22);
                    const ver = clamp(pkg.version, 12);
                    const desc = clamp(pkg.description, WIDGET_WIDTH -| 46);
                    output.p("   {s}{s}{s}{s}   {s}{s}{s}   {s}\n", .{ marker, name_pre, name, name_suf, CYN, ver, RST, desc });
                },
                .options => {
                    const opt = opts[idx];
                    const marker = if (selected) PKN ++ "> " ++ RST else "  ";
                    const name = clamp(opt.name, WIDGET_WIDTH -| 20);
                    const typ = clamp(opt.type_str, 24);
                    output.p("   {s}{s}   {s}{s}{s}\n", .{ marker, name, DIM, typ, RST });
                },
            }
        } else {
            output.raw("\n");
        }
    }

    // Line 8: horizontal rule separating the result list from the detail pane.
    output.raw(CLR);
    var rule_buf: [256]u8 = undefined;
    const rule_len = @min(WIDGET_WIDTH -| 4, rule_buf.len);
    // "─" is U+2500, encoded as the 3-byte UTF-8 sequence E2 94 80.
    var ri: usize = 0;
    while (ri + 3 <= rule_len) : (ri += 3) {
        rule_buf[ri] = 0xE2;
        rule_buf[ri + 1] = 0x94;
        rule_buf[ri + 2] = 0x80;
    }
    output.p("   {s}{s}{s}\n", .{ DIM, rule_buf[0..ri], RST });

    // Detail pane: selected package/option. Every arm emits exactly
    // DETAIL_LINES rows (wrapped content + blanks) so the widget stays
    // WIDGET_LINES tall and the cursor-up count in the key loop stays correct.
    const GUTTER = "   ";
    if (count > 0 and mode == .packages) {
        const pkg = packages[sel];
        // Row 0: name + version.
        output.raw(CLR);
        output.p("{s}{s}{s}{s}{s}  {s}{s}{s}\n", .{ GUTTER, PKN, BLD, clamp(pkg.pname, 22), RST, CYN, clamp(pkg.version, 12), RST });
        var used: usize = 1;
        switch (detail) {
            .collapsed => {
                // Rows 1..n-1: description wrapped on word boundaries across the
                // remaining detail rows (leaving one for the attr line).
                const desc = printWrapped(GUTTER, pkg.description, WIDGET_WIDTH -| GUTTER.len, DETAIL_LINES - 2);
                used += desc;
            },
            .loading => {
                output.raw(CLR);
                output.p("{s}{s}loading details...{s}\n", .{ GUTTER, DIM, RST });
                used += 1;
            },
            .unavailable => {
                output.raw(CLR);
                output.p("{s}{s}details unavailable{s}\n", .{ GUTTER, DIM, RST });
                used += 1;
            },
            .meta => |m| {
                const home = clamp(if (m.homepage.len > 0) m.homepage else "—", WIDGET_WIDTH -| 16);
                const lic = clamp(if (m.license.len > 0) m.license else "—", WIDGET_WIDTH -| 16);
                output.raw(CLR);
                output.p("{s}{s}{s:<8}{s}{s}{s}{s}\n", .{ GUTTER, DIM, "home", RST, CYN, home, RST });
                output.raw(CLR);
                output.p("{s}{s}{s:<8}{s}{s}\n", .{ GUTTER, DIM, "license", RST, lic });
                used += 2;
            },
        }
        // Last row: attr (kept to one line so it never scrolls away).
        if (used < DETAIL_LINES) {
            output.raw(CLR);
            output.p("{s}{s}attr{s}  {s}{s}{s}\n", .{ GUTTER, DIM, RST, CYN, clamp(pkg.attr, WIDGET_WIDTH -| 12), RST });
            used += 1;
        }
        // Pad any remaining detail rows so the pane is exactly DETAIL_LINES tall.
        emitBlanks(DETAIL_LINES - used);
    } else if (count > 0 and mode == .options) {
        const opt = opts[sel];
        output.raw(CLR);
        output.p("{s}{s}  {s}{s}{s}\n", .{ GUTTER, clamp(opt.name, WIDGET_WIDTH -| 6), DIM, clamp(opt.type_str, 24), RST });
        var used: usize = 1;
        used += printWrapped(GUTTER, opt.description, WIDGET_WIDTH -| GUTTER.len, DETAIL_LINES - 1);
        emitBlanks(DETAIL_LINES - used);
    } else {
        emitBlanks(DETAIL_LINES);
    }

    // Blank row separating the detail pane from the controls.
    output.raw(CLR ++ "\n");

    // Controls + padding to reach WIDGET_LINES.
    output.raw(CLR);
    if (mode == .packages) {
        output.p("{s}{s} install  {s} info  {s}[up/down]{s} nav  {s} cancel\n", .{
            GUTTER, keyHint("enter"), keyHint("tab"), DIM, RST, keyHint("esc"),
        });
    } else {
        output.p("{s}{s}[up/down]{s} nav  {s} cancel\n", .{ GUTTER, DIM, RST, keyHint("esc") });
    }
    // Padding to reach WIDGET_LINES. Layout budget so far: header(1) + blank(1)
    // + RESULT_ROWS + rule(1) + DETAIL_LINES + blank(1) + controls(1) =
    // FIXED_LINES + RESULT_ROWS + DETAIL_LINES = WIDGET_LINES, so this loop only
    // pads for the default-size fallback when detectSize never ran.
    const drawn = FIXED_LINES + RESULT_ROWS + DETAIL_LINES;
    if (drawn < WIDGET_LINES) emitBlanks(WIDGET_LINES - drawn);
}

// Raw mode enable/disable, including signal-safe restoration on
// SIGINT/SIGTERM/SIGHUP, now lives in rawterm.zig — shared with man.zig
// (NINA-014).
