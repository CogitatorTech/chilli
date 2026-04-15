//! Handles the parsing of command-line arguments into flags and positional values.
const std = @import("std");
const command = @import("command.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

/// A simple forward-only iterator over a slice of string arguments.
pub const ArgIterator = struct {
    args: []const []const u8,
    index: usize,

    /// Initializes a new iterator for the given argument slice.
    pub fn init(args: []const []const u8) ArgIterator {
        return ArgIterator{ .args = args, .index = 0 };
    }

    /// Peeks at the next argument without consuming it.
    pub fn peek(self: *const ArgIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        return self.args[self.index];
    }

    /// Consumes the next argument, advancing the iterator.
    pub fn next(self: *ArgIterator) void {
        self.index += 1;
    }
};

/// An internal struct to hold a parsed flag and its value.
pub const ParsedFlag = struct {
    name: []const u8,
    value: types.FlagValue,
};

/// Result of attempting to parse a single flag from the iterator.
const FlagParseResult = enum {
    /// A flag was successfully parsed and consumed from the iterator.
    parsed,
    /// The current argument is not a flag (no `-` prefix, is `--`, or end of args).
    not_a_flag,
};

/// Attempts to parse a single flag (long or short) from the current iterator position.
/// If successful, the parsed flag is appended to `cmd.parsed_flags` and the iterator
/// is advanced past the flag (and its value, if any). Returns `.not_a_flag` if the
/// current argument is not a flag.
fn parseSingleFlag(cmd: *command.Command, iterator: *ArgIterator) errors.Error!FlagParseResult {
    const arg = iterator.peek() orelse return .not_a_flag;

    if (std.mem.eql(u8, arg, "--")) return .not_a_flag;

    if (std.mem.startsWith(u8, arg, "--")) {
        const arg_body = arg[2..];
        var flag_name: []const u8 = arg_body;
        var value: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, arg_body, '=')) |eq_idx| {
            flag_name = arg_body[0..eq_idx];
            value = arg_body[eq_idx + 1 ..];
        }

        // Reject `--=value` and bare `--` (which has already been handled above).
        if (flag_name.len == 0) return errors.Error.UnknownFlag;

        const flag = cmd.findFlag(flag_name) orelse return errors.Error.UnknownFlag;

        if (flag.type == .Bool) {
            const flag_value = if (value) |v| try types.parseBool(v) else true;
            try cmd.parsed_flags.append(cmd.allocator, .{
                .name = flag_name,
                .value = .{ .Bool = flag_value },
            });
            iterator.next();
        } else {
            iterator.next();
            const val = value orelse iterator.peek() orelse return errors.Error.MissingFlagValue;
            if (value == null) {
                iterator.next();
            }
            try cmd.parsed_flags.append(cmd.allocator, .{
                .name = flag_name,
                .value = try types.parseValue(flag.type, val),
            });
        }
        return .parsed;
    }

    if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
        const shortcuts = arg[1..];
        iterator.next();

        for (shortcuts, 0..) |shortcut, i| {
            const flag = cmd.findFlagByShortcut(shortcut) orelse return errors.Error.UnknownFlag;

            if (flag.type == .Bool) {
                try cmd.parsed_flags.append(cmd.allocator, .{ .name = flag.name, .value = .{ .Bool = true } });
            } else {
                var value: []const u8 = undefined;
                var value_from_next_arg = false;

                if (shortcuts.len > i + 1) {
                    value = shortcuts[i + 1 ..];
                } else {
                    value = iterator.peek() orelse return errors.Error.MissingFlagValue;
                    value_from_next_arg = true;
                }

                if (value_from_next_arg) {
                    iterator.next();
                }

                try cmd.parsed_flags.append(cmd.allocator, .{
                    .name = flag.name,
                    .value = try types.parseValue(flag.type, value),
                });
                break;
            }
        }
        return .parsed;
    }

    return .not_a_flag;
}

/// Parses command-line arguments from an iterator, populating the command's
/// `parsed_flags` and `parsed_positionals` fields.
///
/// - `cmd`: The command to parse arguments for.
/// - `iterator`: The `ArgIterator` providing the argument strings.
pub fn parseArgsAndFlags(cmd: *command.Command, iterator: *ArgIterator) errors.Error!void {
    var parsing_flags = true;
    while (iterator.peek()) |_| {
        if (parsing_flags) {
            if (std.mem.eql(u8, iterator.peek().?, "--")) {
                parsing_flags = false;
                iterator.next();
                continue;
            }
            const result = try parseSingleFlag(cmd, iterator);
            if (result == .parsed) continue;
        }

        try cmd.parsed_positionals.append(cmd.allocator, iterator.peek().?);
        iterator.next();
    }
}

/// Parses only flags (long and short) from the argument iterator, stopping at the first
/// non-flag argument or `--`. This is used during subcommand resolution to consume flags
/// that appear before subcommand names.
///
/// - `cmd`: The command whose flag definitions are used for parsing.
/// - `iterator`: The argument iterator to read from.
pub fn parseFlagsOnly(cmd: *command.Command, iterator: *ArgIterator) errors.Error!void {
    while (true) {
        const result = try parseSingleFlag(cmd, iterator);
        if (result == .not_a_flag) break;
    }
}

/// Validates that all required positional arguments have been provided and that there are
/// no excess arguments unless a variadic argument is defined.
///
/// - `cmd`: The command whose parsed arguments should be validated.
pub fn validateArgs(cmd: *command.Command) errors.Error!void {
    const num_defined = cmd.positional_args.items.len;
    const num_parsed = cmd.parsed_positionals.items.len;

    if (num_defined == 0) {
        if (num_parsed > 0) return errors.Error.TooManyArguments;
        return;
    }

    const last_arg_def = cmd.positional_args.items[num_defined - 1];
    const has_variadic = last_arg_def.variadic;

    var required_count: usize = 0;
    for (cmd.positional_args.items) |arg_def| {
        if (arg_def.is_required) {
            required_count += 1;
        }
    }
    if (num_parsed < required_count) {
        return errors.Error.MissingRequiredArgument;
    }

    if (!has_variadic and num_parsed > num_defined) {
        return errors.Error.TooManyArguments;
    }
}

// Tests for the `parser` module

const testing = std.testing;
const context = @import("context.zig");

fn dummyExec(_: context.CommandContext) !void {}

fn newTestCmd(allocator: std.mem.Allocator) !*command.Command {
    var cmd = try command.Command.init(allocator, .{
        .name = "test",
        .description = "",
        .exec = dummyExec,
    });
    errdefer cmd.deinit();

    try cmd.addFlag(.{ .name = "output", .shortcut = 'o', .type = .String, .default_value = .{ .String = "" }, .description = "" });
    try cmd.addFlag(.{ .name = "verbose", .shortcut = 'v', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });
    try cmd.addFlag(.{ .name = "force", .shortcut = 'f', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });

    return cmd;
}

test "parser: short flag with attached value" {
    const allocator = std.testing.allocator;
    var cmd = try command.Command.init(allocator, .{
        .name = "test",
        .description = "",
        .exec = dummyExec,
    });
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "output",
        .shortcut = 'o',
        .description = "Output file",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    var it = ArgIterator.init(&[_][]const u8{"-otest.txt"});
    try parseArgsAndFlags(cmd, &it);

    try std.testing.expectEqual(1, cmd.parsed_flags.items.len);
    try std.testing.expectEqualStrings("output", cmd.parsed_flags.items[0].name);

    const value = cmd.parsed_flags.items[0].value;
    switch (value) {
        .String => |s| try std.testing.expectEqualStrings("test.txt", s),
        else => std.debug.panic("Expected string value, got {any}", .{value}),
    }
}

test "parser: long flag formats" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    // Test --flag=value
    var it1 = ArgIterator.init(&[_][]const u8{"--output=file.txt"});
    try parseArgsAndFlags(cmd, &it1);
    try testing.expectEqualStrings("output", cmd.parsed_flags.items[0].name);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[0].value.String);
    cmd.parsed_flags.shrinkRetainingCapacity(0);

    // Test --flag value
    var it2 = ArgIterator.init(&[_][]const u8{ "--output", "file.txt" });
    try parseArgsAndFlags(cmd, &it2);
    try testing.expectEqualStrings("output", cmd.parsed_flags.items[0].name);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[0].value.String);
}

test "parser: short flag formats" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    // Test -f value
    var it1 = ArgIterator.init(&[_][]const u8{ "-o", "file.txt" });
    try parseArgsAndFlags(cmd, &it1);
    try testing.expectEqualStrings("output", cmd.parsed_flags.items[0].name);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[0].value.String);
    cmd.parsed_flags.shrinkRetainingCapacity(0);

    // Test grouped booleans
    var it2 = ArgIterator.init(&[_][]const u8{"-vf"});
    try parseArgsAndFlags(cmd, &it2);
    try testing.expectEqual(2, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("verbose", cmd.parsed_flags.items[0].name);
    try testing.expect(cmd.parsed_flags.items[0].value.Bool);
    try testing.expectEqualStrings("force", cmd.parsed_flags.items[1].name);
    try testing.expect(cmd.parsed_flags.items[1].value.Bool);
    cmd.parsed_flags.shrinkRetainingCapacity(0);

    // Test grouped booleans with value-taking flag at the end
    var it3 = ArgIterator.init(&[_][]const u8{ "-vfo", "file.txt" });
    try parseArgsAndFlags(cmd, &it3);
    try testing.expectEqual(3, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("verbose", cmd.parsed_flags.items[0].name);
    try testing.expectEqualStrings("force", cmd.parsed_flags.items[1].name);
    try testing.expectEqualStrings("output", cmd.parsed_flags.items[2].name);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[2].value.String);
}

test "parser: -- terminator" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    var it = ArgIterator.init(&[_][]const u8{ "--verbose", "--", "--output", "-f" });
    try parseArgsAndFlags(cmd, &it);

    try testing.expectEqual(1, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("verbose", cmd.parsed_flags.items[0].name);

    try testing.expectEqual(2, cmd.parsed_positionals.items.len);
    try testing.expectEqualStrings("--output", cmd.parsed_positionals.items[0]);
    try testing.expectEqualStrings("-f", cmd.parsed_positionals.items[1]);
}

test "parser: error conditions" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    // Unknown long flag
    var it1 = ArgIterator.init(&[_][]const u8{"--nonexistent"});
    try testing.expectError(errors.Error.UnknownFlag, parseArgsAndFlags(cmd, &it1));

    // Unknown short flag
    var it2 = ArgIterator.init(&[_][]const u8{"-x"});
    try testing.expectError(errors.Error.UnknownFlag, parseArgsAndFlags(cmd, &it2));

    // Missing value
    var it3 = ArgIterator.init(&[_][]const u8{"--output"});
    try testing.expectError(errors.Error.MissingFlagValue, parseArgsAndFlags(cmd, &it3));
}

test "parser: argument validation" {
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "req", .is_required = true, .description = "" });
    try cmd.addPositional(.{ .name = "opt", .default_value = .{ .String = "" }, .description = "" });

    // Missing required
    cmd.parsed_positionals.clearRetainingCapacity();
    try testing.expectError(errors.Error.MissingRequiredArgument, validateArgs(cmd));

    // Too many arguments
    cmd.parsed_positionals.clearRetainingCapacity();
    try cmd.parsed_positionals.appendSlice(allocator, &[_][]const u8{ "a", "b", "c" });
    try testing.expectError(errors.Error.TooManyArguments, validateArgs(cmd));

    // Correct number
    cmd.parsed_positionals.clearRetainingCapacity();
    try cmd.parsed_positionals.appendSlice(allocator, &[_][]const u8{ "a", "b" });
    try validateArgs(cmd);
}

test "parser: parseFlagsOnly stops at non-flag argument" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    var it = ArgIterator.init(&[_][]const u8{ "--verbose", "-f", "positional", "--output", "file.txt" });
    try parseFlagsOnly(cmd, &it);

    // Should have parsed --verbose and -f, then stopped at "positional"
    try testing.expectEqual(2, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("verbose", cmd.parsed_flags.items[0].name);
    try testing.expect(cmd.parsed_flags.items[0].value.Bool);
    try testing.expectEqualStrings("force", cmd.parsed_flags.items[1].name);
    try testing.expect(cmd.parsed_flags.items[1].value.Bool);

    // Iterator should be pointing at "positional"
    try testing.expectEqualStrings("positional", it.peek().?);
}

test "parser: parseFlagsOnly stops at -- terminator" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    var it = ArgIterator.init(&[_][]const u8{ "--verbose", "--", "--force" });
    try parseFlagsOnly(cmd, &it);

    // Should have parsed --verbose, then stopped at --
    try testing.expectEqual(1, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("verbose", cmd.parsed_flags.items[0].name);

    // Iterator should be pointing at "--"
    try testing.expectEqualStrings("--", it.peek().?);
}

test "parser: parseFlagsOnly consumes flag values" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    // --output takes a value; parseFlagsOnly must consume both the flag and its value
    var it = ArgIterator.init(&[_][]const u8{ "--output", "file.txt", "subcmd" });
    try parseFlagsOnly(cmd, &it);

    try testing.expectEqual(1, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("output", cmd.parsed_flags.items[0].name);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[0].value.String);

    // Iterator should be pointing at "subcmd", not "file.txt"
    try testing.expectEqualStrings("subcmd", it.peek().?);
}

test "regression: --=value is rejected with UnknownFlag" {
    // Bug: an empty flag name between the dashes and `=` was silently
    // looked up (findFlag("")) and happened to return null, but relied on
    // find-by-empty-string behavior rather than rejecting the input up-front.
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    var it = ArgIterator.init(&[_][]const u8{"--=value"});
    try testing.expectError(errors.Error.UnknownFlag, parseArgsAndFlags(cmd, &it));
}

test "parser: parseFlagsOnly with --flag=value syntax" {
    const allocator = testing.allocator;
    var cmd = try newTestCmd(allocator);
    defer cmd.deinit();

    var it = ArgIterator.init(&[_][]const u8{ "--output=file.txt", "subcmd" });
    try parseFlagsOnly(cmd, &it);

    try testing.expectEqual(1, cmd.parsed_flags.items.len);
    try testing.expectEqualStrings("file.txt", cmd.parsed_flags.items[0].value.String);
    try testing.expectEqualStrings("subcmd", it.peek().?);
}
