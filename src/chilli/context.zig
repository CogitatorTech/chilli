//! Provides the execution context for a command, giving access to parsed arguments and flags.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const command = @import("command.zig");
const errors = @import("errors.zig");

/// Returns true on targets where POSIX environment variable lookup is available.
fn canLookupEnv() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding, .other => false,
        else => true,
    };
}

/// (Private) Describes the source of a value for error reporting.
const ValueSource = enum {
    parsed,
    environment,
    default,
};

/// (Private) Casts a FlagValue to a specific type T at compile time.
/// Panics on type mismatch, which indicates a developer error.
fn castFlagValueTo(
    value: types.FlagValue,
    comptime T: type,
    comptime entity_kind: []const u8,
    entity_name: []const u8,
    source: ValueSource,
) errors.Error!T {
    const panic_msg = "Type mismatch for {s} ''{s}'' from {s} value: expected " ++ @typeName(T) ++ ", got {s}";
    const source_str = @tagName(source);

    return switch (T) {
        bool => if (value == .Bool) value.Bool else std.debug.panic(panic_msg, .{ entity_kind, entity_name, source_str, @tagName(value) }),
        []const u8 => if (value == .String) value.String else std.debug.panic(panic_msg, .{ entity_kind, entity_name, source_str, @tagName(value) }),
        else => switch (@typeInfo(T)) {
            .int => {
                if (value == .Int) {
                    if (std.math.cast(T, value.Int)) |casted_value| {
                        return casted_value;
                    } else {
                        return errors.Error.IntegerValueOutOfRange;
                    }
                }
                std.debug.panic(panic_msg, .{ entity_kind, entity_name, source_str, @tagName(value) });
            },
            .float => {
                if (value == .Float) {
                    const float_val = value.Float;
                    if (@abs(float_val) > std.math.floatMax(T)) {
                        return errors.Error.FloatValueOutOfRange;
                    }
                    return @as(T, @floatCast(float_val));
                }
                std.debug.panic(panic_msg, .{ entity_kind, entity_name, source_str, @tagName(value) });
            },
            else => @compileError("Unsupported type for getFlag/getArg: " ++ @typeName(T)),
        },
    };
}

/// Provides access to command-line data within a command's execution function (`exec`).
pub const CommandContext = struct {
    /// A persistent allocator, typically from the root command, for allocations
    /// that must outlive the command's execution function.
    app_allocator: std.mem.Allocator,
    /// A temporary allocator (typically an ArenaAllocator) for short-lived allocations
    /// during command execution. Memory from this allocator is freed after the exec function returns.
    tmp_allocator: std.mem.Allocator,

    command: *command.Command,
    data: ?*anyopaque,

    /// Retrieves the value for a flag, searching parsed values, then environment
    /// variables, and finally falling back to the default value.
    ///
    /// NOTE: If the value comes from an environment variable, the returned slice
    /// borrows directly from the process environment block (valid for the
    /// lifetime of the process). If you need to hold it past an environment
    /// change, copy it using `app_allocator`.
    pub fn getFlag(self: *const CommandContext, name: []const u8, comptime T: type) errors.Error!T {
        // 1. Check for a parsed value from the command line.
        if (self.command.getFlagValue(name)) |parsed_value| {
            return castFlagValueTo(parsed_value, T, "flag", name, .parsed);
        }

        // 2. Find the flag definition.
        const flag_def = self.command.findFlag(name) orelse
            std.debug.panic("Attempted to access an undefined flag: '{s}'", .{name});

        // 3. Check for a value from an environment variable.
        // getPosix is only available on POSIX targets (not Windows/WASI/freestanding).
        if (comptime canLookupEnv()) {
            if (flag_def.env_var) |env_name| {
                const environ = std.Options.debug_threaded_io.?.environ.process_environ;
                if (std.process.Environ.getPosix(environ, env_name)) |env_val_str| {
                    const env_value = try types.parseValue(flag_def.type, env_val_str);
                    return castFlagValueTo(env_value, T, "flag", name, .environment);
                }
            }
        }

        // 4. Fall back to the default value.
        return castFlagValueTo(flag_def.default_value, T, "flag", name, .default);
    }

    /// Retrieves the value for a positional argument, searching parsed values
    /// and then falling back to the default value if available.
    pub fn getArg(self: *const CommandContext, name: []const u8, comptime T: type) errors.Error!T {
        var arg_def: ?*const types.PositionalArg = null;
        var arg_idx: ?usize = null;

        for (self.command.positional_args.items, 0..) |*item, i| {
            if (std.mem.eql(u8, item.name, name)) {
                arg_def = item;
                arg_idx = i;
                break;
            }
        }

        const found_arg = arg_def orelse
            std.debug.panic("Attempted to access an undefined positional argument: '{s}'", .{name});

        if (found_arg.variadic) {
            std.debug.panic("Positional argument '{s}' is variadic. Use getArgs() or getArgsAs() instead.", .{name});
        }

        // 1. Check for a parsed value from the command line.
        if (arg_idx.? < self.command.parsed_positionals.items.len) {
            const raw_value = self.command.parsed_positionals.items[arg_idx.?];
            const parsed_value = try types.parseValue(found_arg.type, raw_value);
            return castFlagValueTo(parsed_value, T, "argument", name, .parsed);
        }

        // 2. Fall back to the default value.
        if (found_arg.default_value) |default_val| {
            return castFlagValueTo(default_val, T, "argument", name, .default);
        }

        // This path should ideally not be reached if validation is correct.
        // A required argument without a parsed value would fail validation earlier.
        // An optional argument must have a default value (enforced in `addPositional`).
        std.debug.panic("No value or default value found for argument '{s}'", .{name});
    }

    /// Retrieves all raw string values for a variadic positional argument.
    pub fn getArgs(self: *const CommandContext, name: []const u8) []const []const u8 {
        for (self.command.positional_args.items, 0..) |arg_def, i| {
            if (std.mem.eql(u8, arg_def.name, name)) {
                if (!arg_def.variadic) {
                    std.debug.panic("Positional argument '{s}' is not variadic. Use getArg() instead.", .{name});
                }
                const num_parsed = self.command.parsed_positionals.items.len;
                if (num_parsed <= i) {
                    return &.{};
                }
                return self.command.parsed_positionals.items[i..];
            }
        }
        std.debug.panic("Attempted to access an undefined positional argument: '{s}'", .{name});
    }

    /// Retrieves all values for a variadic positional argument, parsed into the specified type `T`.
    /// The returned slice is allocated using the provided `allocator` and must be freed by the caller.
    pub fn getArgsAs(
        self: *const CommandContext,
        comptime T: type,
        name: []const u8,
        allocator: std.mem.Allocator,
    ) errors.Error![]T {
        var arg_def: ?*const types.PositionalArg = null;
        var arg_idx: ?usize = null;

        for (self.command.positional_args.items, 0..) |*item, i| {
            if (std.mem.eql(u8, item.name, name)) {
                arg_def = item;
                arg_idx = i;
                break;
            }
        }

        const found_arg = arg_def orelse
            std.debug.panic("Attempted to access an undefined positional argument: '{s}'", .{name});

        if (!found_arg.variadic) {
            std.debug.panic("Positional argument '{s}' is not variadic. Use getArgsAs() only for variadic arguments.", .{name});
        }

        const num_parsed = self.command.parsed_positionals.items.len;
        const string_args = if (num_parsed > arg_idx.?) self.command.parsed_positionals.items[arg_idx.?..] else &.{};

        if (string_args.len == 0) {
            return allocator.alloc(T, 0);
        }

        var results: std.ArrayList(T) = .empty;
        errdefer results.deinit(allocator);

        for (string_args) |raw_value| {
            const parsed_value = try types.parseValue(found_arg.type, raw_value);
            const casted_value = try castFlagValueTo(parsed_value, T, "variadic argument", name, .parsed);
            try results.append(allocator, casted_value);
        }

        return results.toOwnedSlice(allocator);
    }

    /// Retrieves a pointer to the shared application context data.
    pub fn getContextData(self: *const CommandContext, comptime T: type) ?*T {
        if (self.data) |d| {
            return @ptrCast(@alignCast(d));
        }
        return null;
    }
};

// Tests for the `context` module

const testing = std.testing;
const process = std.process;

fn dummyExec(_: CommandContext) !void {}

test "context: getFlag falls back to default when no env var set" {
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "config",
        .type = .String,
        .default_value = .{ .String = "default.conf" },
        .env_var = "CHILLI_TEST_UNSET_VAR_12345",
        .description = "",
    });

    const ctx = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd, .data = null };

    // With no env var set and no parsed flag, should return the default
    const config_path = try ctx.getFlag("config", []const u8);
    try testing.expectEqualStrings("default.conf", config_path);
}

test "context: getFlag integer range error" {
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();
    try cmd.addFlag(.{ .name = "count", .type = .Int, .default_value = .{ .Int = 0 }, .description = "" });

    // Parsed value is 70000, which does not fit in i16
    try cmd.parsed_flags.append(allocator, .{ .name = "count", .value = .{ .Int = 70000 } });

    const ctx = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd, .data = null };
    try testing.expectError(errors.Error.IntegerValueOutOfRange, ctx.getFlag("count", i16));
}

test "context: getArgs for variadic" {
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();
    try cmd.addPositional(.{ .name = "command", .is_required = true, .description = "" });
    try cmd.addPositional(.{ .name = "files", .variadic = true, .description = "" });

    try cmd.parsed_positionals.appendSlice(allocator, &[_][]const u8{ "run", "file1.zig", "file2.zig" });

    const ctx = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd, .data = null };
    const files = ctx.getArgs("files");

    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("file1.zig", files[0]);
    try testing.expectEqualStrings("file2.zig", files[1]);
}

test "context: typed getArg" {
    const allocator = std.testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();
    try cmd.addPositional(.{ .name = "req_str", .is_required = true, .description = "" });
    try cmd.addPositional(.{ .name = "opt_int", .description = "", .type = .Int, .default_value = .{ .Int = 123 } });
    try cmd.parsed_positionals.append(allocator, "hello");
    const ctx = CommandContext{
        .app_allocator = allocator,
        .tmp_allocator = allocator,
        .command = cmd,
        .data = null,
    };
    try std.testing.expectEqualStrings("hello", try ctx.getArg("req_str", []const u8));
    try std.testing.expectEqual(@as(i64, 123), try ctx.getArg("opt_int", i64));
}

test "context: getFlag" {
    const allocator = std.testing.allocator;
    var cmd = try command.Command.init(allocator, .{
        .name = "test",
        .description = "",
        .exec = dummyExec,
    });
    defer cmd.deinit();
    try cmd.addFlag(.{ .name = "verbose", .type = .Bool, .default_value = .{ .Bool = false }, .description = "" });
    try cmd.addFlag(.{ .name = "count", .type = .Int, .default_value = .{ .Int = 42 }, .description = "" });
    try cmd.addFlag(.{ .name = "pi", .type = .Float, .default_value = .{ .Float = 3.14 }, .description = "" });
    try cmd.parsed_flags.append(allocator, .{ .name = "verbose", .value = .{ .Bool = true } });
    const ctx = CommandContext{
        .app_allocator = allocator,
        .tmp_allocator = allocator,
        .command = cmd,
        .data = null,
    };
    try std.testing.expect(try ctx.getFlag("verbose", bool));
    try std.testing.expectEqual(@as(i32, 42), try ctx.getFlag("count", i32));
    try std.testing.expectEqual(@as(f64, 3.14), try ctx.getFlag("pi", f64));
}

test "context: getArgsAs for typed variadic" {
    const allocator = std.testing.allocator;

    // Test case 1: Integers
    var cmd_int = try command.Command.init(allocator, .{ .name = "test-int", .description = "", .exec = dummyExec });
    defer cmd_int.deinit();
    try cmd_int.addPositional(.{ .name = "numbers", .type = .Int, .variadic = true, .description = "" });
    try cmd_int.parsed_positionals.appendSlice(allocator, &[_][]const u8{ "10", "-20", "300" });

    var ctx_int = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd_int, .data = null };
    const numbers = try ctx_int.getArgsAs(i64, "numbers", allocator);
    defer allocator.free(numbers);

    try testing.expectEqualSlices(i64, &.{ 10, -20, 300 }, numbers);

    // Test case 2: Empty args
    cmd_int.parsed_positionals.clearRetainingCapacity();
    const no_numbers = try ctx_int.getArgsAs(i64, "numbers", allocator);
    defer allocator.free(no_numbers);
    try testing.expectEqual(@as(usize, 0), no_numbers.len);

    // Test case 3: Parse error
    cmd_int.parsed_positionals.clearRetainingCapacity();
    try cmd_int.parsed_positionals.append(allocator, "not-a-number");
    try testing.expectError(error.InvalidCharacter, ctx_int.getArgsAs(i64, "numbers", allocator));
}

test "context: getFlag reads env var via debug_threaded_io environ" {
    // Verify that the Environ.getPosix lookup through debug_threaded_io
    // can find a real environment variable (PATH is always set on POSIX).
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "search-path",
        .type = .String,
        .default_value = .{ .String = "fallback" },
        .env_var = "PATH",
        .description = "",
    });

    const ctx = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd, .data = null };

    // PATH is always set; getFlag should return its value, not the default
    const path_value = try ctx.getFlag("search-path", []const u8);
    try testing.expect(path_value.len > 0);
    try testing.expect(!std.mem.eql(u8, path_value, "fallback"));
}

test "context: getFlag env var lookup returns default for unset var" {
    const allocator = testing.allocator;
    var cmd = try command.Command.init(allocator, .{ .name = "test", .description = "", .exec = dummyExec });
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "config",
        .type = .String,
        .default_value = .{ .String = "default.conf" },
        .env_var = "CHILLI_TEST_UNSET_VAR_XXXXXXX",
        .description = "",
    });

    const ctx = CommandContext{ .app_allocator = allocator, .tmp_allocator = allocator, .command = cmd, .data = null };

    // Unset var should fall back to default
    const config_path = try ctx.getFlag("config", []const u8);
    try testing.expectEqualStrings("default.conf", config_path);
}
