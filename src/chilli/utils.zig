//! A collection of utility functions for formatting help messages and parsing values.
const std = @import("std");
const command = @import("command.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

/// A collection of ANSI escape codes for styling terminal output.
pub const styles = struct {
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

/// Prints a list of commands with aligned descriptions.
pub fn printAlignedCommands(commands: []*command.Command, writer: anytype) !void {
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
        if (cmd.options.shortcut) |s| {
            try writer.print(" ({c})", .{s});
            current_width += 4;
        }

        for (0..max_width - current_width + 2) |_| try writer.writeByte(' ');
        try writer.print("{s}\n", .{cmd.options.description});
    }
}

/// Prints a command's flags with aligned descriptions.
pub fn printAlignedFlags(cmd: *const command.Command, writer: anytype) !void {
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
        if (flag.shortcut) |s| {
            try writer.print("  -{c}, --{s}", .{ s, flag.name });
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

/// Prints a command's positional arguments with aligned descriptions.
pub fn printAlignedPositionalArgs(cmd: *const command.Command, writer: anytype) !void {
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

/// Prints the full usage line for a command, including its parents.
pub fn printUsageLine(cmd: *const command.Command, writer: anytype) !void {
    var parents: std.ArrayList(*command.Command) = .empty;
    defer parents.deinit(cmd.allocator);

    var current_parent = cmd.parent;
    while (current_parent) |p| {
        try parents.append(cmd.allocator, p);
        current_parent = p.parent;
    }
    std.mem.reverse(*command.Command, parents.items);

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
    pub fn lessThan(_: @This(), a: *command.Command, b: *command.Command) bool {
        return std.mem.order(u8, a.options.name, b.options.name) == .lt;
    }
};

const StringSortContext = struct {
    pub fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// Prints subcommands grouped by section and sorted alphabetically.
pub fn printSubcommands(cmd: *const command.Command, writer: anytype) !void {
    var section_map = std.StringHashMap(std.ArrayList(*command.Command)).init(cmd.allocator);
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
        try writer.print("{s}{s}{s}:\n", .{ styles.BOLD, section_name, styles.RESET });
        const cmds_list = section_map.get(section_name).?;
        std.sort.pdq(*command.Command, cmds_list.items, CommandSortContext{}, CommandSortContext.lessThan);
        try printAlignedCommands(cmds_list.items, writer);
        try writer.print("\n", .{});
    }
}

// Tests for the `utils` module

test "utils: parseBool" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("TRUE"));
    try std.testing.expect(!(try parseBool("false")));
    try std.testing.expect(!(try parseBool("FALSE")));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool(""));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("t"));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("f"));
    try std.testing.expectError(errors.Error.InvalidBoolString, parseBool("1"));
}
