//! The core module for defining, managing, and executing commands.
const std = @import("std");
const parser = @import("parser.zig");
const context = @import("context.zig");
const utils = @import("utils.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

/// Represents a single command in a CLI application.
///
/// A `Command` can have its own flags, positional arguments, and an execution function.
/// It can also contain subcommands, forming a nested command structure. Commands are
/// responsible for their own memory management; `deinit` must be called on the root
/// command to free all associated resources, including those of its subcommands.
///
/// # Thread Safety
/// This object and its methods are NOT thread-safe. The command tree should be
/// fully defined in a single thread before being used. Calling `run` from multiple
/// threads on the same `Command` instance concurrently will result in a data race
/// and undefined behavior.
pub const Command = struct {
    options: types.CommandOptions,
    subcommands: std.ArrayList(*Command),
    flags: std.ArrayList(types.Flag),
    positional_args: std.ArrayList(types.PositionalArg),
    parent: ?*Command,
    allocator: std.mem.Allocator,
    parsed_flags: std.ArrayList(parser.ParsedFlag),
    parsed_positionals: std.ArrayList([]const u8),

    /// Initializes a new command.
    /// Panics if the provided command name is empty.
    pub fn init(allocator: std.mem.Allocator, options: types.CommandOptions) !*Command {
        if (options.name.len == 0) {
            std.debug.panic("Command name cannot be empty.", .{});
        }

        const command = try allocator.create(Command);
        command.* = Command{
            .options = options,
            .subcommands = .{},
            .flags = .{},
            .positional_args = .{},
            .parent = null,
            .allocator = allocator,
            .parsed_flags = .{},
            .parsed_positionals = .{},
        };

        const help_flag = types.Flag{
            .name = "help",
            .shortcut = 'h',
            .description = "Shows help information for this command",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        };
        try command.addFlag(help_flag);

        return command;
    }

    /// Deinitializes the command and all its subcommands recursively.
    ///
    /// This function should ONLY be called on the root command of the application.
    /// It recursively deinitializes all child and grandchild commands. Calling `deinit`
    /// on a subcommand that has a parent will lead to a double-free when the
    /// root command's `deinit` is also called.
    pub fn deinit(self: *Command) void {
        for (self.subcommands.items) |sub| {
            sub.deinit();
        }
        self.subcommands.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.positional_args.deinit(self.allocator);
        self.parsed_flags.deinit(self.allocator);
        self.parsed_positionals.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Adds a subcommand to this command.
    /// Returns `error.CommandAlreadyHasParent` if the subcommand has already been
    /// added to another command.
    /// Returns `error.EmptyAlias` if the subcommand is defined with an empty alias.
    pub fn addSubcommand(self: *Command, sub: *Command) !void {
        if (sub.parent != null) {
            return errors.Error.CommandAlreadyHasParent;
        }
        if (sub.options.aliases) |aliases| {
            for (aliases) |alias| {
                if (alias.len == 0) return error.EmptyAlias;
            }
        }

        sub.parent = self;
        try self.subcommands.append(self.allocator, sub);
    }

    /// Adds a flag to the command. Panics if the flag name is empty.
    /// Returns `error.DuplicateFlag` if a flag with the same name or shortcut
    /// already exists on this command.
    pub fn addFlag(self: *Command, flag: types.Flag) !void {
        if (flag.name.len == 0) {
            std.debug.panic("Flag name cannot be empty.", .{});
        }

        for (self.flags.items) |existing_flag| {
            if (std.mem.eql(u8, existing_flag.name, flag.name)) {
                return error.DuplicateFlag;
            }
            if (existing_flag.shortcut) |s_old| {
                if (flag.shortcut) |s_new| {
                    if (s_old == s_new) return error.DuplicateFlag;
                }
            }
        }

        try self.flags.append(self.allocator, flag);
    }

    /// Adds a positional argument to the command's definition.
    /// Returns `error.VariadicArgumentNotLastError` if you attempt to add an
    /// argument after one that is marked as variadic.
    /// Returns `error.RequiredArgumentAfterOptional` if you attempt to add a
    /// required argument after an optional one.
    /// Panics if the argument name is empty or an optional arg lacks a default value.
    pub fn addPositional(self: *Command, arg: types.PositionalArg) !void {
        if (arg.name.len == 0) {
            std.debug.panic("Positional argument name cannot be empty.", .{});
        }
        if (!arg.is_required and !arg.variadic and arg.default_value == null) {
            std.debug.panic("Optional positional argument '{s}' must have a default_value.", .{arg.name});
        }

        if (self.positional_args.items.len > 0) {
            const last_arg = self.positional_args.items[self.positional_args.items.len - 1];
            if (last_arg.variadic) {
                return errors.Error.VariadicArgumentNotLastError;
            }
            if (arg.is_required and !last_arg.is_required) {
                return errors.Error.RequiredArgumentAfterOptional;
            }
        }

        try self.positional_args.append(self.allocator, arg);
    }

    /// Parses arguments and executes the appropriate command. This is the core logic loop.
    pub fn execute(self: *Command, user_args: []const []const u8, data: ?*anyopaque, out_failed_cmd: *?*const Command) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var arg_iterator = parser.ArgIterator.init(user_args);

        var current_cmd: *Command = self;
        out_failed_cmd.* = current_cmd;

        // Reset root command state for re-entering.
        current_cmd.parsed_flags.shrinkRetainingCapacity(0);
        current_cmd.parsed_positionals.shrinkRetainingCapacity(0);

        // Resolve the subcommand chain, parsing flags at each level.
        // Flags before a subcommand name are stored on the command at that level.
        while (arg_iterator.peek()) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (std.mem.startsWith(u8, arg, "-")) {
                try parser.parseFlagsOnly(current_cmd, &arg_iterator);
                continue;
            }
            if (current_cmd.findSubcommand(arg)) |found_sub| {
                current_cmd = found_sub;
                out_failed_cmd.* = current_cmd;
                // Reset subcommand state for re-entrancy.
                current_cmd.parsed_flags.shrinkRetainingCapacity(0);
                current_cmd.parsed_positionals.shrinkRetainingCapacity(0);
                arg_iterator.next();
            } else {
                break;
            }
        }

        // Parse remaining flags and positional arguments for the final resolved command.
        try parser.parseArgsAndFlags(current_cmd, &arg_iterator);

        // Check for --help and --version flags BEFORE validation
        // This allows users to see help even if required arguments are missing
        if (current_cmd.getFlagValue("help")) |flag_val| {
            if (flag_val.Bool) {
                try current_cmd.printHelp();
                return;
            }
        }

        if (self.options.version != null) {
            if (current_cmd.getFlagValue("version")) |flag_val| {
                if (flag_val.Bool) {
                    const stdout = std.fs.File.stdout().deprecatedWriter();
                    try stdout.print("{s}\n", .{self.options.version.?});
                    return;
                }
            }
        }

        try parser.validateArgs(current_cmd);

        // Success, clear the out_failed_cmd
        out_failed_cmd.* = null;

        const ctx = context.CommandContext{
            .app_allocator = self.allocator,
            .tmp_allocator = arena_allocator,
            .command = current_cmd,
            .data = data,
        };

        try current_cmd.options.exec(ctx);
    }

    /// (private) Handles printing formatted errors to a writer.
    /// This function is separated for testability.
    fn handleExecutionError(
        allocator: std.mem.Allocator,
        err: anyerror,
        failed_cmd: ?*const Command,
        writer: anytype,
    ) void {
        const red = utils.styles.RED;
        const reset = utils.styles.RESET;

        switch (err) {
            error.BrokenPipe => return, // Exit silently on broken pipe
            else => {},
        }

        writer.print("{s}Error:{s} ", .{ red, reset }) catch return;

        switch (err) {
            error.MissingRequiredArgument => {
                if (failed_cmd) |cmd| {
                    const path = cmd.getCommandPath(allocator) catch "unknown command";
                    defer if (std.mem.eql(u8, path, "unknown command")) {} else {
                        allocator.free(path);
                    };
                    writer.print("Missing a required argument for command '{s}'.\n", .{path}) catch return;
                } else {
                    writer.print("Missing a required argument.\n", .{}) catch return;
                }
            },
            error.TooManyArguments => {
                if (failed_cmd) |cmd| {
                    const path = cmd.getCommandPath(allocator) catch "unknown command";
                    defer if (std.mem.eql(u8, path, "unknown command")) {} else {
                        allocator.free(path);
                    };
                    writer.print("Too many arguments provided for command '{s}'.\n", .{path}) catch return;
                } else {
                    writer.print("Too many arguments provided.\n", .{}) catch return;
                }
            },
            error.DuplicateFlag => writer.print("A flag with the same name or shortcut was defined more than once.\n", .{}) catch return,
            error.RequiredArgumentAfterOptional => writer.print("A required positional argument cannot be defined after an optional one.\n", .{}) catch return,
            error.EmptyAlias => writer.print("A command cannot be defined with an empty string as an alias.\n", .{}) catch return,
            error.UnknownFlag => writer.print("Unknown flag provided.\n", .{}) catch return,
            error.MissingFlagValue => writer.print("Flag requires a value but none was provided.\n", .{}) catch return,
            error.InvalidFlagGrouping => writer.print("Invalid short flag grouping.\n", .{}) catch return,
            error.InvalidBoolString => writer.print("Invalid value for boolean flag, expected 'true' or 'false'.\n", .{}) catch return,
            error.VariadicArgumentNotLastError => writer.print("Internal Error: Cannot add another positional argument after a variadic one.\n", .{}) catch return,
            error.CommandAlreadyHasParent => writer.print("Internal Error: A command was added to multiple parents.\n", .{}) catch return,
            error.IntegerValueOutOfRange => writer.print("An integer flag value was provided out of the allowed range.\n", .{}) catch return,
            error.InvalidCharacter => writer.print("Invalid character in numeric value.\n", .{}) catch return,
            error.Overflow => writer.print("Numeric value is too large or too small.\n", .{}) catch return,
            error.OutOfMemory => writer.print("Out of memory.\n", .{}) catch return,
            else => writer.print("An unexpected error occurred: {any}\n", .{err}) catch return,
        }
    }

    /// The main entry point for running the CLI application.
    /// This function handles process arguments, invokes `execute`, and prints formatted errors.
    pub fn run(self: *Command, data: ?*anyopaque) !void {
        if (self.options.version != null) {
            try self.addFlag(.{
                .name = "version",
                .description = "Print version information and exit",
                .type = .Bool,
                .default_value = .{ .Bool = false },
            });
        }

        var args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        var failed_cmd: ?*const Command = null;
        self.execute(args[1..], data, &failed_cmd) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            handleExecutionError(self.allocator, err, failed_cmd, stderr);
            std.process.exit(1);
        };
    }

    /// (private) Constructs the full command path (e.g., "root sub") for use in help and error messages.
    /// The returned slice is allocated using the provided allocator and must be freed by the caller.
    fn getCommandPath(self: *const Command, allocator: std.mem.Allocator) ![]const u8 {
        var path_parts: std.ArrayList([]const u8) = .{};
        defer path_parts.deinit(allocator);

        var current: ?*const Command = self;
        while (current) |cmd| {
            try path_parts.append(allocator, cmd.options.name);
            current = cmd.parent;
        }
        std.mem.reverse([]const u8, path_parts.items);

        return std.mem.join(allocator, " ", path_parts.items);
    }

    // ... other functions from findSubcommand to printHelp remain unchanged ...
    /// Finds a direct subcommand by its name, alias, or shortcut.
    pub fn findSubcommand(self: *Command, name: []const u8) ?*Command {
        for (self.subcommands.items) |sub| {
            if (std.mem.eql(u8, sub.options.name, name)) return sub;
            if (sub.options.shortcut) |s| {
                if (name.len == 1 and s == name[0]) return sub;
            }
            if (sub.options.aliases) |a| {
                for (a) |alias| {
                    if (std.mem.eql(u8, alias, name)) return sub;
                }
            }
        }
        return null;
    }

    /// Finds a flag definition by its full name (e.g., "verbose"), searching upwards through parent commands.
    pub fn findFlag(self: *Command, name: []const u8) ?*types.Flag {
        var current: ?*Command = self;
        while (current) |cmd| {
            for (cmd.flags.items) |*flag| {
                if (std.mem.eql(u8, flag.name, name)) return flag;
            }
            current = cmd.parent;
        }
        return null;
    }

    /// Finds a flag definition by its shortcut (e.g., 'v'), searching upwards through parent commands.
    pub fn findFlagByShortcut(self: *Command, shortcut: u8) ?*types.Flag {
        var current: ?*Command = self;
        while (current) |cmd| {
            for (cmd.flags.items) |*flag| {
                if (flag.shortcut) |s| {
                    if (s == shortcut) return flag;
                }
            }
            current = cmd.parent;
        }
        return null;
    }

    /// (Internal) Retrieves the parsed value of a flag, searching upwards through
    /// parent commands. This mirrors `findFlag` and allows subcommand exec functions
    /// to access flags that were parsed at a parent command level.
    pub fn getFlagValue(self: *const Command, name: []const u8) ?types.FlagValue {
        var current: ?*const Command = self;
        while (current) |cmd| {
            for (cmd.parsed_flags.items) |flag| {
                if (std.mem.eql(u8, flag.name, name)) return flag.value;
            }
            current = cmd.parent;
        }
        return null;
    }

    /// (Internal) Retrieves the parsed value of a positional argument by its index.
    pub fn getPositionalValue(self: *const Command, index: usize) ?[]const u8 {
        if (index < self.parsed_positionals.items.len) return self.parsed_positionals.items[index];
        return null;
    }

    /// Prints a formatted help message for the command to standard output.
    pub fn printHelp(self: *const Command) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("{s}{s}{s}\n", .{ utils.styles.BOLD, self.options.description, utils.styles.RESET });

        if (self.options.version) |version| {
            try stdout.print("{s}Version: {s}{s}\n", .{ utils.styles.DIM, version, utils.styles.RESET });
        }
        try stdout.print("\n", .{});

        try stdout.print("{s}Usage:{s}\n", .{ utils.styles.BOLD, utils.styles.RESET });
        try utils.printUsageLine(self, stdout);

        if (self.positional_args.items.len > 0) {
            try stdout.print("{s}Arguments:{s}\n", .{ utils.styles.BOLD, utils.styles.RESET });
            try utils.printAlignedPositionalArgs(self, stdout);
            try stdout.print("\n", .{});
        }

        if (self.flags.items.len > 0) {
            try stdout.print("{s}Flags:{s}\n", .{ utils.styles.BOLD, utils.styles.RESET });
            try utils.printAlignedFlags(self, stdout);
            try stdout.print("\n", .{});
        }

        if (self.subcommands.items.len > 0) {
            try utils.printSubcommands(self, stdout);
        }
    }
};

// Tests for the `command` module

const testing = std.testing;

fn dummyExec(_: context.CommandContext) !void {}

test "command: findSubcommand by alias and shortcut" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();

    const sub = try Command.init(allocator, .{
        .name = "sub",
        .description = "",
        .aliases = &[_][]const u8{ "alias1", "alias2" },
        .shortcut = 's',
        .exec = dummyExec,
    });

    try root.addSubcommand(sub);
    try testing.expect(root.findSubcommand("sub").? == sub);
    try testing.expect(root.findSubcommand("alias1").? == sub);
    try testing.expect(root.findSubcommand("alias2").? == sub);
    try testing.expect(root.findSubcommand("s").? == sub);
    try testing.expect(root.findSubcommand("nonexistent") == null);
}

var integration_flag_val: bool = false;
var integration_arg_val: []const u8 = "";

fn integrationExec(ctx: context.CommandContext) !void {
    integration_flag_val = try ctx.getFlag("verbose", bool);
    integration_arg_val = try ctx.getArg("file", []const u8);
}

test "command: execute with args and flags" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();
    var sub = try Command.init(allocator, .{ .name = "sub", .description = "", .exec = integrationExec });
    try root.addSubcommand(sub);

    try sub.addFlag(.{ .name = "verbose", .shortcut = 'v', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });
    try sub.addPositional(.{ .name = "file", .is_required = true, .description = "" });

    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "sub", "--verbose", "input.txt" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    try testing.expect(integration_flag_val);
    try testing.expectEqualStrings("input.txt", integration_arg_val);
}

// -- Tests for flags before subcommand (issue #12) --

var parent_flag_from_sub: []const u8 = "";

fn parentFlagExec(ctx: context.CommandContext) !void {
    parent_flag_from_sub = try ctx.getFlag("config", []const u8);
    integration_arg_val = try ctx.getArg("file", []const u8);
}

test "command: root flag before subcommand resolves subcommand" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer root.deinit();

    try root.addFlag(.{ .name = "config", .type = .String, .default_value = .{ .String = "default.conf" }, .description = "" });

    var sub = try Command.init(allocator, .{ .name = "run", .description = "", .exec = parentFlagExec });
    try root.addSubcommand(sub);
    try sub.addPositional(.{ .name = "file", .is_required = true, .description = "" });

    // The exact pattern from the bug report: --config <value> run <arg>
    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "--config", "custom.conf", "run", "input.txt" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    try testing.expectEqualStrings("input.txt", integration_arg_val);
}

test "command: root short flag before subcommand resolves subcommand" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer root.deinit();

    try root.addFlag(.{ .name = "verbose", .shortcut = 'v', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });

    exec_called_on = null;
    const sub = try Command.init(allocator, .{ .name = "run", .description = "", .exec = trackingExec });
    try root.addSubcommand(sub);

    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "-v", "run" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    try testing.expectEqualStrings("run", exec_called_on.?);
}

test "command: multiple root flags before subcommand" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer root.deinit();

    try root.addFlag(.{ .name = "verbose", .shortcut = 'v', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });
    try root.addFlag(.{ .name = "config", .type = .String, .default_value = .{ .String = "default.conf" }, .description = "" });

    exec_called_on = null;
    const sub = try Command.init(allocator, .{ .name = "run", .description = "", .exec = trackingExec });
    try root.addSubcommand(sub);

    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "-v", "--config=custom.conf", "run" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    try testing.expectEqualStrings("run", exec_called_on.?);
}

test "command: getFlagValue traverses parents" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer root.deinit();

    try root.addFlag(.{ .name = "config", .type = .String, .default_value = .{ .String = "default.conf" }, .description = "" });

    var sub = try Command.init(allocator, .{ .name = "run", .description = "", .exec = parentFlagExec });
    try root.addSubcommand(sub);
    try sub.addPositional(.{ .name = "file", .is_required = true, .description = "" });

    parent_flag_from_sub = "";
    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "--config", "custom.conf", "run", "input.txt" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    // The subcommand's exec must see the root-level --config value, not the default
    try testing.expectEqualStrings("custom.conf", parent_flag_from_sub);
}

test "command: -- before subcommand stops resolution" {
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer root.deinit();

    exec_called_on = null;
    const sub = try Command.init(allocator, .{ .name = "run", .description = "", .exec = trackingExec });
    try root.addSubcommand(sub);
    try root.addPositional(.{ .name = "arg", .is_required = true, .description = "" });

    var failed_cmd: ?*const Command = null;
    // -- stops subcommand resolution, so "run" becomes a positional for root
    const args = &[_][]const u8{ "--", "run" };
    try root.execute(args, null, &failed_cmd);

    try testing.expect(failed_cmd == null);
    try testing.expectEqualStrings("app", exec_called_on.?);
}

test "command: addSubcommand detects empty alias" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();

    var sub_bad = try Command.init(allocator, .{
        .name = "bad",
        .description = "",
        .aliases = &.{ "", "b" },
        .exec = dummyExec,
    });
    defer sub_bad.deinit();

    try std.testing.expectError(error.EmptyAlias, root.addSubcommand(sub_bad));
}

test "command: addFlag detects duplicates" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{ .name = "output", .description = "", .type = .String, .default_value = .{ .String = "" } });
    try cmd.addFlag(.{ .name = "verbose", .shortcut = 'v', .description = "", .type = .Bool, .default_value = .{ .Bool = false } });

    // Expect error for duplicate name
    try std.testing.expectError(error.DuplicateFlag, cmd.addFlag(.{
        .name = "output",
        .description = "",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    }));

    // Expect error for duplicate shortcut
    try std.testing.expectError(error.DuplicateFlag, cmd.addFlag(.{
        .name = "volume",
        .shortcut = 'v',
        .description = "",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    }));
}

test "command: addPositional argument order" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "optional", .is_required = false, .default_value = .{ .String = "" } });
    try std.testing.expectError(error.RequiredArgumentAfterOptional, cmd.addPositional(.{
        .name = "required",
        .is_required = true,
    }));
}

// ... other tests from `addPositional validation` to `getCommandPath` remain unchanged ...
test "command: addPositional validation" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "a", .is_required = true });
    try cmd.addPositional(.{ .name = "b", .variadic = true });

    try std.testing.expectError(
        error.VariadicArgumentNotLastError,
        cmd.addPositional(.{ .name = "c", .is_required = true }),
    );
}

test "command: init and deinit" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "",
        .exec = dummyExec,
    });
    defer cmd.deinit();
    try std.testing.expectEqualStrings("test", cmd.options.name);
    try std.testing.expect(cmd.findFlag("help") != null);
}

test "command: subcommands" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();
    const sub = try Command.init(allocator, .{ .name = "sub", .description = "", .exec = dummyExec });

    try root.addSubcommand(sub);
    try std.testing.expect(root.findSubcommand("sub").? == sub);
    try std.testing.expect(sub.parent.? == root);
}

test "command: findFlag traverses parents" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();
    var sub = try Command.init(allocator, .{ .name = "sub", .description = "", .exec = dummyExec });
    try root.addSubcommand(sub);

    try root.addFlag(.{ .name = "global", .shortcut = 'g', .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });

    try std.testing.expect(sub.findFlag("global") != null);
    try std.testing.expect(sub.findFlagByShortcut('g') != null);
}

var exec_called_on: ?[]const u8 = null;
fn trackingExec(ctx: context.CommandContext) !void {
    exec_called_on = ctx.command.options.name;
}

test "command: execute" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = trackingExec });
    defer root.deinit();
    const sub = try Command.init(allocator, .{ .name = "sub", .description = "", .exec = trackingExec });
    try root.addSubcommand(sub);

    exec_called_on = null;
    var failed_cmd: ?*const Command = null;
    try root.execute(&[_][]const u8{}, null, &failed_cmd);
    try std.testing.expectEqualStrings("root", exec_called_on.?);

    exec_called_on = null;
    try root.execute(&[_][]const u8{"sub"}, null, &failed_cmd);
    try std.testing.expectEqualStrings("sub", exec_called_on.?);
}

test "command: getCommandPath" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();
    var sub1 = try Command.init(allocator, .{ .name = "sub1", .description = "", .exec = dummyExec });
    try root.addSubcommand(sub1);
    var sub2 = try Command.init(allocator, .{ .name = "sub2", .description = "", .exec = dummyExec });
    try sub1.addSubcommand(sub2);

    var path = try root.getCommandPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("root", path);

    path = try sub1.getCommandPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("root sub1", path);

    path = try sub2.getCommandPath(allocator);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("root sub1 sub2", path);
}

test "command: handleExecutionError provides context" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    var root_cmd = try Command.init(allocator, .{ .name = "test-cmd", .description = "", .exec = dummyExec });
    defer root_cmd.deinit();

    // Test with context
    fbs.pos = 0;
    Command.handleExecutionError(allocator, error.TooManyArguments, root_cmd, writer);
    var written = fbs.getWritten();
    try std.testing.expect(std.mem.endsWith(u8, written, "Error: Too many arguments provided for command 'test-cmd'.\n"));

    // Test without context
    fbs.pos = 0;
    Command.handleExecutionError(allocator, error.TooManyArguments, null, writer);
    written = fbs.getWritten();
    try std.testing.expect(std.mem.endsWith(u8, written, "Error: Too many arguments provided.\n"));
}

test "command: handleExecutionError silent on broken pipe" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    Command.handleExecutionError(allocator, error.BrokenPipe, null, writer);
    try std.testing.expectEqualStrings("", fbs.getWritten());
}
