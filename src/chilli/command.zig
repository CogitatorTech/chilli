//! The core module for defining, managing, and executing commands.
const std = @import("std");
const parser = @import("parser.zig");
const context = @import("context.zig");
const styles = @import("styles.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

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
    options: CommandOptions,
    subcommands: std.ArrayList(*Command),
    flags: std.ArrayList(types.Flag),
    positional_args: std.ArrayList(types.PositionalArg),
    parent: ?*Command,
    allocator: std.mem.Allocator,
    parsed_flags: std.ArrayList(parser.ParsedFlag),
    parsed_positionals: std.ArrayList([]const u8),

    /// Initializes a new command.
    /// Panics if the provided command name is empty.
    pub fn init(allocator: std.mem.Allocator, options: CommandOptions) !*Command {
        if (options.name.len == 0) {
            std.debug.panic("Command name cannot be empty.", .{});
        }

        const command = try allocator.create(Command);
        // On any failure past this point, free the struct so the allocation
        // does not leak. `addFlag` below can fail on OOM.
        errdefer allocator.destroy(command);

        command.* = Command{
            .options = options,
            .subcommands = .empty,
            .flags = .empty,
            .positional_args = .empty,
            .parent = null,
            .allocator = allocator,
            .parsed_flags = .empty,
            .parsed_positionals = .empty,
        };
        // If addFlag fails below, also release any ArrayList backing storage
        // that may have been partially initialised.
        errdefer {
            command.flags.deinit(allocator);
            command.subcommands.deinit(allocator);
            command.positional_args.deinit(allocator);
            command.parsed_flags.deinit(allocator);
            command.parsed_positionals.deinit(allocator);
        }

        const help_flag = types.Flag{
            .name = "help",
            .shortcut = 'h',
            .description = "Shows help information for this command",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        };
        try command.addFlag(help_flag);

        // Add the automatic --version flag up-front if the caller asked for
        // one. Doing it here (rather than in `run`) keeps `run` idempotent
        // across repeated invocations on the same command tree.
        if (options.version != null) {
            try command.addFlag(.{
                .name = "version",
                .description = "Print version information and exit",
                .type = .Bool,
                .default_value = .{ .Bool = false },
            });
        }

        return command;
    }

    /// Deinitializes the command and all its subcommands recursively.
    ///
    /// This function should ONLY be called on the root command of the application.
    /// It recursively deinitializes all child and grandchild commands. Calling `deinit`
    /// on a subcommand that has a parent will panic, because the resulting free
    /// would collide with the root's sweep and cause a double-free.
    pub fn deinit(self: *Command) void {
        if (self.parent != null) {
            std.debug.panic(
                "Command.deinit was called on subcommand '{s}', which is still attached to parent '{s}'. " ++
                    "Only call deinit on the root command; it recursively frees its subcommands.",
                .{ self.options.name, self.parent.?.options.name },
            );
        }
        for (self.subcommands.items) |sub| {
            // Disown the child before recursing so its own parent-check passes.
            sub.parent = null;
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

    /// Resets `parsed_flags` and `parsed_positionals` on this command and
    /// every descendant. Used by `execute` so that a re-entering call sees
    /// a clean tree even on branches that were visited by a previous call
    /// but are not visited by the current one.
    fn resetParsedStateRecursive(self: *Command) void {
        self.parsed_flags.shrinkRetainingCapacity(0);
        self.parsed_positionals.shrinkRetainingCapacity(0);
        for (self.subcommands.items) |sub| {
            sub.resetParsedStateRecursive();
        }
    }

    /// Parses arguments and executes the appropriate command. This is the core logic loop.
    pub fn execute(self: *Command, user_args: []const []const u8, data: ?*anyopaque, out_failed_cmd: *?*const Command) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var arg_iterator = parser.ArgIterator.init(user_args);

        var current_cmd: *Command = self;
        out_failed_cmd.* = current_cmd;

        // Reset parsed state on the entire tree so stale values from a
        // prior `execute` invocation on an unvisited branch do not leak
        // into this run.
        self.resetParsedStateRecursive();

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
                    const io = std.Options.debug_io;
                    var version_buf: [256]u8 = undefined;
                    var stdout_fw = std.Io.File.stdout().writer(io, &version_buf);
                    try stdout_fw.interface.print("{s}\n", .{self.options.version.?});
                    try stdout_fw.flush();
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
        const red = styles.s(styles.RED);
        const reset = styles.s(styles.RESET);

        switch (err) {
            error.BrokenPipe => return, // Exit silently on broken pipe
            else => {},
        }

        writer.print("{s}Error:{s} ", .{ red, reset }) catch return;

        switch (err) {
            error.MissingRequiredArgument => {
                if (failed_cmd) |cmd| {
                    if (cmd.getCommandPath(allocator)) |path| {
                        defer allocator.free(path);
                        writer.print("Missing a required argument for command '{s}'.\n", .{path}) catch return;
                    } else |_| {
                        writer.print("Missing a required argument for command '{s}'.\n", .{cmd.options.name}) catch return;
                    }
                } else {
                    writer.print("Missing a required argument.\n", .{}) catch return;
                }
            },
            error.TooManyArguments => {
                if (failed_cmd) |cmd| {
                    if (cmd.getCommandPath(allocator)) |path| {
                        defer allocator.free(path);
                        writer.print("Too many arguments provided for command '{s}'.\n", .{path}) catch return;
                    } else |_| {
                        writer.print("Too many arguments provided for command '{s}'.\n", .{cmd.options.name}) catch return;
                    }
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
    pub fn run(self: *Command, args: std.process.Args, data: ?*anyopaque) !void {
        // Note: the automatic --version flag is added in `init` so `run` is
        // safe to call more than once on the same command.

        // Collect process arguments via iterator
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);
        var args_iter = std.process.Args.Iterator.init(args);
        defer args_iter.deinit();
        while (args_iter.next()) |arg| {
            try args_list.append(self.allocator, arg);
        }
        const user_args = if (args_list.items.len > 1) args_list.items[1..] else args_list.items[0..0];

        var failed_cmd: ?*const Command = null;
        self.execute(user_args, data, &failed_cmd) catch |err| {
            const io = std.Options.debug_io;
            var stderr_buf: [4096]u8 = undefined;
            var stderr_fw = std.Io.File.stderr().writer(io, &stderr_buf);
            handleExecutionError(self.allocator, err, failed_cmd, &stderr_fw.interface);
            stderr_fw.flush() catch {};
            std.process.exit(1);
        };
    }

    /// (private) Constructs the full command path (e.g., "root sub") for use in help and error messages.
    /// The returned slice is allocated using the provided allocator and must be freed by the caller.
    fn getCommandPath(self: *const Command, allocator: std.mem.Allocator) ![]const u8 {
        var path_parts: std.ArrayList([]const u8) = .empty;
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
    ///
    /// Within a single command's parsed flags, the *last* specified value wins
    /// (matching how getopt, clap, cobra, etc. handle repeated flags), so
    /// `--config foo --config bar` returns `bar`.
    pub fn getFlagValue(self: *const Command, name: []const u8) ?types.FlagValue {
        var current: ?*const Command = self;
        while (current) |cmd| {
            var i: usize = cmd.parsed_flags.items.len;
            while (i > 0) {
                i -= 1;
                const flag = cmd.parsed_flags.items[i];
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
        const io = std.Options.debug_io;
        var buf: [4096]u8 = undefined;
        var file_writer = std.Io.File.stdout().writer(io, &buf);
        const stdout = &file_writer.interface;
        const bold = styles.s(styles.BOLD);
        const dim = styles.s(styles.DIM);
        const reset = styles.s(styles.RESET);

        try stdout.print("{s}{s}{s}\n", .{ bold, self.options.description, reset });

        if (self.options.version) |version| {
            try stdout.print("{s}Version: {s}{s}\n", .{ dim, version, reset });
        }
        try stdout.print("\n", .{});

        try stdout.print("{s}Usage:{s}\n", .{ bold, reset });
        try printUsageLine(self, stdout);

        if (self.positional_args.items.len > 0) {
            try stdout.print("{s}Arguments:{s}\n", .{ bold, reset });
            try printAlignedPositionalArgs(self, stdout);
            try stdout.print("\n", .{});
        }

        if (self.flags.items.len > 0) {
            try stdout.print("{s}Flags:{s}\n", .{ bold, reset });
            try printAlignedFlags(self, stdout);
            try stdout.print("\n", .{});
        }

        if (self.subcommands.items.len > 0) {
            try printSubcommands(self, stdout);
        }
        try file_writer.flush();
    }
};

// ============================================================================
// Help-output printers (private)
// ============================================================================
// These used to live in utils.zig. They were moved here because they depend
// on Command's internals (flags, positional_args, subcommands, parent chain),
// and keeping them in a separate module created a utils <-> command import
// cycle that the refactor set out to eliminate. They are intentionally not
// `pub` — help output is a Command concern, not a public extension point.

fn printAlignedCommands(commands: []*Command, writer: anytype) !void {
    var max_width: usize = 0;
    for (commands) |cmd| {
        var len = cmd.options.name.len;
        if (cmd.options.shortcut != null) {
            len += 4; // " (c)"
        }
        if (len > max_width) max_width = len;
    }

    for (commands) |cmd| {
        try writer.print("  {s}", .{cmd.options.name});
        var current_width = cmd.options.name.len;
        if (cmd.options.shortcut) |sc| {
            try writer.print(" ({c})", .{sc});
            current_width += 4;
        }

        for (0..max_width - current_width + 2) |_| try writer.writeByte(' ');
        try writer.print("{s}\n", .{cmd.options.description});
    }
}

fn printAlignedFlags(cmd: *const Command, writer: anytype) !void {
    var max_width: usize = 0;
    for (cmd.flags.items) |flag| {
        if (flag.hidden) continue;
        const len: usize = if (flag.shortcut != null)
            // "  -c, --name"
            flag.name.len + 8
        else
            // "      --name"
            flag.name.len + 8;
        if (len > max_width) max_width = len;
    }

    for (cmd.flags.items) |flag| {
        if (flag.hidden) continue;

        var current_width: usize = undefined;
        if (flag.shortcut) |sc| {
            try writer.print("  -{c}, --{s}", .{ sc, flag.name });
            current_width = flag.name.len + 8;
        } else {
            try writer.print("      --{s}", .{flag.name});
            current_width = flag.name.len + 8;
        }

        for (0..max_width - current_width + 2) |_| try writer.writeByte(' ');
        try writer.print("{s} [{s}]", .{ flag.description, @tagName(flag.type) });

        switch (flag.default_value) {
            .Bool => |v| try writer.print(" (default: {})", .{v}),
            .Int => |v| try writer.print(" (default: {})", .{v}),
            .Float => |v| try writer.print(" (default: {})", .{v}),
            .String => |v| try writer.print(" (default: \"{s}\")", .{v}),
        }
        try writer.print("\n", .{});
    }
}

fn printAlignedPositionalArgs(cmd: *const Command, writer: anytype) !void {
    var max_width: usize = 0;
    for (cmd.positional_args.items) |arg| {
        if (arg.name.len > max_width) max_width = arg.name.len;
    }

    for (cmd.positional_args.items) |arg| {
        try writer.print("  {s}", .{arg.name});
        for (0..max_width - arg.name.len + 2) |_| try writer.writeByte(' ');
        try writer.print("{s}", .{arg.description});

        if (arg.variadic) {
            try writer.print(" (variadic)\n", .{});
        } else if (arg.is_required) {
            try writer.print(" (required)\n", .{});
        } else {
            try writer.print(" (optional)\n", .{});
        }
    }
}

fn printUsageLine(cmd: *const Command, writer: anytype) !void {
    var parents: std.ArrayList(*Command) = .empty;
    defer parents.deinit(cmd.allocator);

    var current_parent = cmd.parent;
    while (current_parent) |p| {
        try parents.append(cmd.allocator, p);
        current_parent = p.parent;
    }
    std.mem.reverse(*Command, parents.items);

    if (parents.items.len > 0) {
        try writer.print("  {s}", .{parents.items[0].options.name});
        for (parents.items[1..]) |p| {
            try writer.print(" {s}", .{p.options.name});
        }
        try writer.print(" {s}", .{cmd.options.name});
    } else {
        try writer.print("  {s}", .{cmd.options.name});
    }

    if (cmd.flags.items.len > 0) {
        try writer.print(" [flags]", .{});
    }

    for (cmd.positional_args.items) |arg| {
        if (arg.variadic) {
            try writer.print(" [{s}...]", .{arg.name});
        } else if (arg.is_required) {
            try writer.print(" <{s}>", .{arg.name});
        } else {
            try writer.print(" [{s}]", .{arg.name});
        }
    }

    if (cmd.subcommands.items.len > 0) {
        try writer.print(" [command]", .{});
    }

    try writer.print("\n\n", .{});
}

const CommandSortContext = struct {
    pub fn lessThan(_: @This(), a: *Command, b: *Command) bool {
        return std.mem.order(u8, a.options.name, b.options.name) == .lt;
    }
};

const StringSortContext = struct {
    pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

fn printSubcommands(cmd: *const Command, writer: anytype) !void {
    var section_map = std.StringHashMap(std.ArrayList(*Command)).init(cmd.allocator);
    defer {
        var it = section_map.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit(cmd.allocator);
        section_map.deinit();
    }

    for (cmd.subcommands.items) |sub| {
        const list = try section_map.getOrPut(sub.options.section);
        if (!list.found_existing) {
            list.value_ptr.* = .empty;
        }
        try list.value_ptr.*.append(cmd.allocator, sub);
    }

    var sorted_sections: std.ArrayList([]const u8) = .empty;
    defer sorted_sections.deinit(cmd.allocator);
    var it = section_map.keyIterator();
    while (it.next()) |key| try sorted_sections.append(cmd.allocator, key.*);
    std.sort.pdq([]const u8, sorted_sections.items, StringSortContext{}, StringSortContext.lessThan);

    for (sorted_sections.items) |section_name| {
        try writer.print("{s}{s}{s}:\n", .{ styles.s(styles.BOLD), section_name, styles.s(styles.RESET) });
        const cmds_list = section_map.get(section_name).?;
        std.sort.pdq(*Command, cmds_list.items, CommandSortContext{}, CommandSortContext.lessThan);
        try printAlignedCommands(cmds_list.items, writer);
        try writer.print("\n", .{});
    }
}

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
    var root = try Command.init(allocator, .{ .name = "app", .description = "", .exec = trackingExec });
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

    try cmd.addPositional(.{ .name = "optional", .is_required = false, .default_value = .{ .String = "" }, .description = "" });
    try std.testing.expectError(error.RequiredArgumentAfterOptional, cmd.addPositional(.{
        .name = "required",
        .is_required = true,
        .description = "",
    }));
}

// ... other tests from `addPositional validation` to `getCommandPath` remain unchanged ...
test "command: addPositional validation" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "a", .is_required = true, .description = "" });
    try cmd.addPositional(.{ .name = "b", .variadic = true, .description = "" });

    try std.testing.expectError(
        error.VariadicArgumentNotLastError,
        cmd.addPositional(.{ .name = "c", .is_required = true, .description = "" }),
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

    const path1 = try root.getCommandPath(allocator);
    defer allocator.free(path1);
    try std.testing.expectEqualStrings("root", path1);

    const path2 = try sub1.getCommandPath(allocator);
    defer allocator.free(path2);
    try std.testing.expectEqualStrings("root sub1", path2);

    const path3 = try sub2.getCommandPath(allocator);
    defer allocator.free(path3);
    try std.testing.expectEqualStrings("root sub1 sub2", path3);
}

const TestBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn print(self: *TestBufWriter, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void {
        const result = std.fmt.bufPrint(self.buf[self.pos..], fmt, args) catch return error.NoSpaceLeft;
        self.pos += result.len;
    }

    fn writeByte(self: *TestBufWriter, byte: u8) error{NoSpaceLeft}!void {
        if (self.pos >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn getWritten(self: TestBufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

test "command: handleExecutionError provides context" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };

    var root_cmd = try Command.init(allocator, .{ .name = "test-cmd", .description = "", .exec = dummyExec });
    defer root_cmd.deinit();

    // Test with context
    writer.pos = 0;
    Command.handleExecutionError(allocator, error.TooManyArguments, root_cmd, &writer);
    var written = writer.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "Too many arguments provided for command 'test-cmd'.\n") != null);

    // Test without context
    writer.pos = 0;
    Command.handleExecutionError(allocator, error.TooManyArguments, null, &writer);
    written = writer.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "Too many arguments provided.\n") != null);
}

test "command: handleExecutionError silent on broken pipe" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };

    Command.handleExecutionError(allocator, error.BrokenPipe, null, &writer);
    try std.testing.expectEqualStrings("", writer.getWritten());
}

test "command: Args.Iterator collects arguments and skips argv0" {
    // Args.Vector is platform-specific: [*:0]const u8 on POSIX, []const u16 on Windows.
    // This test constructs a POSIX-style argv directly, so it only runs on POSIX targets.
    if (comptime @import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;

    // Simulate argv: ["program", "sub", "--flag", "value"]
    const argv = [_][*:0]const u8{ "program", "sub", "--flag", "value" };
    const args: std.process.Args = .{ .vector = &argv };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(args);
    defer args_iter.deinit();
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    // All 4 args collected
    try std.testing.expectEqual(@as(usize, 4), args_list.items.len);
    try std.testing.expectEqualStrings("program", args_list.items[0]);
    try std.testing.expectEqualStrings("sub", args_list.items[1]);

    // argv0 skip logic (same as run())
    const user_args = if (args_list.items.len > 1) args_list.items[1..] else args_list.items[0..0];
    try std.testing.expectEqual(@as(usize, 3), user_args.len);
    try std.testing.expectEqualStrings("sub", user_args[0]);
    try std.testing.expectEqualStrings("--flag", user_args[1]);
    try std.testing.expectEqualStrings("value", user_args[2]);
}

test "command: Args.Iterator with empty argv produces no user args" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;

    const argv = [_][*:0]const u8{};
    const args: std.process.Args = .{ .vector = &argv };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(args);
    defer args_iter.deinit();
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const user_args = if (args_list.items.len > 1) args_list.items[1..] else args_list.items[0..0];
    try std.testing.expectEqual(@as(usize, 0), user_args.len);
}

test "regression: init with version auto-adds --version flag" {
    // Bug: `--version` was added inside `run`, so the flag was missing
    // if the user called `execute` directly and re-adding it on a second
    // `run` caused DuplicateFlag errors. Fix: add it in `init`.
    const allocator = testing.allocator;
    var cmd = try Command.init(allocator, .{
        .name = "app",
        .description = "",
        .version = "v1.0",
        .exec = dummyExec,
    });
    defer cmd.deinit();

    try std.testing.expect(cmd.findFlag("version") != null);
    try std.testing.expect(cmd.findFlag("help") != null);
}

test "regression: init without version does not add --version flag" {
    const allocator = testing.allocator;
    var cmd = try Command.init(allocator, .{
        .name = "app",
        .description = "",
        .exec = dummyExec,
    });
    defer cmd.deinit();

    try std.testing.expect(cmd.findFlag("version") == null);
    try std.testing.expect(cmd.findFlag("help") != null);
}

test "regression: getFlagValue returns last-specified value for repeated flag" {
    // Bug: iterating parsed_flags front-to-back returned the *first* value,
    // so `--config a --config b` resolved as `a`. Standard CLI semantics
    // are last-wins; fix reverses the iteration inside getFlagValue.
    const allocator = testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{ .name = "config", .type = .String, .default_value = .{ .String = "default" }, .description = "" });

    var failed_cmd: ?*const Command = null;
    const args = &[_][]const u8{ "--config", "first", "--config=second", "--config", "third" };
    try cmd.execute(args, null, &failed_cmd);

    const val = cmd.getFlagValue("config").?;
    try std.testing.expectEqualStrings("third", val.String);
}

test "regression: execute wipes stale state on unvisited subcommands" {
    // Bug: execute only reset parsed_flags/parsed_positionals on commands
    // along the current resolution chain. Running the same root twice with
    // different arg sequences left stale state on branches unvisited by
    // the second run.
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();

    var sub_a = try Command.init(allocator, .{ .name = "a", .description = "", .exec = dummyExec });
    try root.addSubcommand(sub_a);
    try sub_a.addFlag(.{ .name = "verbose", .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });

    const sub_b = try Command.init(allocator, .{ .name = "b", .description = "", .exec = dummyExec });
    try root.addSubcommand(sub_b);

    // First run: exercise sub_a; sub_a now has parsed_flags populated.
    var failed_cmd: ?*const Command = null;
    try root.execute(&[_][]const u8{ "a", "--verbose" }, null, &failed_cmd);
    try std.testing.expect(sub_a.parsed_flags.items.len > 0);

    // Second run: take the sub_b branch instead. sub_a is not visited and
    // must be scrubbed so a later `getFlagValue("verbose")` via sub_a does
    // not see the stale `true` value from the first run.
    try root.execute(&[_][]const u8{"b"}, null, &failed_cmd);
    try std.testing.expectEqual(@as(usize, 0), sub_a.parsed_flags.items.len);
}

test "regression: deinit panics on a subcommand still attached to a parent" {
    // Bug: calling `sub.deinit()` directly while sub was attached to root
    // would cause a double-free when the root later ran its recursive sweep.
    // Fix: deinit panics if `parent != null`. This test verifies the
    // detached/disowned path works (the panic path cannot be tested without
    // subprocess isolation).
    const allocator = testing.allocator;
    var root = try Command.init(allocator, .{ .name = "root", .description = "", .exec = dummyExec });
    defer root.deinit();
    const sub = try Command.init(allocator, .{ .name = "sub", .description = "", .exec = dummyExec });
    try root.addSubcommand(sub);

    try std.testing.expect(sub.parent.? == root);
    // Root's deinit should disown sub before calling sub.deinit, so the
    // recursive sweep does not hit the parent-check panic.
}

test "command: Args.Iterator with only argv0 produces no user args" {
    if (comptime @import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;

    const argv = [_][*:0]const u8{"program"};
    const args: std.process.Args = .{ .vector = &argv };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(args);
    defer args_iter.deinit();
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const user_args = if (args_list.items.len > 1) args_list.items[1..] else args_list.items[0..0];
    try std.testing.expectEqual(@as(usize, 0), user_args.len);
}

// ============================================================================
// Tests for the help-output printers (moved from utils.zig)
// ============================================================================

test "help: printAlignedFlags produces correct padding" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .description = "Enable verbose output",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    var buf: [2048]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };
    try printAlignedFlags(cmd, &writer);

    const output = writer.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Enable verbose output") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  ") != null);
}

test "help: printAlignedPositionalArgs produces correct padding" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "input", .description = "Input file", .is_required = true });
    try cmd.addPositional(.{ .name = "output-file", .description = "Output file", .is_required = false, .default_value = .{ .String = "out.txt" } });

    var buf: [2048]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };
    try printAlignedPositionalArgs(cmd, &writer);

    const output = writer.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "input") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "output-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(required)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(optional)") != null);
}

test "help: printUsageLine produces correct output" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, .{ .name = "app", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addPositional(.{ .name = "file", .description = "A file", .is_required = true });

    var buf: [2048]u8 = undefined;
    var writer = TestBufWriter{ .buf = &buf };
    try printUsageLine(cmd, &writer);

    const output = writer.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "app") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[flags]") != null);
}
