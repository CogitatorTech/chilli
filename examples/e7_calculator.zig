const std = @import("std");
const chilli = @import("chilli");
const Command = chilli.Command;
const CommandOptions = chilli.CommandOptions;
const CommandContext = chilli.CommandContext;
const PositionalArg = chilli.PositionalArg;

fn addExec(ctx: CommandContext) !void {
    const a = try ctx.getArg("a", f64);
    const b = try ctx.getArg("b", f64);
    const result = a + b;
    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;
    try stdout.print("{d} + {d} = {d}\n", .{ a, b, result });
}

fn subtractExec(ctx: CommandContext) !void {
    const a = try ctx.getArg("a", f64);
    const b = try ctx.getArg("b", f64);
    const result = a - b;
    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;
    try stdout.print("{d} - {d} = {d}\n", .{ a, b, result });
}

fn multiplyExec(ctx: CommandContext) !void {
    const a = try ctx.getArg("a", f64);
    const b = try ctx.getArg("b", f64);
    const result = a * b;
    const io = std.Options.debug_io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_fw.flush() catch {};
    const stdout = &stdout_fw.interface;
    try stdout.print("{d} * {d} = {d}\n", .{ a, b, result });
}

fn calculatorRootExec(ctx: CommandContext) !void {
    try ctx.command.printHelp();
}

fn makeOperationCmd(
    allocator: std.mem.Allocator,
    options: CommandOptions,
) !*Command {
    var cmd = try Command.init(allocator, options);
    try cmd.addPositional(PositionalArg{ .name = "a", .description = "First number", .is_required = true, .type = .Float });
    try cmd.addPositional(PositionalArg{ .name = "b", .description = "Second number", .is_required = true, .type = .Float });
    return cmd;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root_cmd = try Command.init(allocator, CommandOptions{
        .name = "calculator",
        .description = "A simple CLI calculator.",
        .exec = calculatorRootExec,
    });
    defer root_cmd.deinit();

    const add_cmd = try makeOperationCmd(allocator, .{
        .name = "add",
        .description = "Adds two numbers.",
        .exec = addExec,
    });

    const subtract_cmd = try makeOperationCmd(allocator, .{
        .name = "subtract",
        .description = "Subtracts two numbers.",
        .exec = subtractExec,
    });

    const multiply_cmd = try makeOperationCmd(allocator, .{
        .name = "multiply",
        .description = "Multiplies two numbers.",
        .exec = multiplyExec,
    });

    try root_cmd.addSubcommand(add_cmd);
    try root_cmd.addSubcommand(subtract_cmd);
    try root_cmd.addSubcommand(multiply_cmd);

    try root_cmd.run(init.args, null);
}

// Example Invocations
//
// 1. Build the example executable:
//    zig build e7_calculator
//
// 2. Run with different arguments:
//
//    // Add two numbers
//    ./zig-out/bin/e7_calculator add 10.5 22
//
//    // Subtract two numbers
//    ./zig-out/bin/e7_calculator subtract 100 42.5
//
//    // Multiply two numbers
//    ./zig-out/bin/e7_calculator multiply -5.5 10
