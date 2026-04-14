//! Chilli is a command-line interface (CLI) miniframework for Zig progamming language.
//!
//! It provides a structured and type-safe way to build complex command-line applications
//! with support for commands, subcommands, flags, and positional arguments.
//! The main entry point for creating a CLI is the `Command` struct.
const std = @import("std");

pub const Command = @import("chilli/command.zig").Command;
pub const CommandOptions = @import("chilli/types.zig").CommandOptions;
pub const Flag = @import("chilli/types.zig").Flag;
pub const FlagType = @import("chilli/types.zig").FlagType;
pub const FlagValue = @import("chilli/types.zig").FlagValue;
pub const PositionalArg = @import("chilli/types.zig").PositionalArg;
pub const CommandContext = @import("chilli/context.zig").CommandContext;
pub const styles = @import("chilli/utils.zig").styles;
pub const Error = @import("chilli/errors.zig").Error;

test {
    @import("std").testing.refAllDecls(@This());
}
