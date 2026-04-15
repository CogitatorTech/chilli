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
    const doc_install_path = "docs/api";

    // Zig's `-femit-docs=<path>` writes the leaf dir but does not create
    // intermediate parents, and git does not track empty directories, so a
    // fresh checkout may have no `docs/` at all. Create it portably here
    // (idempotent: createDirPath is a no-op when the directory already exists).
    const ensure_docs_dir = EnsureDirStep.create(b, "docs");
    const gen_docs_cmd = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe, // Use the same zig that is running the build
        "build-lib",
        "src/lib.zig",
        "-femit-docs=" ++ doc_install_path,
    });
    gen_docs_cmd.step.dependOn(&ensure_docs_dir.step);

    docs_step.dependOn(&gen_docs_cmd.step);

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
        var examples_dir = b.build_root.handle.openDir(io, examples_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) break :examples_blk;
            @panic("Can't open 'examples' directory");
        };
        defer examples_dir.close(io);

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

/// Build step that ensures a directory (relative to the build root) exists.
/// Runs `std.fs.Dir.createDirPath` at make-time, so it only fires when a
/// step that depends on it is actually being built. Portable across Linux,
/// macOS, and Windows.
const EnsureDirStep = struct {
    step: std.Build.Step,
    sub_path: []const u8,

    fn create(b: *std.Build, sub_path: []const u8) *EnsureDirStep {
        const self = b.allocator.create(EnsureDirStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("ensure {s}/", .{sub_path}),
                .owner = b,
                .makeFn = make,
            }),
            .sub_path = sub_path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *EnsureDirStep = @fieldParentPtr("step", step);
        try step.owner.build_root.handle.createDirPath(step.owner.graph.io, self.sub_path);
    }
};
