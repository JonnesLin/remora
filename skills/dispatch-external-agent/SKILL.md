---
name: dispatch-external-agent
description: Hand off a task to a non-Claude-Code AI agent (Codex, DeepSeek, Cursor agent, another Claude Code session, etc.) using a markdown-only handoff protocol — orchestrator writes prompt.md, screen-control spawns the target and points it at the file, target writes result.md, a cron-driven poller (not the orchestrator's session) detects completion, orchestrator reads it back. Use when work is better done by another model (different specialty, different cost profile, different tools), needs to outlive the orchestrator's session, or wants to spend a different vendor's budget.
---

# dispatch-external-agent

The orchestrator dispatches a task to an external agentic AI by exchanging markdown files in a shared task directory. No screen scraping, no OCR — the protocol relies on the target being agentic enough to read and write files. (Codex, Cursor, Claude Code, Aider, Continue, etc. all qualify.)

## When to use vs Agent tool — worked examples

Default to the Agent tool. Reach for `dispatch-external-agent` only when one of the following clearly applies:

| Situation | Choose | Why |
|---|---|---|
| Classify a 3-line message into a project bucket | **Agent tool** | Sub-second work, no benefit from spawning a separate process |
| Summarize a 30-min meeting transcript | **Agent tool** | Single round trip, returns one summary, no need for outliving the session |
| 4-hour codegen task: implement a feature across many files in another repo | **dispatch (Codex)** | Codex's tool-use loop is better-suited; will exceed the orchestrator's likely session lifetime |
| Run a long-form research investigation, return a report tomorrow | **dispatch (any agentic target)** | Outlives the orchestrator session; admin can `/clear` and the target keeps going |
| Translate a doc with admin's preferred tone | **Agent tool** | Quick, in-context |
| Use a model the orchestrator can't run (e.g. specifically DeepSeek for cheap tokens at scale) | **dispatch (DeepSeek)** | Different vendor / different budget |
| Periodic heavy crunching (weekly digest of 200 PRs) | **dispatch + cron** | Long-running, scheduled, would block the orchestrator if in-session |

If unsure, prefer the Agent tool. This skill is the escape hatch.

## Protocol

A task is one directory: `~/projects/<project>/tasks/<id>/`. The orchestrator and the external agent communicate **only** through files in this directory. Nothing else. The full directory schema lives in [`workspace-memory/SKILL.md`](../workspace-memory/SKILL.md) — do not duplicate. The dispatch-relevant subset:

```
tasks/<id>/
├── prompt.md          # task input (orchestrator writes)
├── context/           # input files the target may need (read-only for target)
├── result.md          # final answer (target writes)
├── log.md             # optional: target's running notes / partial progress (target may append)
├── pending_question.md # if target needs admin clarification (target writes; orchestrator clears)
└── state.json         # protocol state (orchestrator-write-only — see below)
```

### Who writes what (strict)

| File | Writer | Notes |
|---|---|---|
| `prompt.md` | orchestrator (once) | Created at dispatch; never modified after |
| `context/*` | orchestrator (once) | Read-only for target |
| `result.md` | **target** | Final output. Target writes this exactly once on completion |
| `log.md` | target (append) | Optional; tolerates torn final line |
| `pending_question.md` | target (write) / orchestrator (delete on resume) | Triggers `awaiting_clarification` |
| `state.json` | **orchestrator only** | Workers / targets must not write this. Concurrent writes will tear |

The orchestrator may also be the cron-driven poller / reaper updating `state.json` — they're the same writer-class.

### `prompt.md` schema

```markdown
---
task_id: <ulid>
created: <ISO timestamp>
target: <codex | deepseek | claude-code | cursor | …>
deadline: <ISO timestamp>
output: tasks/<id>/result.md
heartbeat: tasks/<id>/log.md   # target appends progress here every N minutes if it can
---

# Task

<one-paragraph problem statement>

## Inputs

<list of relevant files in context/, or inline content>

## Constraints

<anything the target needs to respect — coding style, length limit, tools to use/avoid>

## Done means

<acceptance criteria — what makes result.md complete>

## Instructions to the target agent

When you finish, write your final answer to `tasks/<id>/result.md` (path above) with frontmatter `status: ok` (or `failed` / `partial`). Do not print to stdout — the orchestrator only reads `result.md`.

If you need to leave running notes or signal liveness, append to `log.md` periodically (every 10 minutes if the work is long-running). Each line should start with an ISO timestamp.

If you need clarification from the admin before continuing, write `tasks/<id>/pending_question.md` (see workspace-memory SKILL §"Asking admin mid-task" for schema) and stop. Do NOT write `result.md` until you have an answer.

If you fail or get stuck, write `result.md` with `status: failed` in the frontmatter and stop.

Do not modify `state.json` or any file outside `tasks/<id>/` other than `context/` reads.
```

### `result.md` schema

```markdown
---
task_id: <same id>
completed: <ISO timestamp>
status: ok | failed | partial
target: <which agent produced this>
---

<answer body — markdown, code blocks, whatever the task called for>
```

## Dispatch flow

1. **Orchestrator** picks a task and a target. Generates an id (ulid recommended), writes `tasks/<id>/prompt.md` (atomic write, see workspace-memory), copies / symlinks any input files into `tasks/<id>/context/`. Sets `state.json` to `pending`.
2. **Spawn**: orchestrator calls `screen-control` to launch the target (e.g. open a terminal and run `codex`, or focus an existing Cursor window). The entry pointer it types is the absolute path to `prompt.md` plus a one-line instruction to "read this and follow it." That's all screen-control does — it never tries to read the target's screen output.
3. Orchestrator updates `state.json` to `running` with `spawned_at` and `last_heartbeat = spawned_at`.
4. **Target** reads `prompt.md`, does the work, optionally appends to `log.md`, finally writes `result.md`. The protocol section at the bottom of `prompt.md` tells it exactly this.
5. **Lazy reconciliation** (default for phase 1): the next time the orchestrator wakes up — for any reason: a new inbound message, an admin command, an explicit "check tasks" — it scans `~/projects/*/tasks/*/state.json` for `running` tasks and:
   - If `result.md` exists: read its frontmatter status, update `state.json` to `done` / `failed` / `partial`, relay the result to the requester whose `parent_request_id` chains back to the originating chat.
   - If `pending_question.md` exists: update `state.json` to `awaiting_clarification`, relay the question to admin.
   - If `log.md` was modified recently: refresh `last_heartbeat` from its mtime.
   - If `last_heartbeat` is older than 2× the heartbeat interval AND no `result.md` AND past `deadline`: mark `state.json` as `failed` with `reason: timeout` and notify admin.

   Lazy means the orchestrator does not actively poll — it reconciles on its own next activation. For most tasks (Codex jobs that finish in minutes, admin watching the conversation) this is fine.

6. **When lazy isn't enough** — if the user genuinely needs autonomous polling (e.g. a multi-day Codex run that should notify on completion even if the orchestrator is idle), set up a `CronCreate` job at that point. The polling logic is the same as step 5; only the trigger differs. Don't pre-allocate the cron job until a real task needs it.

### Why lazy first

The earlier draft of this protocol mandated a cron-driven `task-poller` from day one. That's premature: the orchestrator wakes up frequently enough (every inbound message) that lazy reconciliation handles 95% of cases with zero infrastructure. Add cron only when you've shipped a task that genuinely needs autonomous notification. See PROTOCOL.md §5 for the general "no preemptive cron" stance.

## Multi-turn (followups)

If the orchestrator needs to send a follow-up to the same external agent:

1. Orchestrator writes `tasks/<id>/followup_<N>.md` (same schema as `prompt.md`, plus `parent: prompt.md` or `parent: result_<N-1>.md`).
2. screen-control re-engages the target, points it at the new file.
3. Target writes `result_<N>.md`.
4. Repeat as needed.

The conversation history is the chain `prompt.md → result_1.md → followup_2.md → result_2.md → …` (consistent zero-padding optional). The whole thing is replay-able.

The target reads files in chain order. It knows which file to read next because the orchestrator's `screen-control` spawn instruction explicitly names the latest one.

## Failure modes

- **Target never writes result.md** → on next reconcile after `deadline`, mark `failed` with `reason: timeout`. Logs the dead task; admin can inspect `tasks/<id>/`.
- **Target writes malformed result.md** (missing frontmatter, unknown status) → mark `state.json` as `failed` with `reason: malformed_output`, notify admin.
- **Target crashes silently mid-task** → no `log.md` updates → `last_heartbeat` goes stale → caught on next reconcile after `deadline`. Stale-but-pre-deadline tasks are *not* killed (the target may legitimately be doing long work without writing logs). If you need stricter liveness, set a tighter `deadline`.
- **Target writes plausible but wrong result.md** → not detectable without verification; if the task has acceptance criteria, the orchestrator can spawn a separate verifier task (Agent tool) that reads `prompt.md` + `result.md` and rates it.
- **Two orchestrators dispatch the same task id** → don't. IDs are ulids; collisions vanishingly rare. If somehow it happens, the second `state.json` write loses; manual cleanup.

## Authorization

Spawning an external agent is sometimes a **sensitive operation** — it consumes credits / tokens / API budget on whatever account the target uses. If the dispatch was triggered by a non-admin, follow the auth flow in `auth-policy.md` (acknowledge → notify admin → wait → approve/deny/timeout) **before** writing `prompt.md` and spawning. If admin-triggered, proceed.

## Anti-patterns

- **Don't scrape the target's screen.** The whole point of this skill is markdown-only handoff. If the target can't write files, it's the wrong target — escalate to admin.
- **Don't share `tasks/<id>/` across orchestrators.** One orchestrator owns each task directory at a time.
- **Don't bake target-specific quirks into this skill.** Per-target launch / focus details (which CLI to invoke, which window title to focus, where the input field is) belong in `screen-control` or in adapter notes alongside it. This skill is the protocol; the substrate is screen-control.
- **Don't pre-allocate cron jobs for tasks that haven't shipped yet.** Lazy reconciliation on next inbound message is the default; add cron only when a real long-running task needs autonomous notification.
- **Don't let the target write `state.json`.** Workers signal by writing `result.md` / `log.md` / `pending_question.md`; the orchestrator owns state.

## Per-target adapter notes

These are short notes on how to invoke specific external agents. Each target has its own quirks; capture them here once we've actually run the target end-to-end.

### codex (OpenAI Codex CLI)

- **Default invocation (admin authorized full permissions 2026-05-01)**: `codex exec --skip-git-repo-check --full-auto "<prompt>" < /dev/null`
  - `--full-auto` = convenience alias for low-friction sandboxed automatic execution (workspace-write sandbox + auto-approve tool calls). This is the default for the operator's super-agent because it removes the per-task `--sandbox` guesswork.
  - For tasks that need to touch files outside the task dir or run network commands, escalate to `--dangerously-bypass-approvals-and-sandbox` — but that requires per-task admin authorization (it's an "always sensitive" operation per auth-policy.md).
- **Why `--skip-git-repo-check`**: codex defaults to refusing to run outside a "trusted" (git-tracked) directory. Our task dirs aren't git repos.
- **Why `< /dev/null`**: without an explicit stdin redirect, `codex exec` prints "Reading additional input from stdin..." and waits.
- **Login**: `codex login status` to verify; `codex login` (interactive) to authenticate via ChatGPT.
- **Verified end-to-end 2026-05-01** on a buggy.py review task. The first run failed with `--sandbox` default (read-only blocks result.md write); fixed with `--sandbox workspace-write`; admin then upgraded to `--full-auto` as the new default to remove that friction for future tasks.
