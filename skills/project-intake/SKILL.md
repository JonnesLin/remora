---
name: project-intake
description: Classify and file inbound project material — logs, meeting notes, experiment records, daily updates, goals, miscellaneous artifacts — into the project's directory structure, then update PROGRESS.md and (where warranted) WORKING_MEMORY.md. Use when the admin sends raw material to be organized into an existing project, or when bootstrapping a new project from a pile of unsorted notes.
---

# project-intake

Take a stream of mixed inbound material (the admin pastes a meeting transcript, drops in a log file, sends a daily update, lists goals, etc.) and turn it into well-organized project state. Operates on a single project workspace at a time.

## When to invoke

- Admin sends new material that belongs to a known project
- Bootstrapping a new project from a pile of unsorted notes
- Periodic re-classification (something filed wrong)

## Inputs

- The new material (text, attached file, image, binary blob)
- The target project name (or "figure out which project" if ambiguous — escalate to admin if unclear)

## Binary attachments

If the inbound material includes a binary file (image, PDF, audio, screenshot), copy it to `~/projects/<name>/attachments/<source-msg-id-or-uuid>.<ext>` per the convention in [`workspace-memory/SKILL.md`](../workspace-memory/SKILL.md) §"`attachments/` naming". The markdown file you write into the appropriate bucket references the attachment by relative path:

```markdown
![meeting whiteboard](../attachments/A3B7C2F1-meeting-board.jpg)
```

Never inline binary content (base64, hex dumps, etc.) into markdown bodies. Markdown is for prose and links; the binary lives in `attachments/`. Original filename can be preserved in the frontmatter `source` field if useful.

## Classification (LLM-judged)

Read the inbound material. Decide which bucket fits best. The buckets exist as conventions, not as a strict mapping rule — judge by what the material actually is, not by keyword matching.

Buckets and example contents (these are hints, not a decision tree):

- **log** → `logs/<YYYY-MM-DD>-<slug>.md`. Hints: server logs, error traces, raw output dumps, performance metrics, debug session writeups.
- **meeting** → `meetings/<YYYY-MM-DD>-<slug>.md`. Hints: meeting transcripts, summaries, decisions made together with someone.
- **experiment** → `experiments/<id>-<slug>.md`. Hints: experiment designs, runs, results, ablations.
- **daily** → `daily/<YYYY-MM-DD>.md`. Hints: daily standup, end-of-day update, "what I did today."
- **goal** → `goals/<slug>.md`. Hints: OKRs, project goals, milestones, success criteria.
- **misc** → `misc/<YYYY-MM-DD>-<slug>.md`. Hints: doesn't fit anywhere obvious; flag for re-classification.

Slug is a short kebab-case summary the LLM picks based on the content (e.g., `2026-05-01-cuda-oom-stale-process`). No fixed slugging algorithm — the LLM chooses something descriptive and reasonable.

If a single inbound message contains multiple types (e.g. "here's today's update plus a meeting summary plus a new goal"), split it: write each piece to its own file in the right bucket. The LLM decides where the splits are.

Misclassification recovery: if a later groom or admin notices a wrong bucket, the file is moved (filesystem `mv`) and PROGRESS.md is updated with a "reclassified <slug>: <old bucket> → <new bucket>" entry.

## Output protocol (per intake)

For each piece of material:

1. **Classify** → bucket
2. **Write** → `<bucket>/<filename>.md` with frontmatter:
   ```markdown
   ---
   ingested: <ISO timestamp>
   source: <e.g. "imessage from admin", "email from alice@…", "uploaded file foo.txt">
   bucket: <log|meeting|experiment|daily|goal|misc>
   ---

   <body — the original content, lightly cleaned up; preserve verbatim quotes>
   ```
3. **Append PROGRESS.md** with a top entry: `<ISO date> — ingested <bucket>: <slug> (<one-line summary>)`. Use the atomic-write pattern from [`workspace-memory/SKILL.md`](../workspace-memory/SKILL.md) §"Atomic writes" — `PROGRESS.md` is prepend-most-recent, so a torn write is the worst case for corruption.
4. **If a durable lesson surfaces** (a goal locked in, a constraint discovered, a stakeholder preference): also update `WORKING_MEMORY.md` (atomic write).

## After-action: tell the admin

After filing, summarize what was done:
- What was filed where (bucket + filename)
- Any classification you were unsure about
- Anything that surfaced a durable update to WORKING_MEMORY.md
- Anything that needs admin's attention (a goal that conflicts with an existing one; a meeting decision that contradicts WORKING_MEMORY)

## Anti-patterns

- **Don't paraphrase to the point of losing fidelity.** The point of having raw material in `logs/` / `meetings/` is that it's the source. Light cleanup (formatting, removing chat noise) is fine; rewriting in your own voice is not.
- **Don't auto-create new buckets.** If something doesn't fit, file under `misc/` and flag for admin. Adding new top-level buckets is a structural change — needs admin sign-off.
- **Don't update WORKING_MEMORY for transient observations.** Each WORKING_MEMORY entry should still be useful in 6 months.
- **Don't classify across projects.** This skill operates on one project at a time. If admin sends material that belongs to multiple projects, escalate — don't guess.

## Idempotency (LLM-judged with one hard rule)

**Hard rule for binaries:** before copying a binary attachment, compute its SHA-256 hash. If a file with the same hash already exists in `attachments/`, reuse the existing one and just reference it from the new markdown — don't double-store the bytes. Hashing is deterministic; this is not LLM judgment.

**LLM-judged for text:** when filing a new piece of textual material, the worker scans the relevant bucket directory and decides whether what's about to be written is meaningfully the same as an existing file. Exact byte-match is one signal but not the only one — the same meeting summarized twice with slightly different prose is still a duplicate. If the LLM judges it duplicate, reply "already ingested at <path>" and do not double-file. If unsure, file as new but reference the prior file in the frontmatter `related:` field.

## Interaction with workspace-memory grooming

Project-intake writes to PROGRESS.md and (occasionally) WORKING_MEMORY.md. The `workspace-memory` grooming job reads those files on its own schedule — intake doesn't trigger grooming directly. Each skill stays in its lane.
