// rawterm.zig — shared raw-terminal-mode handling for the search and man TUI
// widgets. Both widgets read single keystrokes from stdin without waiting
// for Enter, which requires ECHO/ICANON off; both need the terminal restored
// to its original state no matter how the process exits.
//
// `defer rawModeDisable(...)` alone only covers normal returns and Zig
// errors — it does not run on SIGTERM/SIGHUP/SIGKILL (signals bypass defers
// entirely) or on a ReleaseSafe panic (which aborts without unwinding). Left
// unhandled, either one leaves the user's shell in raw, echo-off mode after
// nina exits (NINA-014). SIGKILL can never be caught by any process, so it
// stays out of scope; SIGTERM/SIGINT/SIGHUP are the ones a normal shell or
// `kill` can actually deliver.
//
// A POSIX signal handler cannot close over local state — no captured
// allocator, no pointer to the caller's stack `saved` termios — so the
// termios snapshot the handler restores from has to live in a file-scope
// var, updated by rawModeEnable/rawModeDisable alongside the caller's own
// copy.
const std = @import("std");

pub const STDIN_FD = std.posix.STDIN_FILENO;

var g_saved: ?std.posix.termios = null;

// Restores the terminal from the global snapshot, if raw mode is currently
// active. Split out from the signal handler so it can be exercised directly
// in a test without actually delivering (and dying to) a signal.
fn restoreSavedTermios(fd: std.posix.fd_t) void {
    if (g_saved) |t| std.posix.tcsetattr(fd, .FLUSH, t) catch {};
}

fn defaultAction() std.posix.Sigaction {
    return .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
}

// Restores the terminal, then puts the signal's default disposition back
// and re-raises it so the process actually terminates the way it would have
// without this handler installed — a signal handler that swallows SIGTERM
// and keeps running is worse than the ghosting bug it's fixing.
fn restoreAndReraise(sig: std.posix.SIG) callconv(.c) void {
    restoreSavedTermios(STDIN_FD);
    var dfl = defaultAction();
    std.posix.sigaction(sig, &dfl, null);
    std.posix.raise(sig) catch {};
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = restoreAndReraise },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
}

fn restoreDefaultSignalHandlers() void {
    var dfl = defaultAction();
    std.posix.sigaction(.INT, &dfl, null);
    std.posix.sigaction(.TERM, &dfl, null);
    std.posix.sigaction(.HUP, &dfl, null);
}

// Enables raw mode on `fd`: no echo, no line buffering, one byte at a time.
// ISIG is deliberately left on (unlike a "classic" raw-mode setup) so ^C
// still delivers SIGINT instead of arriving as a literal 0x03 byte in the
// input stream — before this fix Esc was the only way out of a wedged
// search, since ICANON+ISIG off meant ^C did nothing at all. OPOST stays on
// so "\n" keeps translating to "\r\n", which the widgets rely on.
pub fn rawModeEnable(fd: std.posix.fd_t, saved: *std.posix.termios) !void {
    var tio = try std.posix.tcgetattr(fd);
    saved.* = tio;
    g_saved = tio;
    installSignalHandlers();
    tio.lflag.ECHO = false;
    tio.lflag.ICANON = false;
    tio.lflag.IEXTEN = false;
    tio.iflag.ICRNL = false;
    tio.iflag.IXON = false;
    tio.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    tio.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .FLUSH, tio);
}

pub fn rawModeDisable(fd: std.posix.fd_t, saved: std.posix.termios) void {
    std.posix.tcsetattr(fd, .FLUSH, saved) catch {};
    restoreDefaultSignalHandlers();
    g_saved = null;
}

// --- Tests ---
//
// A real SIGTERM-to-a-spawned-om-process test would be the strongest
// evidence, but the repo has no subprocess+signal test harness to build on
// (test/vm/ drives a full NixOS VM over serial, not a quick local pty), and
// reliably synchronizing "the widget is blocked in poll() in raw mode" with
// "now send the signal" from a test process is inherently racy. Instead
// these tests open a real pty (posix_openpt/grantpt/unlockpt), so
// tcgetattr/tcsetattr run against a genuine tty rather than being mocked,
// and exercise the exact code paths the signal handler calls — everything
// except the final `raise()`, which would kill the test binary.

const testing = std.testing;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
// std.posix has no close() wrapper for a bare fd in 0.16 (callers are
// expected to go through std.Io.File) — these test-only pty fds come from
// direct libc calls instead, so close them the same way.
extern "c" fn close(fd: c_int) c_int;

const TestPty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    fn open() !TestPty {
        const O_RDWR_NOCTTY: std.posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@bitCast(O_RDWR_NOCTTY));
        if (master < 0) return error.OpenPtyFailed;
        errdefer _ = close(master);
        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;
        const path = ptsname(master) orelse return error.OpenPtyFailed;
        const slave = try std.posix.openatZ(std.posix.AT.FDCWD, path, O_RDWR_NOCTTY, 0);
        return .{ .master = master, .slave = slave };
    }

    fn closePty(self: TestPty) void {
        _ = close(self.slave);
        _ = close(self.master);
    }
};

test "rawModeEnable stashes the pre-raw termios in the signal-reachable global and disables echo/canon while leaving ISIG on" {
    const pty = TestPty.open() catch |err| {
        // No pty available in this sandbox (e.g. no /dev/ptmx) — nothing to
        // assert against; skip rather than fail the whole suite.
        std.log.warn("skipping rawterm pty test: {t}", .{err});
        return error.SkipZigTest;
    };
    defer pty.closePty();

    try testing.expect(g_saved == null);

    var saved: std.posix.termios = undefined;
    try rawModeEnable(pty.slave, &saved);
    defer rawModeDisable(pty.slave, saved);

    try testing.expect(g_saved != null);
    const applied = try std.posix.tcgetattr(pty.slave);
    try testing.expect(!applied.lflag.ECHO);
    try testing.expect(!applied.lflag.ICANON);
    try testing.expect(applied.lflag.ISIG); // NINA-014: ^C must still raise SIGINT
}

test "rawModeDisable restores the original termios and clears the signal-reachable global" {
    const pty = TestPty.open() catch |err| {
        std.log.warn("skipping rawterm pty test: {t}", .{err});
        return error.SkipZigTest;
    };
    defer pty.closePty();

    const original = try std.posix.tcgetattr(pty.slave);
    var saved: std.posix.termios = undefined;
    try rawModeEnable(pty.slave, &saved);
    rawModeDisable(pty.slave, saved);

    try testing.expect(g_saved == null);
    const restored = try std.posix.tcgetattr(pty.slave);
    try testing.expect(restored.lflag.ECHO == original.lflag.ECHO);
    try testing.expect(restored.lflag.ICANON == original.lflag.ICANON);
}

test "restoreSavedTermios (the signal handler's own restore step) puts ECHO/ICANON back without a real signal" {
    const pty = TestPty.open() catch |err| {
        std.log.warn("skipping rawterm pty test: {t}", .{err});
        return error.SkipZigTest;
    };
    defer pty.closePty();

    var saved: std.posix.termios = undefined;
    try rawModeEnable(pty.slave, &saved);
    // Simulate "process dies mid-search, still in raw mode" by calling only
    // the restore half of the handler — never the re-raise, which would
    // terminate this test binary.
    restoreSavedTermios(pty.slave);
    restoreDefaultSignalHandlers();
    g_saved = null;

    const restored = try std.posix.tcgetattr(pty.slave);
    try testing.expect(restored.lflag.ECHO == saved.lflag.ECHO);
    try testing.expect(restored.lflag.ICANON == saved.lflag.ICANON);
}
