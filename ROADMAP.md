## Feature Roadmap

This document includes the roadmap for the Chilli project.
It outlines features to be implemented and their current status.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

-   **Command Structure**
    -   [x] Nested commands and subcommands
    -   [x] Command aliases and single-character shortcuts
    -   [x] Persistent flags (flags on parent commands are available to children)

-   **Argument & Flag Parsing**
    -   [x] Long flags (`--verbose`), short flags (`-v`), and grouped boolean flags (`-vf`)
    -   [x] Positional Arguments (supports required, optional, and variadic)
    -   [x] Type-safe access for flags and arguments (e.g., `ctx.getFlag("count", i64)`)
    -   [x] Reading flag values from environment variables

-   **Help & Usage Output**
    -   [x] Automatic and context-aware `--help` flag
    -   [x] Automatic `--version` flag
    -   [x] Clean, aligned help output for commands, flags, and arguments
    -   [x] Grouping subcommands into custom sections

-   **Developer Experience**
    -   [x] Simple, declarative API for building commands
    -   [x] Named access for all flags and arguments
    -   [x] Shared context data for passing application state
    -   [ ] Deprecation notices for commands or flags
    -   [ ] Built-in TUI components (like spinners and progress bars)
    -   [ ] Automatic command history and completion
