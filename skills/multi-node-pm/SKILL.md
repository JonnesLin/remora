---
name: multi-node-pm
description: PM orchestration for a multi-node GPU compute cluster. Handles experiment intake (files, audio, DMs), maintains an experiment queue on GitHub, auto-dispatches to idle GPUs, tracks results, and generates weekly reports. Use when the admin sends new experiments or asks for cluster status, or when a cron poll fires.
---

# multi-node-pm

Project manager for a multi-node GPU cluster. The PM (this agent) holds all context, maintains the experiment queue, auto-dispatches work to idle nodes, and synthesizes results for the admin.

---

## Setup (first run)

Prompt the user for the following if not already in env/config:

```
Required env vars (add to ~/.claude/settings.json "env"):
  GITHUB_TOKEN        - personal access token with repo read/write
  GITHUB_REPO         - owner/repo (e.g. "alice/experiments")
  OPENAI_API_KEY      - for Whisper audio transcription
  ADMIN_TG_CHAT_ID    - Telegram chat_id for DM notifications (numeric)

Required config (save to ~/projects/_admin/cluster-config.json):
  {
    "nodes": ["node1", "node2", ...],   // names matching GitHub nodes/<name>/
    "dispatch_branch": "main",
    "poll_interval_minutes": 3
  }
```

After setup, register crons (see §Cron jobs).

---

## GitHub repo layout

```
nodes/
  <node-name>/
    status.json          # written by worker; read by PM
    tasks/
      <task-id>/
        prompt.md        # written by PM; read by worker
        result.md        # written by worker; read by PM
        state.json       # { "status": "pending|running|done|failed", "started_at": "", "eta": "" }

experiments/
  pending/
    <exp-id>.md          # queued experiments awaiting dispatch
  running/
    <exp-id>.md          # currently dispatched
  done/
    <exp-id>.md          # completed (includes result summary)
  failed/
    <exp-id>.md

weekly-reports/
  <YYYY-WW>.md
```

### `nodes/<name>/status.json` schema
```json
{
  "node": "node1",
  "updated_at": "<ISO>",
  "gpus": [
    { "index": 0, "name": "B200", "utilization_pct": 0, "memory_used_mb": 0, "memory_total_mb": 141312, "status": "idle" },
    ...
  ],
  "current_tasks": ["<task-id>", ...],
  "idle_gpu_count": 8
}
```

### `experiments/pending/<exp-id>.md` schema
```markdown
---
exp_id: <ulid>
title: <one-line description>
added_at: <ISO>
gpu_count: 1        # how many GPUs this experiment needs
priority: normal    # normal | high
---

## Objective
<what we want to learn>

## Implementation notes
<approach, key parameters, references>

## Success criteria
<what metrics matter, what values would be good>

## Expected duration
<rough estimate, e.g. "2–4 hours">
```

---

## Cron jobs

Register these via CronCreate on each session start (read from `~/projects/_admin/cron-registry.md`):

```markdown
## Active Crons

- poll-cluster: every 3 minutes — check node status, dispatch pending experiments to idle GPUs, pick up completed results
- weekly-report: every Friday 16:30 — generate weekly experiment report, DM admin
```

On cold start / session resume: read `cron-registry.md`, re-register all active crons via CronCreate.

---

## Intake flow (when admin sends files/audio/text via Telegram)

1. **Audio** (`.ogg`, `.mp3`, `.m4a`, `.wav`):
   - Download via `download_attachment`
   - Transcribe via OpenAI Whisper: `POST https://api.openai.com/v1/audio/transcriptions` with `model=whisper-1`
   - Save transcript to the relevant project's `meetings/` or `misc/` directory with ISO timestamp filename
   - Summarize key points and add to project `PROGRESS.md`

2. **Documents** (PDF, text, code):
   - Download, read, classify (meeting notes / reference / experiment spec / other)
   - File into the appropriate project directory
   - Extract any experiment ideas → add to experiment queue (see §Adding experiments)

3. **Text / DM**:
   - If it describes a new experiment idea → add to queue
   - If it's context / background → update project `WORKING_MEMORY.md`
   - If it's a question → answer from known context

---

## Adding experiments to the queue

When admin describes a new experiment (text, voice, or doc):

1. Extract: objective, approach, GPU count needed, priority, expected duration
2. Generate a ULID for `exp_id`
3. Write `experiments/pending/<exp-id>.md` with the schema above
4. Commit and push to GitHub
5. Reply to admin confirming the experiment was queued, with the exp_id and brief summary

If multiple experiments are described at once, add each separately with unique IDs.

---

## Poll cycle (fires every 3 minutes via cron)

```
1. Fetch nodes/*/status.json from GitHub
2. Identify idle nodes (idle_gpu_count > 0)
3. Fetch experiments/pending/*.md, sort by priority then added_at
4. For each idle node with enough free GPUs:
   a. Take the top-priority pending experiment that fits (gpu_count ≤ idle_gpu_count)
   b. Write nodes/<node>/tasks/<exp-id>/prompt.md with full experiment spec
   c. Write nodes/<node>/tasks/<exp-id>/state.json { status: "pending" }
   d. Move experiments/pending/<exp-id>.md → experiments/running/<exp-id>.md
   e. Commit and push
   f. DM admin: "Dispatched <exp-id> ('<title>') to <node>"
5. Check nodes/*/tasks/*/state.json for status == "done" or "failed"
6. For each completed task:
   a. Read result.md
   b. Move experiments/running/<exp-id>.md → experiments/done/<exp-id>.md, append result summary
   c. Update project PROGRESS.md with outcome
   d. DM admin: "✓ <exp-id> done on <node>: <one-line result summary>"
   e. If failed: DM admin with error summary, move to experiments/failed/
```

---

## Weekly report (fires Friday 16:30)

Aggregate from `experiments/done/` (past 7 days):

```markdown
# Week <YYYY-WW> Experiment Report

## Summary
- Experiments completed: N
- Experiments still running: N
- Experiments failed: N

## Completed experiments
| ID | Title | Node | Outcome |
|----|-------|------|---------|
...

## Key findings
<1–3 bullet points on what we learned>

## Recommended next steps
<what to try next week based on results>

## Pending queue
<experiments still waiting to run>
```

Save to `weekly-reports/<YYYY-WW>.md` on GitHub. DM admin the full report.

---

## Cluster status (on-demand)

When admin asks "what's running" / "cluster status" / similar:

Fetch current `nodes/*/status.json` and `experiments/running/*.md`, format as:

```
Cluster status (as of <time>):
node1: 6/8 GPUs busy — running exp-01ABC (eta 1.5h), exp-02DEF (eta 3h)
node2: 0/8 GPUs busy — idle
node3: 8/8 GPUs busy — running exp-03GHI (eta 45m)

Queue: 4 experiments pending
```
