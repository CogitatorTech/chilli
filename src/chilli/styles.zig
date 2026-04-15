//! ANSI escape-code helpers used by chilli's help and error output.
//!
//! The raw code constants (`RESET`, `BOLD`, ...) are always available for
//! callers that want unconditional styling. Whether chilli's own help and
//! error output emits these codes is controlled by `isEnabled` / `setEnabled`,
//! with the default chosen by `autoDetect` (off when stdout is not a TTY).
const std = @import("std");

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const UNDERLINE = "\x1b[4m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const MAGENTA = "\x1b[35m";
pub const CYAN = "\x1b[36m";
pub const WHITE = "\x1b[37m";

// Module-level state: whether chilli's internal prints emit ANSI codes.
// Resolved lazily on first access through `isEnabled`.
var initialised: bool = false;
var enabled: bool = true;

/// Force ANSI on or off. Overrides the `autoDetect` result for the rest
/// of the process. Idempotent.
pub fn setEnabled(v: bool) void {
    initialised = true;
    enabled = v;
}

/// Returns whether ANSI codes should be emitted. Runs `autoDetect` once
/// on first call, caches the result, and returns the cached value on
/// subsequent calls.
pub fn isEnabled() bool {
    if (!initialised) autoDetect();
    return enabled;
}

/// Detects whether stdout is a TTY; disables ANSI output if it is not.
/// Idempotent: once it (or `setEnabled`) has run, subsequent calls are
/// no-ops.
pub fn autoDetect() void {
    if (initialised) return;
    initialised = true;
    const io = std.Options.debug_io;
    enabled = std.Io.File.stdout().isTty(io) catch false;
}

/// Returns `code` when ANSI is enabled, otherwise an empty string.
/// Use at internal print sites that want conditional styling without
/// branching the format string:
///
/// ```zig
/// try writer.print("{s}Hello{s}\n", .{ styles.s(styles.BOLD), styles.s(styles.RESET) });
/// ```
pub fn s(code: []const u8) []const u8 {
    return if (isEnabled()) code else "";
}

test "regression: styles.s returns empty when disabled, code when enabled" {
    // Bug: ANSI codes were emitted unconditionally, so `program --help > out.txt`
    // or piping help through `less` (without `-R`) would write raw escape
    // sequences to the file or terminal.
    // Fix: styles.s() gates emission on styles.isEnabled, which is now
    // TTY-auto-detected.

    // Force enabled: expect the real code.
    setEnabled(true);
    try std.testing.expectEqualStrings("\x1b[1m", s(BOLD));
    try std.testing.expectEqualStrings("\x1b[0m", s(RESET));

    // Force disabled: expect empty strings.
    setEnabled(false);
    try std.testing.expectEqualStrings("", s(BOLD));
    try std.testing.expectEqualStrings("", s(RESET));

    // Leave the state disabled so other tests don't depend on the TTY of
    // the current test runner. (Tests generally run without a real TTY.)
}
