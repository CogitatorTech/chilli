//! This module defines all public errors that can be returned by the Chilli framework.
//!
//! Consolidating errors here provides a single source of truth for error handling
//! and makes it easier for users of the library to catch specific failures.
const std = @import("std");

/// The set of all possible errors returned by the Chilli framework.
pub const Error = error{
    /// An unknown flag was provided (like `--nonexistent`).
    UnknownFlag,
    /// A flag that requires a value was provided without one.
    MissingFlagValue,
    /// Short flags were grouped incorrectly.
    InvalidFlagGrouping,
    /// A command was invoked without one of its required positional arguments.
    MissingRequiredArgument,
    /// A command was invoked with more positional arguments than it accepts.
    TooManyArguments,
    /// An invalid string was provided for a boolean flag (must be "true" or "false").
    InvalidBoolString,
    /// Attempted to add an argument after a variadic one.
    VariadicArgumentNotLastError,
    /// Attempted to add a subcommand that already has a parent.
    CommandAlreadyHasParent,
    /// An integer value was outside the valid range for the requested type.
    IntegerValueOutOfRange,
    /// A float value was outside the valid range for the requested type.
    FloatValueOutOfRange,
    /// A flag with the same name or shortcut was already defined on this command.
    DuplicateFlag,
    /// Attempted to add a required positional argument after an optional one.
    RequiredArgumentAfterOptional,
    /// A command was defined with an empty string as an alias.
    EmptyAlias,
    /// An environment variable name or value was not valid WTF-8 on Windows.
    /// Unreachable on POSIX targets; included so Windows callers of
    /// `getFlag` with an `env_var`-backed flag can handle it uniformly.
    InvalidWtf8,
} || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.mem.Allocator.Error;
