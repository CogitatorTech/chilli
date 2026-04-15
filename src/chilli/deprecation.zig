//! Emission of deprecation warnings for commands, flags, and positional args.
//!
//! When a caller invokes a definition that carries a non-null `deprecated`
//! field, chilli prints a one-line warning to stderr (unless the
//! `CHILLI_NO_DEPRECATION_WARNINGS` environment variable is set to any
//! non-empty value). The command itself is still parsed and dispatched
//! normally, so warnings never break existing scripts.
const std = @import("std");
const styles = @import("styles.zig");

// Module-level suppression cache: check the environment variable once,
// reuse the result for every subsequent warning.
var suppression_initialised: bool = false;
var suppressed_cached: bool = false;

/// Returns true if deprecation warnings should be suppressed.
/// On first call, looks up `CHILLI_NO_DEPRECATION_WARNINGS` and caches the
/// result for the rest of the process.
pub fn isSuppressed(allocator: std.mem.Allocator) bool {
    if (!suppression_initialised) {
        suppression_initialised = true;
        const environ = std.Options.debug_threaded_io.?.environ.process_environ;
        if (environ.getAlloc(allocator, "CHILLI_NO_DEPRECATION_WARNINGS")) |val| {
            defer allocator.free(val);
            suppressed_cached = val.len > 0;
        } else |_| {
            suppressed_cached = false;
        }
    }
    return suppressed_cached;
}

/// Force suppression on or off. Used by tests to reset module state and
/// to verify the suppression path without mutating the process environment.
pub fn setSuppressedForTests(v: bool) void {
    suppression_initialised = true;
    suppressed_cached = v;
}

/// Writes a deprecation-warning line to `writer`. Exposed for tests; the
/// production path goes through `emit`, which writes to stderr.
pub fn format(
    writer: anytype,
    kind: []const u8,
    name: []const u8,
    reason: []const u8,
) !void {
    try writer.print(
        "{s}warning:{s} {s} '{s}' is deprecated: {s}\n",
        .{ styles.s(styles.YELLOW), styles.s(styles.RESET), kind, name, reason },
    );
}

/// Emits a deprecation warning to stderr if suppression is not active.
/// Failure to write is silently ignored (warnings must not disrupt the
/// program).
pub fn emit(
    allocator: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
    reason: []const u8,
) void {
    if (isSuppressed(allocator)) return;
    const io = std.Options.debug_io;
    var buf: [1024]u8 = undefined;
    var stderr_fw = std.Io.File.stderr().writer(io, &buf);
    format(&stderr_fw.interface, kind, name, reason) catch return;
    stderr_fw.flush() catch {};
}

// ============================================================================
// Tests
// ============================================================================

const TestBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn print(self: *TestBufWriter, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void {
        const result = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += result.len;
    }

    fn written(self: TestBufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

test "deprecation: format writes a warning line with the expected shape" {
    // Disable ANSI styling for stable byte-level assertions.
    styles.setEnabled(false);
    defer styles.setEnabled(false);

    var buf: [256]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };
    try format(&writer, "flag", "--old", "use --new");
    try std.testing.expectEqualStrings(
        "warning: flag '--old' is deprecated: use --new\n",
        writer.written(),
    );
}

test "deprecation: format includes ANSI codes when styles are enabled" {
    styles.setEnabled(true);
    defer styles.setEnabled(false);

    var buf: [256]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };
    try format(&writer, "command", "old-cmd", "removed in v0.5");
    const out = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[33m") != null); // yellow
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null); // reset
    try std.testing.expect(std.mem.indexOf(u8, out, "command 'old-cmd' is deprecated: removed in v0.5") != null);
}

test "deprecation: setSuppressedForTests overrides the env-var cache" {
    // Turn suppression on via the test hook; emit becomes a no-op.
    setSuppressedForTests(true);
    defer setSuppressedForTests(false);
    try std.testing.expect(isSuppressed(std.testing.allocator));

    // Turn it back off; the cache stays primed so no env lookup happens here.
    setSuppressedForTests(false);
    try std.testing.expect(!isSuppressed(std.testing.allocator));
}
