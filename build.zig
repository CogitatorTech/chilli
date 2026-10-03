const std = @import("std");
const fs = std.fs;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Library Setup ---
    const lib_source = b.path("src/lib.zig");

    const lib_module = b.createModule(.{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "chilli",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Export the module so downstream projects can use it
    _ = b.addModule("chilli", .{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    // --- Docs Setup ---
    const docs_step = b.step("docs", "Generate API documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .custom = "../docs" },
        .install_subdir = "api",
    });
    docs_step.dependOn(&install_docs.step);

    // --- Test Setup ---
    const test_module = b.createModule(.{
        .root_source_file = lib_source,
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // --- Example Setup ---
    const examples_path = "examples";
    const io = b.graph.io;
    examples_blk: {
        // If the examples directory isn't present (common when used as a dependency),
        // skip setting up example artifacts instead of panicking.
        var examples_dir = b.root.openDir(io, examples_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) {
                b.graph.poisonCache();
                break :examples_blk;
            }
            @panic("Can't open 'examples' directory");
        };
        defer examples_dir.close(io);
        b.dependOnDirectoryContents(b.path(examples_path));

        var dir_iter = examples_dir.iterate();
        while (dir_iter.next(io) catch @panic("Failed to iterate examples")) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

            const exe_name = fs.path.stem(entry.name);
            const exe_path = b.fmt("{s}/{s}", .{ examples_path, entry.name });

            const exe_module = b.createModule(.{
                .root_source_file = b.path(exe_path),
                .target = target,
                .optimize = optimize,
            });
            exe_module.addImport("chilli", lib_module);

            const exe = b.addExecutable(.{
                .name = exe_name,
                .root_module = exe_module,
            });
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            const run_step_name = b.fmt("run-{s}", .{exe_name});
            const run_step_desc = b.fmt("Run the {s} example", .{exe_name});
            const run_step = b.step(run_step_name, run_step_desc);
            run_step.dependOn(&run_cmd.step);
        }
    }
}
