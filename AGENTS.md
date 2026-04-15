# AGENTS.md

This file provides guidance to coding agents collaborating on this repository.

## Mission

Chilli is a command-line interface (CLI) microframework for Zig.
It turns a declarative description of commands, flags, and positional arguments into a parser, help generator, and dispatcher, with zero external
dependencies.
Priorities, in order:

1. Correctness of argument parsing, flag resolution, and help output.
2. Minimal public API for defining and running command trees from other Zig projects.
3. Zero non-Zig dependencies, maintainable, and well-tested code.
4. Cross-platform support (Linux, macOS, and Windows).

## Core Rules

- Use English for code, comments, docs, and tests.
- Prefer small, focused changes over large refactoring.
- Add comments only when they clarify non-obvious behavior.
- Do not add features, error handling, or abstractions beyond what is needed for the current task.
- Keep the project dependency-free: no external Zig packages or C libraries unless explicitly agreed.

## Writing Style

- Use Oxford commas in inline lists: "a, b, and c" not "a, b, c".
- Do not use em dashes. Restructure the sentence, or use a colon or semicolon instead.
- Avoid colorful adjectives and adverbs. Write "TCP proxy" not "lightweight TCP proxy", "scoring components" not "transparent scoring components".
- Use noun phrases for checklist items, not imperative verbs. Write "redundant index detection" not "detect redundant indexes".
- Headings in Markdown files must be in the title case: "Build from Source" not "Build from source". Minor words (a, an, the, and, but, or, for, in,
  on, at, to, by, of, is, are, was, were, be) stay lowercase unless they are the first word.

## Repository Layout

- `src/lib.zig`: Public API entry point. Re-exports `Command`, `CommandOptions`, `Flag`, `FlagType`, `FlagValue`, `PositionalArg`, `CommandContext`,
  `styles`, and `Error`.
- `src/chilli/command.zig`: The `Command` struct, `CommandOptions`, init/deinit, `run`, subcommand and flag registration, and the private help-output printers.
- `src/chilli/types.zig`: Core types (`Flag`, `FlagType`, `FlagValue`, `PositionalArg`) and the `parseBool` / `parseValue` helpers.
- `src/chilli/parser.zig`: Argument-string parser (`ArgIterator`, `ParsedFlag`, long/short/grouped flag handling, positional handling).
- `src/chilli/context.zig`: The `CommandContext` passed to each command's `exec` function for typed flag and argument access.
- `src/chilli/errors.zig`: Error types produced by parsing and type coercion.
- `src/chilli/styles.zig`: ANSI escape-code constants plus a TTY-gated `s()` wrapper used by the help and error output.
- `src/chilli/deprecation.zig`: Warning formatter and stderr emitter for deprecated commands, flags, and positional arguments, with `CHILLI_NO_DEPRECATION_WARNINGS` suppression.
- `examples/`: Self-contained example programs (`e1_simple_cli.zig` through `e8_flags_and_args.zig`) built as executables via `build.zig`.
- `.github/workflows/`: CI workflows (`tests.yml` for unit tests on Linux, macOS, and Windows, `docs.yml` for API doc deployment).
- `build.zig` / `build.zig.zon`: Zig build configuration and package metadata.
- `Makefile`: GNU Make wrapper around `zig build` targets.
- `docs/`: Generated API docs land in `docs/api/` (produced by `make docs`).

## Architecture

### Command Tree

A Chilli application is a tree of `Command` nodes. Each node owns its `flags`, `positional_args`, optional `exec`
function, and a list of subcommands. `Command.init` allocates a node; `Command.deinit` recursively frees the subtree, so
downstream users call `deinit` only on the root.

### Parsing Pipeline

Arguments flow through: `ArgIterator` over `[][]const u8` (`parser.zig`) -> per-node flag and positional resolution
(`parser.zig` + `command.zig`) -> `CommandContext` population (`context.zig`) -> `exec` dispatch on the resolved leaf
command.

### Flag and Positional Types

`FlagType` (`types.zig`) enumerates the supported value kinds (`Bool`, `Int`, `Float`, `String`). `FlagValue` is the matching-tagged union.
`types.parseValue` is the single conversion point from raw strings into a `FlagValue`; every new type or coercion belongs here.

### Help and Version Output

Help and version text are generated automatically from the command tree at runtime by `command.zig`, using the metadata in `CommandOptions` (name,
description, version, sections) and the registered flags and positional args. Grouping into
named sections is supported; custom help formatting beyond that should be added sparingly.

### Public API Surface

Everything re-exported from `src/lib.zig` is part of the public API. Changes to names or signatures there are breaking.
The rest of `src/chilli/` is internal and may be refactored freely as long as the public surface and its behavior are
preserved.

### Dependencies

Chilli has **no external Zig or C dependencies**.
The only `build.zig.zon` entries should be Chilli itself.
Please do not add dependencies without prior discussion.

## Zig Conventions

- Zig version: 0.16.0 (as declared in `build.zig.zon` and the Makefile's `ZIG_LOCAL` path).
- Formatting is enforced by `zig fmt`. Run `make format` before committing.
- Naming follows Zig standard-library conventions: `camelCase` for functions (e.g. `addFlag`, `getFlag`, `parseBool`), `snake_case` for local
  variables and struct fields, `PascalCase` for types and structs, and `SCREAMING_SNAKE_CASE` for top-level compile-time constants.

## Required Validation

Run the relevant targets for any change:

| Target         | Command                          | What It Runs                                                     |
|----------------|----------------------------------|------------------------------------------------------------------|
| Unit tests     | `make test`                      | Inline `test` blocks across `src/lib.zig` and `src/chilli/*.zig` |
| Lint           | `make lint`                      | Checks Zig formatting with `zig fmt --check src examples`        |
| Single example | `make run EXAMPLE=e1_simple_cli` | Builds and runs one example program                              |
| All examples   | `make run`                       | Builds and runs every example under `examples/`                  |
| Docs           | `make docs`                      | Generates API docs into `docs/api`                               |
| Everything     | `make all`                       | Runs `build`, `test`, `lint`, and `docs`                         |

## First Contribution Flow

1. Read the relevant module under `src/chilli/` (often `command.zig`, `parser.zig`, or `types.zig`).
2. Implement the smallest change that covers the requirement.
3. Add or update inline `test` blocks in the changed Zig module to cover the new behavior.
4. Run `make test` and `make lint`.
5. If parser or help-output behavior changed, also exercise the examples with `make run` and confirm the `--help` output is still correct.

Good first tasks:

- New example under `examples/` that demonstrates an API pattern, listed in `examples/README.md`.
- New flag-coercion case in `src/chilli/types.zig` `parseValue` (with an inline `test` block).
- Error message refinement in `src/chilli/errors.zig`, paired with a test that asserts the exact message.
- Help-formatting refinement in `src/chilli/command.zig`.

## Testing Expectations

- Unit and regression tests live as inline `test` blocks in the module they cover (`src/lib.zig` and `src/chilli/*.zig`). There is no separate
  `tests/` directory.
- Tests are discovered automatically via `std.testing.refAllDecls(@This())` in `src/lib.zig`, so new `test` blocks only need to live in a module that
  is reachable from `lib.zig`.
- Every new public function, flag type, or parser branch must ship with at least one `test` block that exercises it, including the error paths where
  applicable.
- Tests that touch argument parsing should build their input as `[][]const u8` explicitly, not read from `std.process.args()`, so they work under
  `zig test` without a real process-args environment.
- No public API change is complete without a test covering the new or changed behavior.

## Change Design Checklist

Before coding:

1. Modules affected by the change (`command`, `parser`, `types`, `context`, `errors`, `styles`, or `deprecation`).
2. Whether the change is user-visible in `--help` output, and if so, which examples will surface it.
3. Public API impact, i.e. whether the change adds to or alters anything re-exported from `src/lib.zig`, and is therefore additive or breaking.
4. Cross-platform implications, especially for anything that touches environment variables, the filesystem, or process-args encoding.

Before submitting:

1. `make test` passes.
2. `make lint` passes.
3. `make run` succeeds for all examples when touching the parser, command dispatch, or help-output code.
4. Docs updated (`make docs`) if the public API surface changed, and `ROADMAP.md` ticked or updated if a listed item was implemented.

## Commit and PR Hygiene

- Keep commits scoped to one logical change.
- PR descriptions should include:
    1. Behavioral change summary.
    2. Tests added or updated.
    3. Whether examples were run locally (yes/no), and on which OS.
