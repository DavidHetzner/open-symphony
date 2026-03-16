# Open-Symphony

Open-Symphony is a fork of [OpenAI's Symphony](https://github.com/openai/symphony), extended to support multiple AI coding agents. Where the original Symphony only works with OpenAI Codex, Open-Symphony lets you choose your provider -- including Claude Code by Anthropic -- with a single config change.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers manage work at a higher level instead of supervising coding agents directly._

> [!WARNING]
> Open-Symphony is a low-key engineering preview for testing in trusted environments.

## What's different from upstream Symphony?

- **Multi-provider support**: Switch between Codex and Claude Code via `codex.provider` in your `WORKFLOW.md`
- **Claude Code integration**: Full support for Claude Code CLI as an agent backend, using per-turn subprocesses with `--resume` for session continuity
- **Provider-agnostic orchestration**: The orchestrator, dashboard, and token accounting work identically regardless of which provider is active

## Supported Providers

| Provider | Config value | Backend |
|---|---|---|
| OpenAI Codex | `codex` (default) | Long-lived JSON-RPC app-server subprocess |
| Claude Code | `claude` | Per-turn CLI subprocess with `--resume` for session continuity |

### Quick switch

```yaml
# WORKFLOW.md
codex:
  provider: claude          # "codex" (default) or "claude"
  claude_command: claude     # path to claude CLI (default: "claude")
  command: codex app-server  # still used when provider is "codex"
```

## Running Open-Symphony

### Requirements

Open-Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Open-Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

For the Claude provider, you need the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use the Elixir reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Open-Symphony for my repository based on
> elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
