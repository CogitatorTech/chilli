//! This module defines the core data structures used throughout the Chilli framework.
const std = @import("std");
const context = @import("context.zig");
const utils = @import("utils.zig");
const errors = @import("errors.zig");

/// Enumerates the supported data types for a `Flag` or `PositionalArg`.
pub const FlagType = enum {
    Bool,
    Int,
    Float,
    String,
};

/// A tagged union that holds the value of a parsed flag or argument.
pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i64,
    Float: f64,
    String: []const u8,
};

/// Parses a raw string value into the appropriate `FlagValue` type.
///
/// - `value_type`: The target `FlagType` to parse into.
/// - `value`: The raw string input from the command line.
/// Returns a `FlagValue` union or a parsing error.
pub fn parseValue(value_type: FlagType, value: []const u8) errors.Error!FlagValue {
    return switch (value_type) {
        .Bool => FlagValue{ .Bool = try utils.parseBool(value) },
        .Int => FlagValue{ .Int = try std.fmt.parseInt(i64, value, 10) },
        .Float => FlagValue{ .Float = try std.fmt.parseFloat(f64, value) },
        .String => FlagValue{ .String = value },
    };
}

/// Defines the configuration for a `Command`.
///
/// All string-slice fields (`name`, `description`, `version`, `section`, and
/// the entries of `aliases`) are borrowed by the `Command`, not copied. They
/// must remain valid for the lifetime of the command tree.
pub const CommandOptions = struct {
    /// The primary name of the command, used to invoke it.
    name: []const u8,
    /// A short description of the command's purpose, shown in help messages.
    description: []const u8,
    /// The function to execute when this command is run.
    exec: *const fn (ctx: context.CommandContext) anyerror!void,
    /// An optional list of alternative names for the command.
    aliases: ?[]const []const u8 = null,
    /// An optional single-character shortcut for the command (e.g., 'c').
    shortcut: ?u8 = null,
    /// An optional version string for the application. If provided on the root command,
    /// an automatic `--version` flag will be available.
    version: ?[]const u8 = null,
    /// The name of the section under which this command should be grouped in a parent's help message.
    section: []const u8 = "Commands",
};

/// Defines a command-line flag (e.g., `--verbose` or `-v`).
pub const Flag = struct {
    /// The full name of the flag (e.g., "verbose").
    name: []const u8,
    /// A short description of the flag's purpose, shown in help messages.
    description: []const u8,
    /// An optional single-character shortcut for the flag (e.g., 'v').
    shortcut: ?u8 = null,
    /// The data type of the flag's value.
    type: FlagType,
    /// The default value for the flag if it's not provided by the user.
    default_value: FlagValue,
    /// If `true`, the flag will not be shown in help messages.
    hidden: bool = false,
    /// If set, the framework will check this environment variable for a value
    /// if the flag is not provided on the command line.
    env_var: ?[]const u8 = null,
};

/// Defines a positional argument for a command.
pub const PositionalArg = struct {
    /// The name of the argument, used in help messages and for named access.
    name: []const u8,
    /// A short description of the argument's purpose.
    description: []const u8,
    /// The data type of the argument's value. Defaults to `.String`.
    type: FlagType = .String,
    /// If `true`, the argument must be provided by the user.
    is_required: bool = false,
    /// The default value for the argument if it's optional and not provided.
    default_value: ?FlagValue = null,
    /// If `true`, this argument will capture all remaining positional arguments.
    /// Only the last positional argument for a command can be variadic.
    variadic: bool = false,
};

// Tests for the `types` module

test "types: parseValue" {
    // Bool
    try std.testing.expect((try parseValue(.Bool, "true")).Bool);
    try std.testing.expect(!(try parseValue(.Bool, "false")).Bool);
    try std.testing.expectError(errors.Error.InvalidBoolString, parseValue(.Bool, "notabool"));

    // Int
    try std.testing.expectEqual(@as(i64, 123), (try parseValue(.Int, "123")).Int);
    try std.testing.expectError(error.InvalidCharacter, parseValue(.Int, "notanint"));

    // Float
    try std.testing.expectEqual(3.14, (try parseValue(.Float, "3.14")).Float);
    try std.testing.expectError(error.InvalidCharacter, parseValue(.Float, "notafloat"));

    // String
    try std.testing.expectEqualStrings("hello", (try parseValue(.String, "hello")).String);
}
