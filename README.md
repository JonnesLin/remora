# remora

A drop-in **operating protocol** for an LLM-powered super-agent. Like the fish, it attaches to a host runtime — Claude Code, Codex, Cursor, Aider, Continue, OpenHands, Gemini CLI, Windsurf, Cline, Goose, Kilo Code, OpenCode, GitHub Copilot, … — and gives the agent inside a consistent identity model, authorization flow, persistent project memory, and protocol for dispatching subagents and external workers.

The protocol is **markdown-only**. Nothing to install, no service to run. Drop these files into a workspace and any of the supported runtimes picks up its native entry file automatically.

## Why "remora"

Remoras are the small fish that hitchhike on sharks and rays. They go wherever the host goes, eating scraps the host stirred up, but never directing the host's path. This protocol is the same: it sits inside whatever LLM runtime you happen to be using, doesn't fight the host's design, and gives you continuity across sessions and runtime swaps.

## How it works

This repo contains two kinds of files:

1. **The protocol** (runtime-neutral): [`PROTOCOL.md`](./PROTOCOL.md), [`auth-policy.md`](./auth-policy.md), [`skills/`](./skills/), [`LICENSE`](./LICENSE).
2. **Runtime entry shims** (one per supported runtime): each is a 3-line pointer to the protocol. Whatever runtime you use, that runtime's native entry file is already present and pre-wired — Claude Code, Codex, Cursor, etc. all sit on equal footing.

When you open this directory in any supported runtime, it reads its native entry file (the shim), which instructs the agent to load the canonical `PROTOCOL.md` + `auth-policy.md` into context. From there, the protocol takes over.

No privileged runtime. No "bring your own glue." Pure drop-in.

## Find your runtime

Each row links to that runtime's native entry file as it lives in this repo. Click your runtime's row to see the exact 3-line shim it loads on startup.

| Runtime | Native entry file | Notes |
|---|---|---|
| **Claude Code** (Anthropic) | [`CLAUDE.md`](./CLAUDE.md) | |
| **Codex** (OpenAI) | [`AGENTS.md`](./AGENTS.md) | |
| **Cursor** — legacy | [`.cursorrules`](./.cursorrules) | most installs still read this |
| **Cursor** — modern | [`.cursor/rules/remora.mdc`](./.cursor/rules/remora.mdc) | new MDC-format rules system |
| **Windsurf** (Codeium) — legacy | [`.windsurfrules`](./.windsurfrules) | |
| **Windsurf** — modern | [`.windsurf/rules/remora.md`](./.windsurf/rules/remora.md) | |
| **Aider** | [`CONVENTIONS.md`](./CONVENTIONS.md) | load via `aider --read CONVENTIONS.md` or `.aider.conf.yml` |
| **Continue.dev** | [`.continue/rules/remora.md`](./.continue/rules/remora.md) | auto-loaded from this dir |
| **Gemini CLI** (Google) | [`GEMINI.md`](./GEMINI.md) | |
| **OpenHands** | [`.openhands_instructions`](./.openhands_instructions) or [`.openhands/microagents/remora.md`](./.openhands/microagents/remora.md) | both formats supported; microagents is newer |
| **Cline** / **Roo Code** | [`.clinerules`](./.clinerules) | |
| **Goose** (Block) | [`.goosehints`](./.goosehints) | |
| **Kilo Code** / **Factory** / **OpenCode** | [`AGENTS.md`](./AGENTS.md) | natively read the open AGENTS.md standard |
| **GitHub Copilot** | [`.github/copilot-instructions.md`](./.github/copilot-instructions.md) | |

If your runtime isn't listed, drop in a single markdown file at whatever path your runtime expects, with the same content as one of the existing shims (or just symlink one). Then send a PR.

**Backends are orthogonal.** Works with any LLM provider the runtime supports: Anthropic, OpenAI, Google, AWS Bedrock, Azure OpenAI, Vertex AI, OpenRouter, LiteLLM, Together, Fireworks, Groq, … The protocol doesn't care.

## Quick start

```bash
git clone https://github.com/<your-username>/remora.git my-workspace
cd my-workspace
```

1. **Edit [`auth-policy.md`](./auth-policy.md)** — replace `<admin-phone>` and `<admin-email>` with your own verified handles. (These are the only two pieces of identity config; everything else flows from them.)
2. **Open the directory in your runtime.** The runtime picks up its native entry file from the table above and the agent reads `PROTOCOL.md` + `auth-policy.md` on first message.
3. **Send your first message.** The agent will create `~/projects/_admin/`, scan for in-flight authorization requests (none on first run), and wait for inbound work.

## Project layout (after the agent has run)

The agent stores runtime state at `~/projects/`, separate from this protocol repo:

```
~/projects/
├── _admin/                # auth state, audit log, friends list, routing hints
│   ├── pending/           # in-flight 30-min authorization requests
│   ├── log.jsonl          # append-only audit log
│   ├── friends.json       # friends allowlist
│   ├── routing.json       # optional channel→project hints
│   └── away-mode.json     # present when away mode is active
└── <project-name>/        # one directory per tracked project
    ├── PROGRESS.md        # reverse-chronological recent activity
    ├── WORKING_MEMORY.md  # durable, curated lessons
    ├── tasks/<id>/        # per-task scratch (prompt.md, result.md, state.json)
    ├── attachments/       # binary blobs referenced by markdown
    └── logs/, meetings/, experiments/, daily/, goals/, misc/, archive/
```

This separation means the protocol repo stays clean (just markdown), while operator-specific state stays in the operator's home.

## Design highlights

- **Three identity tiers** — admin / friend / stranger. Identity is a character-for-character handle match against verified channels (phone, OAuth-authenticated email, Apple ID-bound iMessage). Never inferred from message content.
- **30-minute authorization flow** for sensitive operations from non-admins. Survives runtime context-clear via on-disk pending records.
- **Markdown-only handoff** to external agents (Codex, Aider, etc.). No screen scraping, no OCR — the protocol relies on the target being agentic enough to read and write files.
- **Persistent project memory** in `PROGRESS.md` (recent activity) and `WORKING_MEMORY.md` (durable lessons), with atomic writes and a verify-before-trust rule.
- **Self-evolution via `distill`** — the agent reviews recent activity and proposes promotions to durable memory or new skills; admin gates application.
- **Hard rules vs LLM judgment** — most decisions are LLM-judged, but a small set (identity match, auth state machine, atomic writes, path validation, audit log immutability) are deterministic. See [`PROTOCOL.md` §10](./PROTOCOL.md).

## What's deliberately *not* here

- **No model.** Bring your own — pick a runtime, point it at the directory.
- **No service.** No daemons, no servers. The runtime is the only process.
- **No vendor SDK.** Markdown only.
- **No language-specific stuff.** This is a protocol, not a coding agent.
- **No privileged runtime.** Every supported runtime sits at the same layer; the canonical doc has a runtime-neutral name (`PROTOCOL.md`) and every entry file is a shim.

## Status

Personal blueprint released as reference. Use it, fork it, ignore the parts that don't fit your workflow. Some calls are deliberately opinionated (single admin, three identity tiers, markdown-only handoff, no preemptive cron) — read [`PROTOCOL.md` §10 ("Hard rules")](./PROTOCOL.md) and [`PROTOCOL.md` §9 ("Don'ts")](./PROTOCOL.md) for the bits that are not up for LLM judgment.

## License

MIT. See [`LICENSE`](./LICENSE).
