const std = @import("std");
const chilli = @import("chilli");

fn dummyExec(ctx: chilli.CommandContext) !void {
    _ = ctx;
}

pub fn main() anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "help-demo",
        .description = "A demonstration of Chilli's automatic help output.",
        .version = "v1.0.0",
        .exec = dummyExec,
    });
    defer root_cmd.deinit();

    try root_cmd.addFlag(.{
        .name = "verbose",
        .shortcut = 'v',
        .description = "Enable verbose logging",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root_cmd.addFlag(.{
        .name = "output",
        .shortcut = 'o',
        .description = "Specify an output file",
        .type = .String,
        .default_value = .{ .String = "stdout" },
    });

    var sub_cmd = try chilli.Command.init(allocator, .{
        .name = "sub",
        .description = "A subcommand with its own arguments.",
        .exec = dummyExec,
    });
    try root_cmd.addSubcommand(sub_cmd);

    try sub_cmd.addPositional(.{
        .name = "input",
        .description = "The input file to process.",
        .is_required = true,
    });

    std.debug.print("--- Help for root command ('help-demo --help') ---\n", .{});
    try root_cmd.printHelp();

    std.debug.print("\n--- Help for subcommand ('help-demo sub --help') ---\n", .{});
    try sub_cmd.printHelp();
}

// Example Invocation
//
// This example does not parse command-line arguments. Instead, its main function
// programmatically builds the command structure and prints the help messages to
// show what the output looks like.
//
// You can run it directly with:
//    zig build run-e3_help_output
