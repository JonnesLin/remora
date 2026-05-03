---
name: workspace-memory
description: Manage a project's persistent on-disk memory — PROGRESS.md (reverse-chronological recent activity), WORKING_MEMORY.md (durable lessons), memory/index.md (navigation), tasks/<id>/ (per-task state), attachments/ (binary blobs). Use when bootstrapping a new project workspace, when a subagent needs to read or update project state, when handling multi-turn task clarification, or when running periodic grooming (archive old progress, distill durable lessons, prune stale entries). Adapted from the workspace-memory pattern with super-agent extensions.
---

# workspace-memory

Persistent project memory in markdown. The substrate that makes resume-across-sessions work: every subagent reads these files at the start of a task and writes back at the end, so no in-memory state needs to survive `/clear` or `/compact`.

This SKILL is the **single source of truth** for the per-project layout, the bootstrap protocol, and the file-write atomicity rules. PROTOCOL.md and other SKILLs link here rather than duplicating.

## Layout (per project) — canonical

```
~/projects/<name>/
├── PROTOCOL.md                  # optional per-project protocol overrides; usually a shim → root PROTOCOL.md
├── PROGRESS.md                # reverse-chronological recent activity (newest first)
├── WORKING_MEMORY.md          # durable, curated facts and lessons
├── memory/
│   └── index.md               # optional pointer map for larger projects
├── archive/
│   └── progress/              # archived old PROGRESS entries (one file per month)
├── logs/                      # raw inbound logs (see project-intake)
├── meetings/                  # meeting notes
├── experiments/               # experiment records
├── daily/                     # daily updates
├── goals/                     # goal docs
├── misc/                      # uncategorized intake (flagged for re-classification)
├── attachments/               # binary blobs (images, PDFs, etc.) referenced by intake markdown
└── tasks/<id>/                # per-task scratch (see schema below)
```

### `tasks/<id>/` schema (canonical)

```
tasks/<id>/
├── prompt.md                  # task input (created by orchestrator)
├── context/                   # input files the worker may need (read-only for worker)
├── pending_question.md        # present iff state == awaiting_clarification
├── result.md                  # final output (created by worker)
├── log.md                     # optional running notes from worker
└── state.json                 # protocol state (orchestrator-write-only — see below)
```

`state.json` minimal shape:
```json
{
  "id": "<ulid>",
  "status": "pending|running|awaiting_clarification|done|failed|timeout",
  "spawned_at": "<ISO>",
  "deadline": "<ISO>",
  "last_heartbeat": "<ISO or null>",
  "target": "agent-tool|claude-code|codex|deepseek|cursor|...",
  "parent_request_id": "<ulid or null>"
}
```

### `attachments/` naming

Binary attachments referenced by intake markdown live under `attachments/`. Naming: `<source-msg-id-or-uuid>.<ext>`. Example: an image arriving in iMessage with message_id `5B897871-…` → `attachments/5B897871-….png`. Markdown files in `logs/`, `meetings/`, etc. reference attachments by relative path: `![screenshot](../attachments/<filename>)`.

Never inline binary content into markdown bodies. Markdown is for prose and links.

## File responsibilities

### `PROGRESS.md` — what just happened

- **Reverse-chronological**, newest entry at top.
- One entry per significant event: a task completed, a decision made, a file added, a meeting summarized.
- Each entry: ISO date + one-line summary + (optional) pointer to detail file.
- This is the **first thing** a subagent reads on bootstrap. It tells "what's the current state of this project."
- When it grows past ~200 lines, archive the oldest half to `archive/progress/<YYYY-MM>.md` during grooming.

### `WORKING_MEMORY.md` — what's durable

- Curated, non-chronological. Facts, lessons, conventions, hard-won knowledge.
- Things that should still be true 6 months from now.
- Examples: "the API uses cursor pagination, not offset"; "stakeholder X cares about Y"; "we tried approach Z and it didn't work because W."
- Updated rarely, by promotion from PROGRESS during grooming or by explicit "save this" from admin.
- The **second thing** a subagent reads on bootstrap.

### `memory/index.md` — where to look

- Optional. Only build it once a project has so many sub-docs that a subagent can't reasonably scan the directory.
- Map: topic → file. One line each.

## Bootstrap protocol (every subagent, every task)

1. Read project-level `PROTOCOL.md` if present, else root `PROTOCOL.md`.
2. Read `tasks/<id>/state.json`.
3. **Branch on state**:
   - `state.status == "pending"` → standard fresh task. Continue to step 4.
   - `state.status == "awaiting_clarification"` → resuming after admin clarification. Read `tasks/<id>/pending_question.md` and the latest admin reply (passed in via the dispatcher). Skip step 5–6 (no need to re-read project-level files unless the question requires them) and continue the original task from where it paused. Update `state.status` to `running`.
   - `state.status == "running"` and the dispatcher confirmed the previous worker died — this is a recovery dispatch. Treat the task as resumable: read everything that was written so far (`prompt.md`, `log.md` if present, any `pending_question.md`), decide whether to redo or continue. Mark `state.last_heartbeat` and proceed.
   - `state.status` in `{done, failed, timeout}` → terminal. Don't dispatch. (The dispatcher should have caught this; if a subagent ever sees this, log and return.)
4. Read `PROGRESS.md` (top 50–100 lines is usually enough).
5. Read `WORKING_MEMORY.md` (whole file).
6. If task references a specific area, also read relevant files in `memory/index.md` or topic subdirectories.
7. Do the work.
8. **Update PROGRESS.md** with a new top entry summarizing what happened (atomic write — see below).
9. If the task surfaced a durable lesson, also update WORKING_MEMORY.md (atomic write).
10. Write `tasks/<id>/result.md` with frontmatter:
    - `status: ok|failed|partial` (required).
    - `flag_for_distill: true|false` (optional; default false). Set to `true` when the task surfaced a lesson, pattern, or convention the worker thinks is worth crystallizing into WORKING_MEMORY or a new/updated skill. The orchestrator dispatches an immediate distill run on this project when it sees the flag (see distill SKILL §"When to invoke" → "Post-task flag"). Bar: would the lesson still be useful in 6 months?

    The orchestrator updates `state.json` to the terminal state on its next reconcile (lazy by default — see dispatch-external-agent SKILL §"Dispatch flow" step 5) and also reads the frontmatter at that point to act on `flag_for_distill`.

### Asking admin mid-task (the `awaiting_clarification` exit)

When the worker needs admin input it cannot derive from on-disk state:

1. Write `tasks/<id>/pending_question.md`:
   ```markdown
   ---
   asked_at: <ISO>
   asks: admin
   ---

   # Question

   <one-paragraph question for admin>

   ## Options (if applicable)

   - A: ...
   - B: ...
   ```
2. Update `tasks/<id>/state.json` `status: awaiting_clarification`.
3. Return a summary to the orchestrator: "task <id> needs admin input — see pending_question.md".
4. The orchestrator relays the question to admin via the originating channel.
5. When admin replies, the orchestrator dispatches a fresh subagent for the same `<id>`. That subagent reads `state.json`, sees `awaiting_clarification`, then reads `prompt.md`, `pending_question.md`, and the admin's reply (which the orchestrator passes in via the dispatch context), and re-derives where to continue. No transition-state blob is stored — the LLM re-derives from the original prompt plus the new answer.

If the work done before the question was expensive (e.g. a long external-agent run wrote partial results to `log.md`), the worker treats `log.md` as additional input on resume. Don't try to checkpoint internal context — the markdown trail is the only state.

## Atomic writes (mandatory for PROGRESS.md and WORKING_MEMORY.md)

Crashing mid-write to `PROGRESS.md` (especially since it's prepended) is the worst case for corruption — torn header, lost entries, or a half-written entry that survives. Always write via:

1. Read the existing file into memory.
2. Compute the new contents.
3. Write to `<path>.tmp` (same directory, same filesystem).
4. `fsync` the tmp file.
5. `rename(<path>.tmp, <path>)` — atomic on the same filesystem on macOS / Linux.

Same rule for `WORKING_MEMORY.md`. Same rule for `state.json`. Append-mostly files (`log.md`, audit logs) can use `O_APPEND` + small writes if the format tolerates a torn final line.

If `<path>.tmp` already exists when you start, a previous write was interrupted — log it and remove the tmp before proceeding.

## Verify before trusting

Memory files are working notes, not ground truth. Before acting on something recalled from memory:

- If the memory names a file path: check the file exists.
- If the memory names a function / config / record ID: confirm it's still there.
- If the memory describes a state ("project X is in phase 2"), reconcile with the most recent PROGRESS entries before assuming it's still true.

When memory and live state disagree, **trust live state and update the memory.**

## Grooming (manual or scheduled, deferred)

Grooming is the periodic cleanup of the project's memory files. There is **no default cron job** for it — admin asks the agent to groom when PROGRESS.md feels unwieldy, or sets up a recurring job via `CronCreate` if the project warrants it.

When admin does request grooming (or when a future cron job runs it):

**Daily-groom** (per project) — LLM-judged actions, one hard rule:
- LLM compresses entries that say substantially the same thing as adjacent ones (judgment, not regex).
- Removes entries the LLM verifies are now wrong by checking the live state.
- **Hard rule (size threshold, not LLM-judged)**: if `PROGRESS.md` exceeds ~200 lines, the oldest half is moved to `archive/progress/<YYYY-MM>.md`. Atomic write.

**Weekly-distill** (per project) — fully LLM-judged:
- LLM reads the past week's PROGRESS entries and decides which are durable lessons worth preserving.
- Promotes those into WORKING_MEMORY.md, de-duplicating by meaning (not byte-match) against existing entries.
- Updates `memory/index.md` if it exists.

The LLM's bar for promotion: would this still be useful in 6 months? If yes, promote. If unsure, leave it in PROGRESS (which will eventually archive).

Grooming is itself a task — dispatched as a subagent with `cwd = <project>`. It writes a meta-entry to PROGRESS noting the groom happened.

## Anti-patterns (don't)

- **Don't duplicate protocol across files.** This SKILL is the source of truth for layout / bootstrap / atomic writes; PROTOCOL.md and other SKILLs should link, not restate.
- **Don't archive too early.** PROGRESS entries from this week are "recent" — archiving them daily defeats the point.
- **Don't promote everything to WORKING_MEMORY.** Most session detail is ephemeral and belongs only in PROGRESS.
- **Don't write project state into the global agent memory** at `~/.claude/projects/<encoded>/memory/`. That memory is for the agent's cross-project knowledge (user identity, agent-wide preferences). Project state belongs in the project directory so it travels with the project.
- **Don't create shim files for AIs that aren't being used.** If only Claude Code touches this project, you don't need a `GEMINI.md` or `.github/copilot-instructions.md`.
- **Don't write `state.json` from a worker.** Workers signal by writing `result.md` / `log.md` / `pending_question.md`. Only the orchestrator updates `state.json`. Concurrent writes will tear.
- **Don't write to `PROGRESS.md` non-atomically.** Always tempfile + rename.
- **Not for ingesting raw material.** That's `project-intake`'s job — this skill manages already-organized memory; intake is the on-ramp.

## Reference

Original pattern: https://github.com/the workspace-memory pattern (the operator's prior work). Borrowed: three-layer split, single-canonical-entry, verify-before-trust, grooming cycle. Added for the super-agent: `tasks/<id>/` per-task scratch, `awaiting_clarification` resume (no transition blob — LLM re-derives from prompt + admin reply), `attachments/` convention, atomic-write mandate, orchestrator-write-only `state.json`.
