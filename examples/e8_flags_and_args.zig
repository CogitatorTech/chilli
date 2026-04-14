const std = @import("std");
const chilli = @import("chilli");

fn exec(ctx: chilli.CommandContext) !void {
    const count = try ctx.getFlag("count", i32);
    const message = try ctx.getFlag("message", []const u8);
    const force = try ctx.getFlag("force", bool);

    const required_arg = try ctx.getArg("required-arg", []const u8);
    const optional_arg = try ctx.getArg("optional-arg", []const u8);
    const variadic_args = ctx.getArgs("variadic-args");

    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;

    try stdout.print("Flags:\n", .{});
    try stdout.print("  --count: {d}\n", .{count});
    try stdout.print("  --message: {s}\n", .{message});
    try stdout.print("  --force: {}\n", .{force});

    try stdout.print("\nArguments:\n", .{});
    try stdout.print("  required-arg: {s}\n", .{required_arg});
    try stdout.print("  optional-arg: {s}\n", .{optional_arg});
    try stdout.print("  variadic-args: {any}\n", .{variadic_args});
}

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "flags-args-demo",
        .description = "Demonstrates various flags and arguments.",
        .exec = exec,
    });
    defer root_cmd.deinit();

    try root_cmd.addFlag(.{
        .name = "count",
        .shortcut = 'c',
        .description = "A number of times to do something.",
        .type = .Int,
        .default_value = .{ .Int = 1 },
    });

    try root_cmd.addFlag(.{
        .name = "message",
        .description = "A message to print.",
        .type = .String,
        .default_value = .{ .String = "default message" },
    });

    try root_cmd.addFlag(.{
        .name = "force",
        .shortcut = 'f',
        .description = "Force an operation.",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root_cmd.addPositional(.{
        .name = "required-arg",
        .description = "A truly required argument.",
        .is_required = true,
    });

    try root_cmd.addPositional(.{
        .name = "optional-arg",
        .description = "An optional argument.",
        .is_required = false,
        .default_value = .{ .String = "default value" },
    });

    try root_cmd.addPositional(.{
        .name = "variadic-args",
        .description = "Any number of additional arguments.",
        .variadic = true,
    });

    try root_cmd.run(init.args, null);
}

// Example Invocations
//
// 1. Build the example executable:
//    zig build e8_flags_and_args
//
// 2. Run with different arguments:
//
//    // Show the help output
//    ./zig-out/bin/e8_flags_and_args --help
//
//    // Run with only the required argument
//    ./zig-out/bin/e8_flags_and_args required_value
//
//    // Run with all arguments and a mix of long and short flags
//    ./zig-out/bin/e8_flags_and_args req_val opt_val --count 10 -f
//
//    // Run with variadic arguments and grouped boolean flags
//    ./zig-out/bin/e8_flags_and_args req_val opt_val extra1 extra2 extra3 -cf
