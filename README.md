<div align="center">
  <picture>
    <img alt="Chilli Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Chilli</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/CogitatorTech/chilli/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/chilli/actions/workflows/tests.yml)
[![CodeFactor](https://img.shields.io/codefactor/grade/github/CogitatorTech/chilli?label=code%20quality&style=flat&labelColor=282c34&logo=codefactor)](https://www.codefactor.io/repository/github/CogitatorTech/chilli)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.1-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://CogitatorTech.github.io/chilli)
[![Examples](https://img.shields.io/badge/examples-view-green?style=flat&labelColor=282c34&logo=zig)](https://github.com/CogitatorTech/chilli/tree/main/examples)
[![Release](https://img.shields.io/github/release/CogitatorTech/chilli.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/CogitatorTech/chilli/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/CogitatorTech/chilli/blob/main/LICENSE)

A microframework for creating command-line applications in Zig

</div>

---

Chilli is a lightweight command-line interface (CLI) framework for the Zig programming language.
Its goal is to make it easy to create structured, maintainable, and user-friendly CLIs with minimal boilerplate,
while being small and fast, and not getting in the way of your application logic.

### Features

- Provides a simple, low-overhead, declarative API for building CLI applications
- Supports nested commands, subcommands, and aliases
- Provides type-safe parsing for flags, positional arguments, and environment variables
- Supports generating automatic `--help` and `--version` output with custom sections
- Uses a shared context to pass application state
- Written in pure Zig with no external dependencies

See the [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> Chilli is in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/CogitatorTech/chilli/issues) to report bugs or request features.

---

### Getting Started

You can add Chilli to your project and start using it by following the steps below.

#### Installation

Run the following command in the root directory of your project to download Chilli:

```sh
zig fetch --save=chilli "https://github.com/CogitatorTech/chilli/archive/<branch_or_tag>.tar.gz"
```

Replace `<branch_or_tag>` with the desired branch or tag, like `main` (for the development version) or `v0.2.2`
(for the specified release version).
This command will download Chilli and add it to Zig's global cache and update your project's `build.zig.zon` file.

#### Adding to Build Script

Next, modify your `build.zig` file to make Chilli available to your build target as a module.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Get the dependency object from the builder
    const chilli_dep = b.dependency("chilli", .{});

    // 2. Create a module for the dependency
    const chilli_module = chilli_dep.module("chilli");

    // 3. Create your executable module and add chilli as import
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("chilli", chilli_module);

    // 4. Create executable with the module
    const exe = b.addExecutable(.{
        .name = "your-cli-app",
        .root_module = exe_module,
    });

    b.installArtifact(exe);
}
```

#### Using Chilli in an Application

Finally, you can `@import("chilli")` and start using it in your Zig application.

```zig
const std = @import("std");
const chilli = @import("chilli");

// A function for our command to execute
fn greet(ctx: chilli.CommandContext) !void {
    const name = try ctx.getFlag("name", []const u8);
    const excitement = try ctx.getFlag("excitement", u32);

    std.print("Hello, {s}", .{name});
    var i: u32 = 0;
    while (i < excitement) : (i += 1) {
        std.print("!", .{});
    }
    std.print("\n", .{});
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the root command for your application
    var root_cmd = try chilli.Command.init(allocator, .{
        .name = "your-cli-app",
        .description = "A new CLI built with Chilli",
        .version = "v0.1.0",
        .exec = greet, // The function to run
    });
    defer root_cmd.deinit();

    // Add flags to the command
    try root_cmd.addFlag(.{
        .name = "name",
        .shortcut = 'n',
        .description = "The name to greet",
        .type = .String,
        .default_value = .{ .String = "World" },
    });
    try root_cmd.addFlag(.{
        .name = "excitement",
        .type = .Int,
        .description = "How excited to be",
        .default_value = .{ .Int = 1 },
    });

    // Hand control over to the framework
    try root_cmd.run(null);
}
```

You can now run your CLI application with the `--help` flag to see the output below:

```bash
$ ./your-cli-app --help
your-cli-app v0.2.2
A new CLI built with Chilli

USAGE:
    your-cli-app [FLAGS]

FLAGS:
    -n, --name <string>      The name to greet [default: World]
        --excitement <int>   How excited to be [default: 1]
    -h, --help               Prints help information
    -V, --version            Prints version information
```

---

### Documentation

You can find the full API documentation for the latest release of Chilli [here](https://CogitatorTech.github.io/chilli).

Alternatively, you can use the `make docs` command to generate the API documentation for the current version of Chilli
from the source code.
This will generate HTML documentation in the `docs/api` directory, which you can serve locally with `make serve-docs`
and view in your web browser at [http://localhost:8000](http://localhost:8000).

### Examples

Check out the [examples](examples) directory for examples of how Chilli can be used to build a variety of CLI
applications.

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

Chilli is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/45673/chili-pepper).
