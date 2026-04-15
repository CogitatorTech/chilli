# AI Usage Policy

> [!IMPORTANT]
> Chilli does not accept fully AI-generated pull requests.
> AI tools may be used only for assistance.
> You must understand and take responsibility for every change you submit.
>
> Read and follow [AGENTS.md](./AGENTS.md), [CONTRIBUTING.md](./CONTRIBUTING.md), and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## Our Rule

All contributions must come from humans who understand and can take full responsibility for their code. LLMs make mistakes and cannot be held
accountable.
Chilli is a CLI framework, so its users trust it to parse their arguments correctly, dispatch to the right command, and emit help text that matches
reality. Subtle issues in the parser, command-tree teardown, or help generator silently corrupt every downstream CLI that depends on Chilli, so human
ownership matters.

> [!WARNING]
> Maintainers may close PRs that appear to be fully or largely AI-generated.

## Getting Help

Before asking an AI, please open or comment on an issue on the [Chilli issue tracker](https://github.com/CogitatorTech/chilli/issues). There are
no silly questions, and CLI-parsing topics (POSIX vs GNU flag conventions, grouped short flags, subcommand dispatch, environment-variable fallback,
and allocator and lifetime management across the command tree) are an area where LLMs often give confident but incorrect answers.

If you do use AI tools, use them for assistance (like a reference or tutor), not generatively (to fully write code for you).

## Guidelines for Using AI Tools

1. Complete understanding of every line of code you submit.
2. Local review and testing before submission, including `make test` and `make lint`.
3. Personal responsibility for bugs, regressions, and cross-platform issues in your contribution.
4. Disclosure of which AI tools you used in your PR description.
5. Compliance with all rules in [AGENTS.md](./AGENTS.md) and [CONTRIBUTING.md](./CONTRIBUTING.md).

### Example Disclosure

> I used Claude to help understand a parsing regression in `src/chilli/parser.zig`.
> I reviewed the suggested fix, ran `make test` and `make run` locally against the relevant examples, and verified the `--help` output is unchanged.

## Allowed (Assistive Use)

- Explanations of existing code in `src/lib.zig`, `src/chilli/`, and `examples/`.
- Suggestions for debugging failing inline `test` blocks or help-output mismatches.
- Help understanding Zig compiler errors, allocator lifetimes, or prior-art conventions from other CLI frameworks.
- Review of your own code for correctness, clarity, and style.

## Not Allowed (Generative Use)

- Generation of entire PRs or large code blocks, including new parser branches in `src/chilli/parser.zig`, new flag or argument types in
  `src/chilli/types.zig`, new command-tree logic in `src/chilli/command.zig`, or new example programs under `examples/`.
- Delegation of implementation or API decisions to the tool, especially for the shape of the public API re-exported from `src/lib.zig` or for help
  and error output that users will see.
- Submission of code you do not understand.
- Generation of documentation, README content, or doc comments without your own review.
- Automated or bulk submission of changes produced by agents.

## About AGENTS.md

[AGENTS.md](./AGENTS.md) encodes project rules about architecture, testing, and conventions, and is structured so that LLMs can better comply with
them. Agents may still ignore or be talked out of it; it is a best effort, not a guarantee.
Its presence does not imply endorsement of any specific AI tool or service.

## Licensing Note

Chilli is licensed under the MIT License and has no external Zig or C dependencies, so all source in this repository is expected to be originally
authored by contributors. AI-generated code of unclear provenance would muddy that boundary, which is another reason to keep contributions
human-authored.

## AI Disclosure

This policy was adapted, with the assistance of AI tools, from a similar policy used by other open-source projects, and was reviewed and edited by
human contributors to fit Chilli.
