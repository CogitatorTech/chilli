const std = @import("std");
const chilli = @import("chilli");

const AppContext = struct {
    log_level: u8,
    start_time: i64,
};

fn rootExec(ctx: chilli.CommandContext) !void {
    const is_verbose = try ctx.getFlag("verbose", bool);
    std.debug.print("Advanced CLI Example\n", .{});
    std.debug.print("  - Verbose mode: {}\n", .{is_verbose});

    if (ctx.getContextData(AppContext)) |app_ctx| {
        app_ctx.log_level = if (is_verbose) 1 else 0;
    }

    try ctx.command.printHelp();
}

fn addExec(ctx: chilli.CommandContext) !void {
    if (try ctx.getFlag("verbose", bool)) {
        const app_ctx = ctx.getContextData(AppContext).?;
        std.debug.print("Running 'add' command... Log Level: {d}\n", .{app_ctx.log_level});
    }

    const a = try ctx.getArg("a", i64);
    const b = try ctx.getArg("b", i64);
    const precision = try ctx.getFlag("precision", f64);
    const result = @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b));

    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;
    const precision_int: u32 = @intFromFloat(@max(0.0, @min(precision, 20.0)));

    var buf: [64]u8 = undefined;
    const formatted_result = try std.fmt.bufPrint(&buf, "{d:.[prec]}", .{
        .num = result,
        .prec = precision_int,
    });

    try stdout.print("Result: {s}\n", .{formatted_result});
}

fn greetExec(ctx: chilli.CommandContext) !void {
    const name = try ctx.getArg("name", []const u8);
    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;
    try stdout.print("Hello, {s}!\n", .{name});
}

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_context = AppContext{
        .log_level = 0,
        .start_time = 0,
    };

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "comp-cli",
        .description = "A comprehensive example of the Chilli framework.",
        .version = "v1.2.3",
        .exec = rootExec,
    });
    defer root_cmd.deinit();

    try root_cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .description = "Enable verbose output",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    var add_cmd = try chilli.Command.init(allocator, .{
        .name = "add",
        .description = "Adds two integers",
        .aliases = &[_][]const u8{"sum"},
        .shortcut = 'a',
        .exec = addExec,
    });
    try root_cmd.addSubcommand(add_cmd);

    try add_cmd.addFlag(.{
        .name = "precision",
        .type = .Float,
        .description = "Number of decimal places for the output",
        .default_value = .{ .Float = 2.0 },
    });

    try add_cmd.addPositional(.{ .name = "a", .description = "First number", .is_required = true, .type = .Int });
    try add_cmd.addPositional(.{ .name = "b", .description = "Second number", .is_required = true, .type = .Int });

    var greet_cmd = try chilli.Command.init(allocator, .{
        .name = "greet",
        .description = "Prints a greeting",
        .exec = greetExec,
        .section = "Extra Commands",
    });
    try root_cmd.addSubcommand(greet_cmd);

    try greet_cmd.addPositional(.{
        .name = "name",
        .description = "The name to greet",
        .is_required = false,
        .default_value = .{ .String = "World" },
    });

    try root_cmd.run(init.args, &app_context);
}

// Example Invocations
//
// 1. Build the example executable:
//    zig build e5_advanced_cli
//
// 2. Run with different arguments:
//
//    // Add two numbers
//    ./zig-out/bin/e5_advanced_cli add 15 27
//
//    // Use the 'sum' alias, the persistent '--verbose' flag, and the local '--precision' flag
//    ./zig-out/bin/e5_advanced_cli --verbose sum 10 5.5 --precision=4
//
//    // Greet the default 'World'
//    ./zig-out/bin/e5_advanced_cli greet
//
//    // Greet a specific person
//    ./zig-out/bin/e5_advanced_cli greet Ziggy
