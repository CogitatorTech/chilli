const std = @import("std");
const chilli = @import("chilli");

fn dummyExec(ctx: chilli.CommandContext) !void {
    try ctx.command.printHelp();
}

pub fn main(init: std.process.Init.Minimal) anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "section-demo",
        .description = "Demonstrates custom subcommand sections.",
        .exec = dummyExec,
    });
    defer root_cmd.deinit();

    const cmd_get = try chilli.Command.init(allocator, .{
        .name = "get",
        .description = "Get a resource.",
        .exec = dummyExec,
        .section = "Core Commands",
    });
    try root_cmd.addSubcommand(cmd_get);

    const cmd_set = try chilli.Command.init(allocator, .{
        .name = "set",
        .description = "Set a resource.",
        .exec = dummyExec,
        .section = "Core Commands",
    });
    try root_cmd.addSubcommand(cmd_set);

    const cmd_config = try chilli.Command.init(allocator, .{
        .name = "config",
        .description = "Configure the application.",
        .exec = dummyExec,
        .section = "Management Commands",
    });
    try root_cmd.addSubcommand(cmd_config);

    const cmd_auth = try chilli.Command.init(allocator, .{
        .name = "auth",
        .description = "Authenticate with the service.",
        .exec = dummyExec,
        .section = "Management Commands",
    });
    try root_cmd.addSubcommand(cmd_auth);

    const cmd_other = try chilli.Command.init(allocator, .{
        .name = "other",
        .description = "Another command.",
        .exec = dummyExec,
    });
    try root_cmd.addSubcommand(cmd_other);

    try root_cmd.run(init.args, null);
}

// Example Invocation
//
// This example's main purpose is to demonstrate the custom section titles in the
// help output. The root command is configured to print its help message by default.
//
// You can see the formatted output by running:
//    zig build run-e4_custom_sections
//
// Or, to invoke help explicitly:
//    ./zig-out/bin/e4_custom_sections --help
