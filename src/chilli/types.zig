//! This module defines the core data structures used throughout the Chilli framework.
const std = @import("std");
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

/// Parses a boolean value from a string, case-insensitively.
///
/// Accepts "true" or "false". Any other value will result in `Error.InvalidBoolString`.
pub fn parseBool(input: []const u8) errors.Error!bool {
    if (std.ascii.eqlIgnoreCase(input, "true")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(input, "false")) {
        return false;
    }
    return errors.Error.InvalidBoolString;
}

/// Parses a raw string value into the appropriate `FlagValue` type.
///
/// - `value_type`: The target `FlagType` to parse into.
/// - `value`: The raw string input from the command line.
/// Returns a `FlagValue` union or a parsing error.
pub fn parseValue(value_type: FlagType, value: []const u8) errors.Error!FlagValue {
    return switch (value_type) {
        .Bool => FlagValue{ .Bool = try parseBool(value) },
        .Int => FlagValue{ .Int = try std.fmt.parseInt(i64, value, 10) },
        .Float => FlagValue{ .Float = try std.fmt.parseFloat(f64, value) },
        .String => FlagValue{ .String = value },
    };
}

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

test "types: parseBool" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("TRUE"));
    try std.testing.expect(!(try parseBool("false")));
    try std.testing.expect(!(try parseBool("FALSE")));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool(""));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("t"));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("f"));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("1"));
}

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
