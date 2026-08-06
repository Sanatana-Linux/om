// output.zig — the only file that writes to stdout
// All ANSI codes live here. No raw escape sequences elsewhere.
const std = @import("std");
const types = @import("types.zig");
const nina_version = @import("version.zig");
const errors = @import("errors.zig");
const Io = std.Io;

// Color constants — all ANSI codes live here only
const PINK = "\x1b[38;2;255;183;197m";
const BOLD = "\x1b[1m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

// kaomoji constants — all kaomoji defined here, never inlined elsewhere. Rare
// and earned: each marks one genuine moment and never repeats in one output
// block. They are plain text, not ANSI, so they survive pipes and NO_COLOR.
const KAO_FACE = "(˶ᵔ ᵕ ᵔ˶)  "; // hello — her face
const KAO_COZY = "(っ˘ω˘ς)  "; // apply start
const KAO_EXCITED = "╰(*°▽°*)╯  "; // apply success after a failure this session
const KAO_GENTLE = "( ˘ᵕ˘ )  "; // back done
const KAO_CONTENT = "( ´ ∀ ` )  "; // clean freed
const KAO_HAPPY = "( ´ ▽ ` )  "; // doctor all clear / mood all good
const KAO_SLEEPY = "(˘ω˘ )  "; // try / develop exit
const KAO_READY = "( •̀ᴗ•́ )  "; // update start
const KAO_SAD = "(；ω；)  "; // network or ssh errors only — never user typos

// Exported for TUI use (search.zig references these to avoid \x1b in that file)
pub const C_PINK = PINK;
pub const C_BOLD = BOLD;
pub const C_GREEN = GREEN;
pub const C_YELLOW = YELLOW;
pub const C_RED = RED;
pub const C_CYAN = CYAN;
pub const C_DIM = DIM;
pub const C_RESET = RESET;
pub const C_CLEAR_EOL = "\x1b[K";
pub const C_CURSOR_UP_FMT = "\x1b[{d}A";

// Precomputed prefix strings
const HDR_C = PINK ++ ":: " ++ RESET;
const HDR_P = ":: ";
const STEP_C = "   " ++ DIM ++ "-> " ++ RESET;
const STEP_P = "   -> ";
const TEACH_C = "   " ++ DIM ++ "= " ++ RESET;
const TEACH_P = "   = ";
const ERR_C = PINK ++ ":: " ++ RED ++ "error:" ++ RESET ++ " ";
const ERR_P = ":: error: ";
const WARN_C = PINK ++ ":: " ++ YELLOW ++ "warning:" ++ RESET ++ " ";
const WARN_P = ":: warning: ";

var _fw: Io.File.Writer = undefined;
var _w: *Io.Writer = undefined;
var _io: Io = undefined;
var color_enabled: bool = true;
var teach_enabled: bool = false;
var auto_yes: bool = false;

// --- Build panel ---

pub const BuildPanel = struct {
    total: u32 = 0,
    completed: u32 = 0,
    total_mb: f32 = 0,
    active: [32]u8 = [_]u8{0} ** 32,
    active_len: usize = 0,
    mode: enum { fetching, building, activating } = .fetching,
    pulse_pos: u8 = 0,

    const BAR_WIDTH = 28;

    pub fn update(self: *BuildPanel, line: []const u8) void {
        // "these N paths will be fetched (X MiB download, Y MiB unpacked)"
        if (std.mem.indexOf(u8, line, "paths will be fetched") != null) {
            if (parseAfterWord(line, "these ")) |n_str| {
                if (std.fmt.parseInt(u32, n_str, 10) catch null) |n| self.total = n;
            }
            // "(X MiB download..."
            if (std.mem.indexOfScalar(u8, line, '(')) |pi| {
                const after = std.mem.trim(u8, line[pi + 1 ..], " \t");
                if (indexOfSpace(after)) |sp| {
                    if (std.fmt.parseFloat(f32, after[0..sp]) catch null) |mb| self.total_mb = mb;
                }
            }
            return;
        }

        // "copying path '/nix/store/...' from '...'" (nix 2.x substituter message)
        // older nix used "fetching path '...'" — match both for compatibility
        if (std.mem.indexOf(u8, line, "copying path '") != null or
            std.mem.indexOf(u8, line, "fetching path '") != null)
        {
            self.completed +|= 1;
            self.mode = .fetching;
            self.setActiveName(line, false);
            return;
        }

        // "building '/nix/store/...-name.drv'"
        if (std.mem.indexOf(u8, line, "building '") != null and
            std.mem.indexOf(u8, line, ".drv") != null)
        {
            self.mode = .building;
            self.setActiveName(line, true);
            return;
        }

        // "activating the configuration..."
        if (std.mem.indexOf(u8, line, "activating the configuration") != null or
            std.mem.indexOf(u8, line, "activating configuration") != null)
        {
            self.mode = .activating;
            if (self.total > 0) self.completed = self.total;
            const msg = "activating configuration...";
            const copy_len = @min(msg.len, self.active.len);
            @memcpy(self.active[0..copy_len], msg[0..copy_len]);
            self.active_len = copy_len;
            return;
        }
    }

    pub fn render(self: *BuildPanel) void {
        if (!color_enabled) return;

        // Up 2 lines to the name line (blank line is below header, name is next)
        p("\x1b[2A", .{});

        // Name line
        p("\r\x1b[K", .{});
        const name = self.active[0..self.active_len];
        switch (self.mode) {
            .fetching => p("   {s}fetching{s}  {s}{s}{s}", .{ c(DIM), c(RESET), c(CYAN), name, c(RESET) }),
            .building => p("   {s}building{s}  {s}{s}{s}", .{ c(DIM), c(RESET), c(YELLOW), name, c(RESET) }),
            .activating => p("   {s}{s}{s}", .{ c(GREEN), name, c(RESET) }),
        }
        p("\n", .{});

        // Bar line
        p("\r\x1b[K", .{});
        if (self.total == 0) {
            self.drawPulse();
        } else {
            self.drawCountedBar();
        }
        p("\n", .{});

        flush();
    }

    fn drawCountedBar(self: *BuildPanel) void {
        const filled: u32 = if (self.total > 0)
            @min(BAR_WIDTH, (self.completed * BAR_WIDTH) / self.total)
        else
            0;
        const empty: u32 = BAR_WIDTH - filled;

        const blk_color = switch (self.mode) {
            .fetching => CYAN,
            .building => YELLOW,
            .activating => GREEN,
        };

        p("   ", .{});
        if (filled > 0) {
            p("{s}", .{c(blk_color)});
            for (0..filled) |_| p("█", .{});
            p("{s}", .{c(RESET)});
        }
        if (empty > 0) {
            p("{s}", .{c(DIM)});
            for (0..empty) |_| p("░", .{});
            p("{s}", .{c(RESET)});
        }
        p("   {s}{d} / {d} paths{s}", .{ c(DIM), self.completed, self.total, c(RESET) });
        if (self.total_mb > 0) {
            const done_mb = self.total_mb * @as(f32, @floatFromInt(self.completed)) /
                @as(f32, @floatFromInt(@max(self.total, 1)));
            p("   {d:.1} MB / {d:.1} MB", .{ done_mb, self.total_mb });
        }
    }

    fn drawPulse(self: *BuildPanel) void {
        const PULSE_SIZE: u8 = 4;
        const blk_color = switch (self.mode) {
            .fetching => CYAN,
            .building => YELLOW,
            .activating => GREEN,
        };
        p("   ", .{});
        for (0..BAR_WIDTH) |i| {
            const pos: u8 = @intCast(i);
            const in_pulse = pos >= self.pulse_pos and pos < self.pulse_pos + PULSE_SIZE;
            if (in_pulse) {
                p("{s}█{s}", .{ c(blk_color), c(RESET) });
            } else {
                p("{s}░{s}", .{ c(DIM), c(RESET) });
            }
        }
        self.pulse_pos = (self.pulse_pos + 1) % BAR_WIDTH;
    }

    fn setActiveName(self: *BuildPanel, line: []const u8, is_drv: bool) void {
        const store = "/nix/store/";
        const idx = std.mem.indexOf(u8, line, store) orelse return;
        const after = line[idx + store.len ..];
        if (after.len < 33) return;
        var name = after[33..]; // skip 32-char hash + dash
        if (is_drv) {
            if (std.mem.endsWith(u8, name, ".drv")) name = name[0 .. name.len - 4];
        }
        // Trim trailing quote / whitespace
        name = std.mem.trimEnd(u8, name, "' \t\r\n");
        const copy_len = @min(name.len, self.active.len);
        @memcpy(self.active[0..copy_len], name[0..copy_len]);
        self.active_len = copy_len;
    }
};

fn parseAfterWord(line: []const u8, word: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, word) orelse return null;
    const after = line[idx + word.len ..];
    const end = indexOfSpace(after) orelse return null;
    return after[0..end];
}

fn indexOfSpace(s: []const u8) ?usize {
    for (s, 0..) |b, i| if (b == ' ' or b == '\t') return i;
    return null;
}

pub fn buildPanelInit() void {
    if (!color_enabled) return;
    p("\n\n\n", .{});
    flush();
}

pub fn buildPanelClear() void {
    if (!color_enabled) return;
    p("\n", .{});
    flush();
}

pub fn init(writer: *Io.Writer, io: std.Io, environ: *const std.process.Environ.Map, color_config: bool) void {
    _w = writer;
    _io = io;
    color_enabled = color_config and
        (std.Io.File.stdout().isTty(io) catch false) and
        !environ.contains("NO_COLOR");
}

pub fn setTeach(enabled: bool) void {
    teach_enabled = enabled;
}

// Set by --yes: bypass confirm() entirely for scripted/automated invocations
// that want the old prompts skipped on purpose, instead of by accident via a
// closed stdin. Does not affect confirmDefaultNo, which stays opt-in-only.
pub fn setAutoYes(enabled: bool) void {
    auto_yes = enabled;
}

pub fn flush() void {
    _w.flush() catch {};
}

// Whether ANSI color is active (tty + config + no NO_COLOR). Callers spawning
// child processes that colorize their own output use this to gate the child.
pub fn colorEnabled() bool {
    return color_enabled;
}

fn c(code: []const u8) []const u8 {
    return if (color_enabled) code else "";
}

fn hdr() []const u8 {
    return if (color_enabled) HDR_C else HDR_P;
}

fn step() []const u8 {
    return if (color_enabled) STEP_C else STEP_P;
}

fn teach_pfx() []const u8 {
    return if (color_enabled) TEACH_C else TEACH_P;
}

// Raw write — used by TUI
pub fn raw(bytes: []const u8) void {
    _w.writeAll(bytes) catch {};
}

// Formatted print — used by TUI for in-place rendering
pub fn p(comptime fmt: []const u8, args: anytype) void {
    _w.print(fmt, args) catch {};
}

pub fn cursorUp(n: usize) void {
    if (n > 0) p("\x1b[{d}A", .{n});
}

pub fn clearLine() void {
    p("\r\x1b[K", .{});
}

// --- Error and warning output ---

pub fn printError(message: []const u8, detail: ?[]const u8, suggestion: ?[]const u8) void {
    p("{s}{s}\n", .{ if (color_enabled) ERR_C else ERR_P, message });
    if (detail) |d| p("   {s}{s}{s}\n", .{ c(DIM), d, c(RESET) });
    // Actionable suggestion in cyan — the next step should catch the eye.
    if (suggestion) |s| p("   {s}-> {s}{s}\n", .{ c(CYAN), s, c(RESET) });
}

// Like printError, but for genuine system failures (network/ssh/search). The sad
// kaomoji signals "this is on the machine, not on you" — never used for typos or
// not-found errors, which go through printError.
pub fn printSystemError(message: []const u8, detail: ?[]const u8, suggestion: ?[]const u8) void {
    p("{s}{s}{s}\n", .{ KAO_SAD, if (color_enabled) ERR_C else ERR_P, message });
    if (detail) |d| p("   {s}{s}{s}\n", .{ c(DIM), d, c(RESET) });
    if (suggestion) |s| p("   {s}-> {s}{s}\n", .{ c(CYAN), s, c(RESET) });
}

pub fn printWarning(message: []const u8) void {
    p("{s}{s}\n", .{ if (color_enabled) WARN_C else WARN_P, message });
}

// Display a translated build error through the 3-layer pipeline format.
// is_system = true  → (；ω；) kaomoji prefix (machine's fault, not the user's)
// suggestion may contain '\n'-separated lines; the first gets "-> " and the
// rest are indented with "   " so the secondary "nix log ..." line lines up.
pub fn buildError(err: errors.TranslatedError) void {
    if (err.is_system) {
        // KAO_SAD already includes trailing spaces: "(；ω；)  "
        p("{s}{s}{s}\n\n", .{ KAO_SAD, if (color_enabled) ERR_C else ERR_P, err.title });
    } else {
        p("{s}{s}\n\n", .{ if (color_enabled) ERR_C else ERR_P, err.title });
    }

    var body_lines = std.mem.splitScalar(u8, err.body, '\n');
    while (body_lines.next()) |line| {
        if (line.len == 0) continue;
        p("   {s}\n", .{line});
    }

    if (err.location) |loc| {
        p("{s}   {s}{s}\n", .{ c(DIM), loc, c(RESET) });
    }

    p("\n", .{});

    var sug_lines = std.mem.splitScalar(u8, err.suggestion, '\n');
    var first = true;
    while (sug_lines.next()) |line| {
        if (line.len == 0) continue;
        if (first) {
            p("{s}   -> {s}{s}\n", .{ c(CYAN), line, c(RESET) });
            first = false;
        } else {
            p("{s}   {s}{s}\n", .{ c(DIM), line, c(RESET) });
        }
    }
}

// Display post-build warnings collected from captured stderr.
// Shown after the success line in dim yellow.
pub fn buildWarnings(warnings: []const []const u8) void {
    for (warnings) |w| {
        p("{s}   \u{26a0}  {s}{s}\n", .{ c(YELLOW), w, c(RESET) });
    }
}

pub fn aborted() void {
    p("{s}aborted\n", .{hdr()});
}

// One-time dim note when ~/.om.conf is migrated to the XDG config path.
pub fn configMigrated(path: []const u8) void {
    p("{s}{s}config migrated to {s}{s}\n", .{ step(), c(DIM), path, c(RESET) });
}

pub fn printTeach(cmd: []const u8) void {
    if (teach_enabled) p("{s}{s}{s}\n", .{ teach_pfx(), cmd, c(RESET) });
}

pub fn printSubstep(comptime fmt: []const u8, args: anytype) void {
    p("{s}", .{step()});
    p(fmt, args);
    p("\n", .{});
}

// Strips terminal-hostile bytes from external/untrusted text before it reaches
// the terminal: full CSI sequences (ESC '[' ... final byte) — used to scrub a
// child process's ANSI color when NO_COLOR forces capture-then-print instead of
// a direct stream — plus any other byte < 0x20 except \n and \t, which would
// otherwise let hook output, a nix search description, or an unparseable log
// line smuggle escape sequences (title changes, screen garbage, spoofed lines)
// into the terminal (NINA-016).
pub fn sanitize(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < input.len) {
        const b = input[i];
        if (b == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len and !(input[i] >= 0x40 and input[i] <= 0x7e)) : (i += 1) {}
            if (i < input.len) i += 1; // consume the final byte
            continue;
        }
        if (b < 0x20 and b != '\n' and b != '\t') {
            i += 1;
            continue;
        }
        try out.append(gpa, b);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "sanitize strips CSI color sequences" {
    const cleaned = try sanitize(std.testing.allocator, "kepr: \x1b[31;1m13.1 KiB\x1b[0m");
    defer std.testing.allocator.free(cleaned);
    try std.testing.expectEqualStrings("kepr: 13.1 KiB", cleaned);
}

test "sanitize strips bare control bytes but keeps newline and tab" {
    const cleaned = try sanitize(std.testing.allocator, "line one\x07\nnext\ttab\x1b]0;evil title\x07 done");
    defer std.testing.allocator.free(cleaned);
    try std.testing.expectEqualStrings("line one\nnext\ttab]0;evil title done", cleaned);
}

// gpa sanitizes each hook output line before it reaches the terminal — hooks are
// the user's own code (weak boundary, but still not om's own text) and their
// output could contain embedded escape sequences (NINA-016).
pub fn hookFailed(gpa: std.mem.Allocator, name: []const u8, code: u8, hook_output: []const u8) void {
    p("{s}{s} hook exited with code {d}{s}\n\n", .{ hdr(), name, code, c(RESET) });

    if (hook_output.len > 0) {
        var lines = std.mem.splitScalar(u8, hook_output, '\n');
        var shown: [5][]const u8 = undefined;
        var count: usize = 0;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            shown[count % shown.len] = trimmed;
            count += 1;
        }

        const display_count = @min(count, shown.len);
        const start = count - display_count;
        for (0..display_count) |i| {
            const line = shown[(start + i) % shown.len];
            const clean = sanitize(gpa, line) catch line;
            defer if (clean.ptr != line.ptr) gpa.free(clean);
            p("   {s}{s}{s}\n", .{ c(DIM), clean, c(RESET) });
        }
        p("\n", .{});
    }
}

pub fn hookWarning(name: []const u8, code: u8, hook_output: []const u8) void {
    _ = hook_output;
    p("{s}   warning: {s} hook exited with code {d}{s}\n", .{ c(YELLOW), name, code, c(RESET) });
}

// --- Confirmation prompt (returns true = yes) ---

fn stdinIsTty() bool {
    return std.Io.File.stdin().isTty(_io) catch false;
}

fn printConfirmAbortHint() void {
    p("   {s}refusing to assume yes on a closed/non-interactive stdin — pass --yes to confirm automatically{s}\n", .{ c(YELLOW), c(RESET) });
}

// Pure decision for an interactive read that has already happened: `saw_eof` is
// true when the read loop hit end-of-input before a newline, `line` is whatever
// was read (possibly empty). A real EOF with nothing typed (e.g. Ctrl-D at the
// prompt) is treated the same as a closed/non-interactive stdin — silently
// proceeding on a closed input stream is exactly the footgun this prompt exists
// to prevent. Otherwise this is a plain [Y/n]-style default-yes parse.
fn decideAnswer(saw_eof: bool, line: []const u8) bool {
    if (saw_eof and line.len == 0) return false;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    return trimmed[0] != 'n' and trimmed[0] != 'N';
}

// Split out from confirm() so a test can force the non-interactive branch
// deterministically instead of depending on the test runner's own stdin.
fn confirmWithTty(prompt: []const u8, is_tty: bool) bool {
    if (auto_yes) return true;
    if (!is_tty) {
        printConfirmAbortHint();
        return false;
    }
    p("   {s}continue? [Y/n]  ", .{prompt});
    flush();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    var eof = false;
    while (i < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[i .. i + 1]) catch {
            eof = true;
            break;
        };
        if (n == 0) {
            eof = true;
            break;
        }
        if (buf[i] == '\n') break;
        i += 1;
    }
    const line = buf[0..i];
    const answer = decideAnswer(eof, line);
    if (!answer and eof and line.len == 0) printConfirmAbortHint();
    return answer;
}

pub fn confirm(prompt: []const u8) bool {
    return confirmWithTty(prompt, stdinIsTty());
}

fn initForTest() void {
    const S = struct {
        var buf: [256]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&buf);
        var env: std.process.Environ.Map = .init(std.testing.allocator);
    };
    init(&S.discarding.writer, std.testing.io, &S.env, false);
}

test "confirmWithTty: non-tty stdin refuses and prints a hint instead of assuming yes (NINA-005)" {
    initForTest();
    defer setAutoYes(false);
    try std.testing.expect(!confirmWithTty("test", false));
}

test "confirmWithTty: --yes bypasses the tty check entirely" {
    initForTest();
    setAutoYes(true);
    defer setAutoYes(false);
    try std.testing.expect(confirmWithTty("test", false));
}

test "decideAnswer: real EOF with nothing typed refuses (NINA-005)" {
    try std.testing.expect(!decideAnswer(true, ""));
}

test "decideAnswer: bare enter accepts the [Y/n] default" {
    try std.testing.expect(decideAnswer(false, ""));
}

test "decideAnswer: explicit y/Y accepts" {
    try std.testing.expect(decideAnswer(false, "y"));
    try std.testing.expect(decideAnswer(false, "Y"));
}

test "decideAnswer: explicit n/N refuses" {
    try std.testing.expect(!decideAnswer(false, "n"));
    try std.testing.expect(!decideAnswer(false, "N"));
}

// Like confirm, but defaults to NO on an empty answer — for prompts that touch
// system files, where a stray Enter should never trigger the action.
pub fn confirmDefaultNo(question: []const u8) bool {
    p("   {s} [y/N]  ", .{question});
    flush();
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[i .. i + 1]) catch break;
        if (n == 0) break;
        if (buf[i] == '\n') break;
        i += 1;
    }
    const input = std.mem.trim(u8, buf[0..i], " \t");
    if (input.len == 0) return false;
    return input[0] == 'y' or input[0] == 'Y';
}

// --- Apply / rebuild ---

pub fn applyStart(machine: []const u8) void {
    p("{s}{s}rebuilding {s}...\n", .{ KAO_COZY, hdr(), machine });
}

// after_failure: true only when the previous apply this session failed and this
// one succeeded — the one moment that earns the excited kaomoji. Routine
// successes show no kaomoji.
pub fn applyDone(gen: u32, elapsed_ms: u64, after_failure: bool) void {
    const face = if (after_failure) KAO_EXCITED else "";
    const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    if (elapsed_ms >= 1000) {
        p("{s}{s}generation {s}{d}{s}  {s}[{d:.1}s]{s}\n", .{ face, hdr(), c(BOLD), gen, c(RESET), c(DIM), secs, c(RESET) });
    } else {
        p("{s}{s}generation {s}{d}{s}\n", .{ face, hdr(), c(BOLD), gen, c(RESET) });
    }
}

pub fn applyFailed(translated: []const u8) void {
    p("{s}build failed\n", .{if (color_enabled) ERR_C else ERR_P});
    if (translated.len > 0) p("   {s}{s}{s}\n", .{ c(DIM), translated, c(RESET) });
    p("   {s}-> om doctor{s}\n", .{ c(DIM), c(RESET) });
}

pub fn applyDry(machine: []const u8) void {
    p("{s}dry run  {s}\n", .{ hdr(), machine });
}

pub fn applyDryDone() void {
    p("{s}no changes applied\n", .{hdr()});
}

// --- Check ---

pub fn checkStart(machine: []const u8) void {
    p("{s}checking {s}...\n", .{ hdr(), machine });
}

pub fn checkOk() void {
    p("{s}{s}ok{s}\n", .{ hdr(), c(GREEN), c(RESET) });
}

pub fn checkFailed(msg: []const u8) void {
    p("{s}config invalid\n", .{if (color_enabled) ERR_C else ERR_P});
    if (msg.len > 0) p("   {s}{s}{s}\n", .{ c(DIM), msg, c(RESET) });
}

// --- Back / go ---

pub fn backStart(machine: []const u8, from: u32, to: u32) void {
    p("{s}rolling back  {s}  gen {d} -> gen {d}\n", .{ hdr(), machine, from, to });
}

pub fn goStart(machine: []const u8, current: u32, target: u32) void {
    p("{s}switching  {s}  gen {d} -> gen {d}\n", .{ hdr(), machine, current, target });
}

pub fn generationDone(n: u32) void {
    p("{s}done  gen {s}{d}{s}\n", .{ hdr(), c(BOLD), n, c(RESET) });
}

// `back` has nothing older to roll back to. This is a clean stop, not a build
// failure — the rollback would otherwise surface nixos-rebuild's confusing
// 'no profile version older than the current' as a fake build error.
pub fn alreadyOldest() void {
    p("{s}already at the oldest generation\n", .{if (color_enabled) ERR_C else ERR_P});
}

// Like generationDone but for `back` specifically — a successful rollback earns
// the gentle kaomoji. `go` keeps the plain generationDone line.
pub fn backDone(n: u32) void {
    p("{s}{s}done  gen {s}{d}{s}\n", .{ KAO_GENTLE, hdr(), c(BOLD), n, c(RESET) });
}

// --- History ---

pub fn historyHeader(machine: []const u8) void {
    p("{s}generations  {s}\n\n", .{ hdr(), machine });
}

pub fn historyRow(gen: types.GenerationInfo) void {
    if (gen.current) {
        p("   {s}{d}{s}   {s}   {s}   {s}current{s}\n", .{ c(BOLD), gen.number, c(RESET), gen.date, gen.time, c(BOLD), c(RESET) });
    } else {
        p("   {s}{d}   {s}   {s}{s}\n", .{ c(DIM), gen.number, gen.date, gen.time, c(RESET) });
    }
}

// --- Clean ---

pub fn cleanStart(machine: []const u8, keep: u32, total: u32) void {
    p("{s}cleaning  {s}  keeping {d} of {d}\n", .{ hdr(), machine, keep, total });
}

// Fewer generations than the keep limit — there's nothing to collect. Avoids the
// nonsensical 'keeping 5 of 1'.
pub fn cleanNothing(machine: []const u8, total: u32) void {
    p("{s}cleaning  {s}\n\n", .{ hdr(), machine });
    p("   only {d} generation{s} — nothing to remove.\n", .{ total, if (total == 1) "" else "s" });
}

pub fn cleanDoneFreed(freed_bytes: u64) void {
    const freed_gb = @as(f64, @floatFromInt(freed_bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (freed_bytes > 0) {
        p("{s}{s}freed {d:.1} GB{s}\n", .{ KAO_CONTENT, hdr(), freed_gb, c(RESET) });
    } else {
        p("{s}{s}nothing to free{s}\n", .{ KAO_CONTENT, hdr(), c(RESET) });
    }
}

// Backward-compatible alias — callers without a byte count show the plain done line.
pub fn cleanDone() void {
    cleanDoneFreed(0);
}

// --- Sync ---

pub fn syncStart(machine: []const u8) void {
    p("{s}syncing submodules  {s}\n", .{ hdr(), machine });
}

pub fn syncDone() void {
    p("{s}sync complete\n", .{hdr()});
}

// --- Status ---

pub fn statusHeader() void {
    p("{s}status\n\n", .{hdr()});
}

pub fn statusRow(machine: []const u8, gen: u32, time: []const u8, size: []const u8, ok: bool) void {
    if (ok) {
        p("   {s}{s}{s}   gen {s}{d}{s}   {s}{s}   {s}{s}\n", .{ c(DIM), machine, c(RESET), c(BOLD), gen, c(RESET), c(DIM), time, size, c(RESET) });
    } else {
        p("   {s}{s}   {s}unreachable{s}\n", .{ c(RED), machine, "", c(RESET) });
    }
}

pub fn weightStart(machine: []const u8) void {
    p("{s}weighing  {s}\n", .{ hdr(), machine });
}

pub fn weightResult(machine: []const u8, size: []const u8) void {
    p("{s}{s}  {s}{s}{s}\n", .{ hdr(), machine, c(BOLD), size, c(RESET) });
}

// Dim Home Manager generation line, indented under the machine row. Only shown
// when standalone HM is detected; absent otherwise so the layout is unchanged.
pub fn statusHomeRow(gen: u32, detail: []const u8) void {
    if (detail.len > 0) {
        p("   {s}         hm  gen {d}   {s}{s}\n", .{ c(DIM), gen, detail, c(RESET) });
    } else {
        p("   {s}         hm  gen {d}{s}\n", .{ c(DIM), gen, c(RESET) });
    }
}

// --- Diff ---

pub fn diffHeader(a: u32, b: u32, machine: []const u8) void {
    p("{s}gen {d} -> gen {d}  {s}\n\n", .{ hdr(), a, b, machine });
}

// Reached when no generation is marked current (non-standard profile layout,
// a transient readlink failure, or a non-GNU remote host) or there are too
// few generations to infer a pair — nothing safe to diff against.
pub fn diffCannotDetermine() void {
    p("{s}cannot determine current generation — nothing to diff\n", .{if (color_enabled) WARN_C else WARN_P});
}

pub fn diffRow(entry: types.DiffEntry) void {
    switch (entry.op) {
        .add => p("   {s}+{s} {s}   {s}\n", .{ c(GREEN), c(RESET), entry.package, entry.new_version orelse "" }),
        .remove => p("   {s}-{s} {s}   {s}\n", .{ c(RED), c(RESET), entry.package, entry.old_version orelse "" }),
        .change => p("   {s}^{s} {s}   {s} -> {s}\n", .{ c(CYAN), c(RESET), entry.package, entry.old_version orelse "", entry.new_version orelse "" }),
    }
}

// --- Doctor ---

pub fn doctorHeader(machine: []const u8) void {
    p("{s}diagnosing  {s}\n\n", .{ hdr(), machine });
}

pub fn doctorRow(check: types.DoctorCheck) void {
    const status_str = switch (check.status) {
        .ok => if (color_enabled) GREEN ++ "ok" ++ RESET else "ok",
        .warn => if (color_enabled) YELLOW ++ "warn" ++ RESET else "warn",
        .fail => if (color_enabled) RED ++ "fail" ++ RESET else "fail",
    };
    const note_str = check.note orelse "";
    p("   {s:<16}  {s}   {s}\n", .{ check.name, status_str, note_str });
}

pub fn doctorSummary(warnings: u32, failures: u32) void {
    if (failures > 0) {
        p("{s}{d} problems\n", .{ hdr(), failures });
    } else if (warnings > 0) {
        p("{s}{d} warnings\n", .{ hdr(), warnings });
    } else {
        p("{s}{s}{s}all good{s}\n", .{ KAO_HAPPY, hdr(), c(GREEN), c(RESET) });
    }
}

// --- Update ---

pub fn updateStart(machine: []const u8) void {
    p("{s}updating channels  {s}\n\n", .{ hdr(), machine });
}

pub fn updateChannel(name: []const u8, old: ?[]const u8, new: ?[]const u8) void {
    if (old != null and new != null and !std.mem.eql(u8, old.?, new.?)) {
        p("   {s}   {s} -> {s}\n", .{ name, old.?, new.? });
    } else {
        p("   {s}   {s}no change{s}\n", .{ name, c(DIM), c(RESET) });
    }
}

pub fn updateDone() void {
    p("\n{s}done\n", .{hdr()});
}

// --- Upgrade ---

pub fn upgradeStart(machine: []const u8) void {
    p("{s}upgrading  {s}\n", .{ hdr(), machine });
}

// --- Log ---

pub fn logHeader(machine: []const u8) void {
    p("{s}history  {s}\n\n", .{ hdr(), machine });
}

pub fn logRow(date: []const u8, time: []const u8, action: []const u8, detail: []const u8) void {
    p("   {s}{s}  {s}{s}   {s:<16}  {s}\n", .{ c(DIM), date, time, c(RESET), action, detail });
}

// --- Edit ---

pub fn editOpen(path: []const u8, editor: []const u8) void {
    p("{s}opening {s}\n", .{ hdr(), path });
    printSubstep("{s}", .{editor});
    p("\n   {s}run om check to validate before applying{s}\n", .{ c(DIM), c(RESET) });
}

// `om edit hardware` is a mistake: hardware-configuration.nix is generated by
// nixos-generate-config and warns against hand-editing. Refuse and redirect.
pub fn editHardwareWarning() void {
    p("\n   {s}warning: hardware-configuration.nix is auto-generated — do not edit directly{s}\n", .{ c(YELLOW), c(RESET) });
    p("   {s}-> make hardware changes in configuration.nix instead{s}\n", .{ c(CYAN), c(RESET) });
}

// --- Fmt ---

pub fn fmtStart(path: []const u8) void {
    p("{s}formatting  {s}\n", .{ hdr(), path });
}

pub fn fmtDone() void {
    p("{s}done\n", .{hdr()});
}

pub fn fmtNeedsFormat() void {
    p("{s}needs formatting  {s}run om fmt to fix{s}\n", .{ hdr(), c(DIM), c(RESET) });
}

// --- Repl ---

pub fn replStart() void {
    p("{s}nix repl  {s}nixpkgs loaded{s}  :q to exit\n", .{ hdr(), c(DIM), c(RESET) });
}

// --- Develop ---

pub fn developStart(pkgs: []const []const u8) void {
    p("{s}entering dev shell\n\n   ", .{hdr()});
    for (pkgs, 0..) |pkg, i| {
        if (i > 0) p("  ", .{});
        p("{s}", .{pkg});
    }
    p("\n\n   {s}-> press Ctrl+C or type 'exit' to return{s}\n\n", .{ c(DIM), c(RESET) });
}

pub fn developDone() void {
    p("{s}{s}back\n", .{ KAO_SLEEPY, hdr() });
}

// --- Info ---

pub fn infoHeader(machine: []const u8) void {
    p("{s}{s}\n\n", .{ hdr(), machine });
}

pub fn infoRow(key: []const u8, val: []const u8) void {
    p("   {s:<12}  {s}\n", .{ key, val });
}

// --- Boot ---

pub fn bootHeader(machine: []const u8) void {
    p("{s}boot entries  {s}\n\n", .{ hdr(), machine });
}

pub fn bootEntry(entry: types.BootEntry, idx: usize) void {
    if (entry.current) {
        p("   {s}> {s}", .{ c(BOLD), entry.title });
    } else {
        p("   {s}  {s}", .{ c(DIM), entry.title });
    }
    if (entry.date) |d| p("   {s}", .{d});
    p("{s}\n", .{c(RESET)});
    _ = idx;
}

// --- Service ---

pub fn serviceListHeader(machine: []const u8) void {
    p("{s}services  {s}\n\n", .{ hdr(), machine });
}

pub fn serviceRow(svc: types.ServiceInfo) void {
    const state_str = switch (svc.state) {
        .active => if (color_enabled) GREEN ++ "active" ++ RESET else "active",
        .failed => if (color_enabled) RED ++ "failed" ++ RESET else "failed",
        .inactive => "inactive",
        .unknown => "unknown",
    };
    const uptime = svc.uptime orelse "";
    p("   {s:<24}  {s:<14}  {s}\n", .{ svc.name, state_str, uptime });
}

pub fn serviceVerb(verb: []const u8, name: []const u8, machine: []const u8) void {
    p("{s}{s} {s}  {s}\n", .{ hdr(), verb, name, machine });
}

pub fn serviceDone() void {
    p("{s}done\n", .{hdr()});
}

pub fn serviceLogsHeader(name: []const u8, n: u32, machine: []const u8) void {
    p("{s}{s}  last {d} lines  {s}\n\n", .{ hdr(), name, n, machine });
}

// --- Store ---

pub fn storeInfo(info: types.StoreInfo) void {
    p("{s}store\n\n", .{hdr()});
    p("   {s:<16}  {s}\n", .{ "total", info.total_size });
    p("   {s:<16}  {d} paths\n", .{ "live", info.live_paths });
    p("   {s:<16}  {s}{d} paths{s}   {s}run om clean{s}\n", .{ "reclaimable", c(DIM), info.reclaimable_paths, c(RESET), c(CYAN), c(RESET) });
}

// --- Channel ---

pub fn channelListHeader(machine: []const u8) void {
    p("{s}channels  {s}\n\n", .{ hdr(), machine });
}

pub fn channelRow(ch: types.ChannelInfo) void {
    p("   {s:<16}  {s}\n", .{ ch.name, ch.url });
}

// --- Flake ---

pub fn flakeUpdateStart() void {
    p("{s}updating inputs\n\n", .{hdr()});
}

pub fn flakeInput(input: types.FlakeInput) void {
    if (input.changed) {
        const old = if (input.old_rev) |r| r[0..@min(7, r.len)] else "?";
        const new = if (input.new_rev) |r| r[0..@min(7, r.len)] else "?";
        p("   {s:<20}  {s} -> {s}\n", .{ input.name, old, new });
    } else {
        p("   {s:<20}  {s}no change{s}\n", .{ input.name, c(DIM), c(RESET) });
    }
}

pub fn flakeLockWritten() void {
    p("\n{s}flake.lock written\n", .{hdr()});
}

pub fn flakeValid() void {
    p("{s}{s}valid{s}\n", .{ hdr(), c(GREEN), c(RESET) });
}

pub fn flakeCheckStart() void {
    p("{s}checking flake\n", .{hdr()});
}

// --- Profile ---

pub fn profileListHeader() void {
    p("{s}profile packages\n\n", .{hdr()});
}

pub fn profileRow(attr: []const u8, pkg_version: []const u8, description: []const u8) void {
    p("   {s:<24}  {s:<12}  {s}\n", .{ attr, pkg_version, description });
}

// --- Install / Remove / Try ---

// Typo help for install: the query matched nothing, so suggest the closest real
// package name (pink) and let the caller confirm.
pub fn didYouMean(query: []const u8, suggestion: []const u8) void {
    p("{s}{s}'{s}' not found{s}  —  did you mean {s}{s}{s}?\n", .{ hdr(), c(DIM), query, c(RESET), c(PINK), suggestion, c(RESET) });
}

pub fn installStart(pkg: []const u8, path: types.InstallPath) void {
    const path_str = switch (path) {
        .profile => "profile",
        .system => "system",
    };
    p("{s}installing {s}{s}{s}  {s}\n", .{ hdr(), c(PINK), pkg, c(RESET), path_str });
}

pub fn installDone(pkg: []const u8) void {
    p("{s}{s}{s}{s} installed  {s}available now{s}\n", .{ hdr(), c(PINK), pkg, c(RESET), c(DIM), c(RESET) });
}

pub fn removeStart(pkg: []const u8) void {
    p("{s}removing {s}{s}{s}\n", .{ hdr(), c(PINK), pkg, c(RESET) });
}

// Plain-language health summary. No kaomoji, no hearts — just the facts.
pub fn mood(machine: []const u8, state: []const u8, gen: u32, age: []const u8, size: []const u8) void {
    const healthy = std.mem.eql(u8, state, "running");
    const verdict = if (healthy) "all good" else state;
    const color = if (healthy) GREEN else YELLOW;
    const face = if (healthy) KAO_HAPPY else "";
    p("{s}{s}{s}  {s}{s}{s}\n", .{ face, hdr(), machine, c(color), verdict, c(RESET) });
    if (age.len > 0 or size.len > 0) {
        p("   generation {d}, last applied {s}, {s} system closure\n", .{ gen, age, size });
    } else {
        p("   generation {d}\n", .{gen});
    }
}

pub fn installEditorPrompt(pkg: []const u8, config_path: []const u8, line: u32, editor: []const u8) void {
    p("{s}opening {s}  add {s}{s}{s} to systemPackages\n", .{ hdr(), config_path, c(PINK), pkg, c(RESET) });
    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "{s} {s} +{d}", .{ editor, config_path, line }) catch editor;
    printSubstep("{s}", .{cmd});
    p("\n   {s}save and close when done{s}\n\n", .{ c(DIM), c(RESET) });
}

pub fn installSelectPrompt(pkg: []const u8, pkg_version: []const u8) void {
    p("{s}{s}{s}{s}  {s}\n\n", .{ hdr(), c(PINK), pkg, c(RESET), pkg_version });
    p("   [i] profile install    {s}instant  no rebuild{s}\n", .{ c(DIM), c(RESET) });
    p("   [s] system install     {s}opens editor  requires apply{s}\n", .{ c(DIM), c(RESET) });
    p("   [t] try now            {s}exits when done{s}\n\n", .{ c(DIM), c(RESET) });
    p("   > ", .{});
    flush();
}

pub fn tryStart(pkg: []const u8) void {
    p("{s}trying {s}{s}{s}  exit when done\n", .{ hdr(), c(PINK), pkg, c(RESET) });
}

pub fn tryExitHint() void {
    p("   {s}-> press Ctrl+C or type 'exit' to return{s}\n", .{ c(DIM), c(RESET) });
}

pub fn tryDone() void {
    p("{s}{s}back\n", .{ KAO_SLEEPY, hdr() });
}

// --- List ---

pub fn listHeader(machine: []const u8) void {
    p("{s}packages  {s}\n\n", .{ hdr(), machine });
}

pub fn listSection(title: []const u8) void {
    p("   {s}{s}{s}\n", .{ c(DIM), title, c(RESET) });
}

// Padded name so the version column lines up into a clean two-column table.
pub fn listPkg(name: []const u8, pkg_version: []const u8) void {
    p("   {s}{s:<16}{s}  {s}{s}{s}\n", .{ c(PINK), name, c(RESET), c(DIM), pkg_version, c(RESET) });
}

pub fn blankLine() void {
    p("\n", .{});
}

// --- Hello ---

pub fn hello(machines: []const types.Machine) void {
    p("{s}{s}om\n\n", .{ KAO_FACE, hdr() });
    if (machines.len == 0) {
        p("   {s}no machines configured{s}\n", .{ c(DIM), c(RESET) });
        p("   {s}run om setup or edit ~/.config/om/config to add one{s}\n", .{ c(DIM), c(RESET) });
    } else {
        for (machines) |m| {
            const kind = if (m.local) "local" else "ssh";
            const detail = if (m.local) "default" else m.host orelse "";
            p("   {s}{s}{s}   {s}   {s}\n", .{ c(DIM), m.name, c(RESET), kind, detail });
        }
    }
    p("\n", .{});
}

// --- Help ---

pub fn help() void {
    p("{s}om  {s}NixOS Intuitive Navigation Assistant by Asha Software{s}\n\n", .{ hdr(), c(DIM), c(RESET) });
    const cmds = [_][2][]const u8{
        .{ "boot", "boot entries" },
        .{ "check", "system checks (local/doctor/mood/fmt/info/log/status)" },
        .{ "flake", "flake management (apply/upgrade/init/update/check/show/lock/clone/pin/unpin)" },
        .{ "gen", "generation management (back/go/history/diff/delete/current/list)" },
        .{ "help", "this message" },
        .{ "home", "home manager commands" },
        .{ "man [topic]", "open the built-in manual pager" },
        .{ "pkg", "package tools (info/build/cache/why/try/tree/deps/size/path/closure/search/options/develop/repl/run)" },
        .{ "profile", "profile package management (info/install/remove/upgrade)" },
        .{ "service", "manage services" },
        .{ "store", "nix store tools (weight/path/clean/optimise/verify/repair/fetch/hash)" },
        .{ "sync", "commit and push config submodules" },
    };
    for (cmds) |cmd| {
        p("   {s:<18}  {s}{s}{s}\n", .{ cmd[0], c(DIM), cmd[1], c(RESET) });
    }
    p("\n   {s}flags: --on <machine>  --dry  --check  --no-apply  --last <n>  --all  --json  --yes  --version{s}\n", .{ c(DIM), c(RESET) });
}

// Render a grouped command's subcommand list, shown when the group is invoked
// with no subcommand or an explicit `help`. Rows are {invocation, description}.
pub fn subcommandHelp(group: []const u8, rows: []const [2][]const u8, footer: ?[]const u8) void {
    p("{s}{s} subcommands\n\n", .{ hdr(), group });
    for (rows) |row| {
        p("   {s:<16}  {s}{s}{s}\n", .{ row[0], c(DIM), row[1], c(RESET) });
    }
    if (footer) |f| p("\n   {s}{s}{s}\n", .{ c(DIM), f, c(RESET) });
    p("\n   om {s} help  {s}for this message{s}\n", .{ group, c(DIM), c(RESET) });
}

pub fn version() void {
    p("{s}om  v{s}  zig 0.16  zero dependencies\n", .{ hdr(), nina_version.VERSION });
}

// --- Search (text output before TUI) ---

pub fn searchResult(pkg: types.NixPackage) void {
    p("   {s}{s}{s}   {s}{s}{s}   {s}\n", .{ c(PINK), pkg.pname, c(RESET), c(DIM), pkg.version, c(RESET), pkg.description });
}

pub fn searchHeader(query: []const u8, count: usize) void {
    p("{s}search nixpkgs {s}  {s}{d} results{s}\n\n", .{ hdr(), query, c(DIM), count, c(RESET) });
}

// Header for the combined `om options` search (NixOS + home-manager options).
pub fn optionsHeader(query: []const u8) void {
    p("{s}searching options  {s}{s}{s}\n", .{ hdr(), c(DIM), query, c(RESET) });
}

// --- Cache ---

pub fn cacheCheckStart(pkg: []const u8) void {
    p("{s}checking cache  {s}{s}{s}\n", .{ hdr(), c(PINK), pkg, c(RESET) });
}

pub fn cacheNotCached(pkg: []const u8) void {
    p("{s}{s} not found in store or cache\n", .{ hdr(), pkg });
}

pub fn cacheResult(pkg: []const u8, info: []const u8) void {
    p("{s}{s}  {s}\n", .{ hdr(), pkg, info });
}

// Dim hint after a plain (non-tty) package search: NUR lives in its own flake,
// so results never include it — point scripted users at the one-liner instead.
pub fn searchNurNote(query: []const u8) void {
    p("   {s}NUR: {s}nix search github:nix-community/NUR {s}{s}\n", .{ c(DIM), c(CYAN), query, c(RESET) });
}

// --- Gen commands ---

pub fn genCurrent(n: u32) void {
    p("{d}\n", .{n});
}

pub fn done() void {
    p("{s}done\n", .{hdr()});
}

pub fn runStart(pkg: []const u8) void {
    p("{s}running {s}{s}{s}\n", .{ hdr(), c(PINK), pkg, c(RESET) });
}

pub fn buildStart(attr: []const u8) void {
    p("{s}building {s}\n", .{ hdr(), attr });
}

pub fn buildDone() void {
    p("{s}done\n", .{hdr()});
}

pub fn treeStart(pkg: []const u8) void {
    p("{s}tree  {s}{s}{s}\n", .{ hdr(), c(PINK), pkg, c(RESET) });
}

// --- Self-update (om update) ---

pub fn updateSelfStart() void {
    p("{s}{s}checking for updates\n", .{ KAO_READY, hdr() });
}

pub fn updateSelfCurrent(ver: []const u8) void {
    p("{s}{s}om {s} is up to date{s}\n", .{ hdr(), c(GREEN), ver, c(RESET) });
}

pub fn updateSelfAvailable(current: []const u8, latest: []const u8) void {
    p("{s}update available\n", .{hdr()});
    p("{s}current  {s}{s}{s}\n", .{ step(), c(DIM), current, c(RESET) });
    p("{s}latest   {s}{s}{s}{s}\n", .{ step(), c(BOLD), c(GREEN), latest, c(RESET) });
}

fn releaseNotesHeading(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    return std.mem.trim(u8, line[i..], " \t");
}

fn releaseNotesBullet(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    const marker = line[0];
    if ((marker == '-' or marker == '*' or marker == '+') and line[1] == ' ') return line[2..];
    if (std.ascii.isDigit(marker)) {
        var i: usize = 1;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') return line[i + 2 ..];
    }
    return null;
}

pub fn updateSelfReleaseNotes(notes: []const u8) void {
    const trimmed = std.mem.trim(u8, notes, " \t\r\n");
    if (trimmed.len == 0) return;

    p("{s}changelog\n", .{hdr()});
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        const text = std.mem.trim(u8, line, " \t");
        if (text.len == 0) {
            p("\n", .{});
            continue;
        }
        if (text[0] == '#') {
            const title = releaseNotesHeading(text);
            if (title.len == 0) continue;
            p("   {s}{s}{s}{s}\n", .{ c(BOLD), c(CYAN), title, c(RESET) });
            continue;
        }
        if (releaseNotesBullet(text)) |item| {
            p("   {s}- {s}{s}\n", .{ c(CYAN), item, c(RESET) });
            continue;
        }
        p("   {s}\n", .{text});
    }
}

pub fn updateSelfDownloading(ver: []const u8, platform: []const u8) void {
    p("{s}downloading om {s} for {s}\n", .{ step(), ver, platform });
}

pub fn updateSelfVerifying() void {
    p("{s}verifying checksum\n", .{step()});
}

pub fn updateSelfInstalling(install_path: []const u8) void {
    p("{s}installing to {s}\n", .{ step(), install_path });
}

pub fn updateSelfDone(old_ver: []const u8, new_ver: []const u8) void {
    p("{s}updated  {s} {s}→{s} {s}\n", .{ hdr(), old_ver, c(DIM), c(RESET), new_ver });
}

pub fn updateSelfNoPlatform(platform: []const u8) void {
    p("{s}no pre-built binary for {s}\n", .{ hdr(), platform });
    p("{s}check kepr.uk/nina/releases for available platforms\n", .{step()});
}

pub fn updateSelfNetworkError() void {
    p("{s}{s}\n", .{ if (color_enabled) WARN_C else WARN_P, "could not reach kepr.uk — check your connection" });
}

pub fn updateSelfChecksumFailed() void {
    p("{s}checksum mismatch — download may be corrupt\n", .{if (color_enabled) ERR_C else ERR_P});
    p("{s}try again or download manually from kepr.uk/nina/releases\n", .{step()});
}

pub fn updateSelfNixManaged(new_ver: []const u8) void {
    p("{s}upgrading to {s}{s}{s} via nix profile\n", .{ step(), c(BOLD), new_ver, c(RESET) });
}

pub fn updateSelfNixFailed() void {
    p("{s}nix profile upgrade failed\n", .{if (color_enabled) ERR_C else ERR_P});
    p("{s}try manually: nix profile upgrade '.*om.*'\n", .{step()});
}

// Reached when building the new version into the store fails, before the
// profile has been touched at all — the old om element is still installed
// and working.
pub fn updateSelfNixPrefetchFailed() void {
    p("{s}could not build the new version — check your connection and try again\n", .{if (color_enabled) ERR_C else ERR_P});
    p("{s}your current om install is untouched\n", .{step()});
}

// Reached only after `nix profile remove` already succeeded and the
// re-add failed despite the new version having just been built into the
// store — om is genuinely uninstalled at this point, not just stuck on
// the old version, so the recovery command must reinstall from scratch
// rather than upgrade. Expected to be rare now that the build happens
// before the profile is touched.
pub fn updateSelfNixReinstallFailed() void {
    p("{s}nix profile add failed — om was removed and is not reinstalled\n", .{if (color_enabled) ERR_C else ERR_P});
    p("{s}reinstall manually: nix profile add --no-write-lock-file 'https://kepr.uk/nina/archive/HEAD.tar.gz#om'\n", .{step()});
}

pub fn updateSelfNixRehash() void {
    p("{s}run {s}hash -r{s} or open a new shell to use the updated binary\n", .{ step(), c(DIM), c(RESET) });
}

// Reached when om is in the store but not a `nix profile` element — i.e. it
// was installed by the system config (NixOS module / systemPackages) or
// home-manager. `om update` (the profile self-updater) can't touch those;
// pushing them at `nix profile add` would spawn a second, drifting install.
pub fn updateSelfSystemManaged() void {
    p("{s}om is managed by your system configuration, not om update\n", .{hdr()});
    p("{s}update it where you manage that config:\n", .{step()});
    p("      {s}nix flake update om && sudo nixos-rebuild switch{s}\n", .{ c(DIM), c(RESET) });
}

// --- Goodbye / uninstall ---

pub fn goodbyeStart() void {
    p("{s}uninstalling om\n", .{hdr()});
}

pub fn goodbyeFile(path: []const u8) void {
    p("{s}will remove {s}\n", .{ step(), path });
}

pub fn goodbyeNix() void {
    p("{s}will remove om from nix profile\n", .{step()});
    p("{s}command: nix profile remove om\n", .{step()});
}

pub fn goodbyeDone() void {
    p("{s}goodbye! see kepr.uk/nina to reinstall\n", .{hdr()});
}

pub fn goodbyeFailed(msg: []const u8) void {
    p("{s}{s}\n", .{ if (color_enabled) ERR_C else ERR_P, msg });
}

// --- Setup ---

pub fn setupCheck() void {
    p("{s}checking nix features\n", .{hdr()});
}

pub fn setupFeatures(nix_command: bool, flakes: bool) void {
    p("{s}nix-command  {s}{s}{s}\n", .{
        step(),
        if (nix_command) c(GREEN) else "",
        if (nix_command) "enabled" else "not enabled",
        if (nix_command) c(RESET) else "",
    });
    p("{s}flakes       {s}{s}{s}\n", .{
        step(),
        if (flakes) c(GREEN) else "",
        if (flakes) "enabled" else "not enabled",
        if (flakes) c(RESET) else "",
    });
}

pub fn setupAllSet() void {
    p("{s}all set\n", .{hdr()});
}

// Printed once, before the first search, when the nixpkgs registry still points
// at a remote URL. Flush so it lands before `nix registry pin` and any results.
pub fn pinningRegistry() void {
    p("{s}pinning nixpkgs for fast local search...\n", .{hdr()});
    flush();
}

// --- Plain (non-tty) search rendering ---
// Color-gated equivalents of the raw-ANSI TUI widget, for piped/scripted search.
// Using the gated header + c() keeps ANSI out of non-tty output (NO_COLOR / pipes).

pub fn searchPlainHeader(mode_str: []const u8, query: []const u8, count: u64) void {
    p("{s}search {s} {s}  {s}{d} results{s}\n", .{ hdr(), mode_str, query, c(DIM), count, c(RESET) });
}

pub fn searchPlainNoResults() void {
    p("   no results\n", .{});
}

pub fn searchPlainPackage(pname: []const u8, pkg_version: []const u8, description: []const u8, unfree: bool) void {
    if (unfree) {
        p("   {s}   {s}{s}{s}   {s}unfree{s}   {s}\n", .{ pname, c(CYAN), pkg_version, c(RESET), c(YELLOW), c(RESET), description });
    } else {
        p("   {s}   {s}{s}{s}   {s}\n", .{ pname, c(CYAN), pkg_version, c(RESET), description });
    }
}

pub fn searchPlainOption(name: []const u8, type_str: []const u8) void {
    p("   {s}   {s}{s}{s}\n", .{ name, c(DIM), type_str, c(RESET) });
}

pub fn searchEmptyQuery() void {
    p("{s}search needs a query  {s}e.g. om search firefox{s}\n", .{ hdr(), c(DIM), c(RESET) });
}

pub fn setupEnabling() void {
    p("{s}enabling experimental features\n", .{hdr()});
}

pub fn setupDone(path: []const u8) void {
    p("{s}wrote {s}\n", .{ step(), path });
    p("{s}done  open a new shell to pick up the change\n", .{hdr()});
}

// --- NixOS setup (declarative configuration.nix) ---

pub fn setupNixosOffer(features_line: []const u8, conf_path: []const u8) void {
    p("{s}on NixOS these go in your system config\n", .{hdr()});
    p("   om can add this line to {s}{s}{s}:\n\n", .{ c(DIM), conf_path, c(RESET) });
    p("       {s}{s}{s}\n\n", .{ c(CYAN), features_line, c(RESET) });
}

pub fn setupNixosWrote(conf_path: []const u8) void {
    p("{s}added the line to {s}  {s}(backup: {s}.om-bak){s}\n", .{ step(), conf_path, c(DIM), conf_path, c(RESET) });
    p("{s}now run {s}sudo nixos-rebuild switch{s} — then om's ready\n", .{ hdr(), c(BOLD), c(RESET) });
}

pub fn setupNixosManual(features_line: []const u8, conf_path: []const u8) void {
    p("{s}no problem — add this line inside the {s}{{ }}{s} in {s}:\n\n", .{ hdr(), c(DIM), c(RESET), conf_path });
    p("       {s}{s}{s}\n\n", .{ c(CYAN), features_line, c(RESET) });
    p("   then run {s}sudo nixos-rebuild switch{s} — then om's ready\n", .{ c(BOLD), c(RESET) });
}

pub fn setupNixosNeedsRebuild(conf_path: []const u8) void {
    p("{s}already declared in {s}\n", .{ hdr(), conf_path });
    p("   just run {s}sudo nixos-rebuild switch{s} to activate it\n", .{ c(BOLD), c(RESET) });
}

pub fn unpinDone(input: []const u8) void {
    p("{s}unpinned {s}\n", .{ hdr(), input });
}

pub fn pinDone(input: []const u8, rev: []const u8) void {
    p("{s}pinned {s} -> {s}\n", .{ hdr(), input, rev });
}

pub fn hashResult(hash: []const u8) void {
    p("{s}\n", .{hash});
}

pub fn fetchResult(hash: []const u8, url: []const u8) void {
    _ = url;
    p("{s}\n", .{hash});
}

pub fn storeRepairStart() void {
    p("{s}repairing store\n", .{hdr()});
}

pub fn storeVerifyStart() void {
    p("{s}verifying store\n", .{hdr()});
}

pub fn storeOptimiseStart(machine: []const u8) void {
    p("{s}optimising store  {s}\n", .{ hdr(), machine });
    printSubstep("nix store optimise", .{});
}

pub fn storeOptimiseDone() void {
    p("{s}done\n", .{hdr()});
}

pub fn optimizeStart(machine: []const u8) void {
    p("{s}optimizing store  {s}\n", .{ hdr(), machine });
}

pub fn optimizeDone() void {
    p("{s}store optimized\n", .{hdr()});
}

pub fn repairStart() void {
    p("{s}repairing store\n", .{hdr()});
}

pub fn repairDone() void {
    p("{s}store repaired\n", .{hdr()});
}

pub fn storeGcDone(freed: []const u8) void {
    p("{s}freed {s}\n", .{ hdr(), freed });
}

pub fn storePath(path: []const u8) void {
    p("{s}\n", .{path});
}

pub fn pkgResult(key: []const u8, val: []const u8) void {
    p("   {s:<16}  {s}\n", .{ key, val });
}

pub fn channelDone() void {
    p("{s}done\n", .{hdr()});
}

pub fn flakeShowHeader(name: []const u8) void {
    p("{s}{s}\n\n", .{ hdr(), name });
}

pub fn flakeShowEntry(kind: []const u8, name: []const u8, desc: []const u8) void {
    p("   {s:<12}  {s:<24}  {s}\n", .{ kind, name, desc });
}

// --- Home Manager ---

pub fn homeNotInstalled() void {
    p("{s}home manager not detected  {s}nothing to do{s}\n", .{ hdr(), c(DIM), c(RESET) });
}

// HM is a NixOS/flake module — rebuilt by nixos-rebuild, not the standalone CLI.
pub fn homeModuleManaged() void {
    p("{s}home manager is managed by your system config\n", .{hdr()});
    p("   {s}-> run {s}om apply{s}{s} to rebuild both together{s}\n", .{ c(CYAN), c(BOLD), c(RESET), c(CYAN), c(RESET) });
}

pub fn homeApplyStart(machine: []const u8) void {
    p("{s}{s}applying home config  {s}\n", .{ KAO_COZY, hdr(), machine });
}

pub fn homeApplyDone(gen: u32, elapsed_ms: u64) void {
    const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    // gen 0 means the post-switch generation re-read failed — the switch itself
    // succeeded, so report success without a misleading "generation 0".
    if (gen == 0) {
        if (elapsed_ms >= 1000) {
            p("{s}done  {s}[{d:.1}s]{s}\n", .{ hdr(), c(DIM), secs, c(RESET) });
        } else {
            p("{s}done\n", .{hdr()});
        }
        return;
    }
    if (elapsed_ms >= 1000) {
        p("{s}generation {s}{d}{s}  {s}[{d:.1}s]{s}\n", .{ hdr(), c(BOLD), gen, c(RESET), c(DIM), secs, c(RESET) });
    } else {
        p("{s}generation {s}{d}{s}\n", .{ hdr(), c(BOLD), gen, c(RESET) });
    }
}

// `home` was invoked against a remote machine. Detection + flake-ref are
// local-only, so we don't act on a remote — point the user at the local run.
pub fn homeLocalOnly(machine: []const u8) void {
    p("{s}home manager commands run on the local machine only\n", .{hdr()});
    p("   {s}-> '{s}' is remote; run om home on that machine directly{s}\n", .{ c(DIM), machine, c(RESET) });
}

pub fn homeApplyDry(machine: []const u8) void {
    p("{s}home dry run  {s}\n", .{ hdr(), machine });
}

pub fn homeApplyDryDone() void {
    p("{s}{s}ok{s}  no changes applied\n", .{ hdr(), c(GREEN), c(RESET) });
}

pub fn homeBackStart(machine: []const u8, from: u32, to: u32) void {
    p("{s}rolling back home config  {s}  gen {d} -> gen {d}\n", .{ hdr(), machine, from, to });
}

pub fn homeBackDone(n: u32) void {
    p("{s}{s}done  gen {s}{d}{s}\n", .{ KAO_GENTLE, hdr(), c(BOLD), n, c(RESET) });
}

pub fn homeHistoryHeader(machine: []const u8) void {
    p("{s}home generations  {s}\n\n", .{ hdr(), machine });
}

pub fn homeHistoryRow(number: u32, date: []const u8, time: []const u8, current: bool) void {
    if (current) {
        p("   {s}{d}{s}   {s}   {s}   {s}current{s}\n", .{ c(BOLD), number, c(RESET), date, time, c(BOLD), c(RESET) });
    } else {
        p("   {s}{d}   {s}   {s}{s}\n", .{ c(DIM), number, date, time, c(RESET) });
    }
}

pub fn homeEditOpen(path: []const u8, editor: []const u8) void {
    p("{s}opening {s}\n", .{ hdr(), path });
    printSubstep("{s}", .{editor});
}

pub fn homeCheckStart(machine: []const u8) void {
    p("{s}checking home config  {s}\n", .{ hdr(), machine });
}

pub fn homeCheckOk() void {
    p("{s}{s}ok{s}\n", .{ hdr(), c(GREEN), c(RESET) });
}

pub fn homeDiffHeader(a: u32, b: u32, machine: []const u8) void {
    p("{s}home gen {d} -> gen {d}  {s}\n\n", .{ hdr(), a, b, machine });
}

pub fn homeNothingToDiff() void {
    p("{s}only one home generation — nothing to diff yet\n", .{hdr()});
}

pub fn homePackagesHeader(machine: []const u8) void {
    p("{s}home packages  {s}\n\n", .{ hdr(), machine });
}

// A flake attribute wasn't defined — note it (dim) before trying the next, less
// specific candidate in the home-apply fallback chain.
pub fn homeAttrFallback(ref: []const u8) void {
    p("   {s}{s} not defined — trying next{s}\n", .{ c(DIM), ref, c(RESET) });
}

pub fn homeInitStart(switch_on_init: bool, dir: ?[]const u8) void {
    const target = dir orelse "~/.config/home-manager";
    if (switch_on_init) {
        p("{s}{s}setting up home manager  {s}{s}{s}\n", .{ KAO_COZY, hdr(), c(PINK), target, c(RESET) });
        p("   {s}-> will activate after init{s}\n", .{ c(DIM), c(RESET) });
    } else {
        p("{s}initialising home manager  {s}{s}{s}\n", .{ hdr(), c(PINK), target, c(RESET) });
        p("   {s}-> edit home.nix then run {s}om home apply{s}\n", .{ c(DIM), c(BOLD), c(RESET) });
    }
}

pub fn homeInitDone(switch_on_init: bool) void {
    if (switch_on_init) {
        p("{s}{s}home manager ready\n", .{ KAO_GENTLE, hdr() });
    } else {
        p("{s}done  edit home.nix and run {s}om home apply{s} when ready\n", .{ hdr(), c(BOLD), c(RESET) });
    }
}

// `home init` against a config that already exists — never overwrite; point at
// apply instead.
pub fn homeInitExists(path: []const u8) void {
    p("{s}home manager config already exists\n", .{if (color_enabled) WARN_C else WARN_P});
    p("   {s}{s}{s}\n", .{ c(DIM), path, c(RESET) });
    p("   {s}-> run {s}om home apply{s}{s} to activate it{s}\n", .{ c(CYAN), c(BOLD), c(RESET), c(CYAN), c(RESET) });
}

// --- First-run wizard ---

pub fn firstRunBanner() void {
    p("{s}{s}om \u{2014} first run\n\n", .{ KAO_FACE, hdr() });
}

pub fn firstRunNoConfig() void {
    p("   no config found. let me get set up.\n\n", .{});
}

// Print a prompt line and read the user's answer. Returns the default if the
// user presses Enter without typing anything. buf must be at least 256 bytes.
// Returns a slice into buf (or default if empty input).
pub fn firstRunPrompt(label: []const u8, default: []const u8, buf: []u8) []const u8 {
    p("   {s:<14} {s}> {s}", .{ label, c(DIM), c(RESET) });
    flush();
    var i: usize = 0;
    while (i < buf.len - 1) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[i .. i + 1]) catch break;
        if (n == 0) break;
        if (buf[i] == '\n') break;
        i += 1;
    }
    const input = std.mem.trim(u8, buf[0..i], " \t\r");
    if (input.len == 0) {
        // Echo the default so the output shows what was chosen
        p("{s}{s}{s}\n", .{ c(DIM), default, c(RESET) });
        flush();
        return default;
    }
    return input;
}

pub fn firstRunScanning() void {
    p("\n   {s}:: scanning for config...{s}\n", .{ c(DIM), c(RESET) });
}

// Report what the scan found at /etc/nixos, noting flake vs channel.
pub fn firstRunDetected(path: []const u8, is_flake: bool) void {
    const kind = if (is_flake) "flake-based system" else "channel-based system";
    p("   {s}-> found {s}{s}   {s}({s}){s}\n\n", .{ c(CYAN), path, c(RESET), c(DIM), kind, c(RESET) });
}

pub fn firstRunNoneFound() void {
    p("   {s}-> nothing found at /etc/nixos{s}\n\n", .{ c(DIM), c(RESET) });
}

// Prompt with a pre-filled default shown in brackets. Empty input accepts the
// default. When `detected` and a default is present, note that enter confirms.
pub fn firstRunPromptDefault(label: []const u8, default: []const u8, detected: bool, buf: []u8) []const u8 {
    if (default.len > 0) {
        p("   {s:<14} {s}[{s}]{s} > ", .{ label, c(DIM), default, c(RESET) });
        if (detected) p("{s}enter to confirm{s} ", .{ c(DIM), c(RESET) });
    } else {
        p("   {s:<14} {s}> {s}", .{ label, c(DIM), c(RESET) });
    }
    flush();
    var i: usize = 0;
    while (i < buf.len - 1) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[i .. i + 1]) catch break;
        if (n == 0) break;
        if (buf[i] == '\n') break;
        i += 1;
    }
    const input = std.mem.trim(u8, buf[0..i], " \t\r");
    if (input.len == 0) {
        p("{s}{s}{s}\n", .{ c(DIM), default, c(RESET) });
        flush();
        return default;
    }
    return input;
}

// Shown before channel operations on a flake-managed system, where nix-channel
// commands generally don't apply.
pub fn flakeChannelNote() void {
    p("{s}{s}note: flake-based system — use {s}om flake update{s}{s} to update inputs{s}\n", .{ hdr(), c(DIM), c(CYAN), c(RESET), c(DIM), c(RESET) });
}

pub fn firstRunWritten(path: []const u8) void {
    p("\n   {s}written to {s}{s}\n\n", .{ c(DIM), path, c(RESET) });
}

pub fn firstRunSkipped() void {
    p("\n   {s}skipping setup in non-interactive mode{s}\n", .{ c(DIM), c(RESET) });
}
