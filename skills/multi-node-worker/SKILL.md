---
name: multi-node-worker
description: Worker behavior for a GPU compute node in the multi-node cluster. Two components: (1) a lightweight status reporter cron that writes nvidia-smi output to GitHub every few minutes, and (2) the Claude Code agent task-executor that polls GitHub for assigned experiments, writes and runs code, and commits results. Deploy on each worker node.
---

# multi-node-worker

Worker node behavior for the multi-node GPU cluster. Splits into two independent components:

- **Status reporter**: a simple shell script run by cron — no AI, just nvidia-smi → GitHub
- **Task executor**: the Claude Code agent that picks up assigned experiments, writes code, runs it, records results

---

## Setup (first run on a new node)

Prompt the user for the following:

```
Required env vars (add to ~/.claude/settings.json "env"):
  GITHUB_TOKEN     - personal access token with repo read/write
  GITHUB_REPO      - owner/repo (same repo the PM uses)
  NODE_NAME        - this node's identifier (e.g. "node1"), must match cluster-config.json

Required tools on the node:
  git, nvidia-smi, python3 (or conda/uv), gh (GitHub CLI optional but helpful)
```

---

## Component 1: Status reporter

A shell script run by system cron every 3 minutes. No Claude Code involvement.

### Script: `~/bin/report-gpu-status.sh`

```bash
#!/bin/bash
set -euo pipefail

NODE_NAME="${NODE_NAME:?NODE_NAME not set}"
GITHUB_REPO="${GITHUB_REPO:?GITHUB_REPO not set}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN not set}"
REPO_DIR="${HOME}/cluster-repo"

# Clone or pull the repo
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" "$REPO_DIR"
fi
cd "$REPO_DIR"
git pull --quiet origin main

# Build GPU status JSON
GPU_JSON=$(nvidia-smi \
  --query-gpu=index,name,utilization.gpu,memory.used,memory.total \
  --format=csv,noheader,nounits | python3 - <<'EOF'
import sys, json, datetime

gpus = []
idle_count = 0
for line in sys.stdin.read().strip().split('\n'):
    idx, name, util, mem_used, mem_total = [x.strip() for x in line.split(',')]
    status = "idle" if int(util) < 5 else "busy"
    if status == "idle":
        idle_count += 1
    gpus.append({
        "index": int(idx),
        "name": name,
        "utilization_pct": int(util),
        "memory_used_mb": int(mem_used),
        "memory_total_mb": int(mem_total),
        "status": status
    })

import os
node = os.environ["NODE_NAME"]
print(json.dumps({
    "node": node,
    "updated_at": datetime.datetime.utcnow().isoformat() + "Z",
    "gpus": gpus,
    "idle_gpu_count": idle_count
}, indent=2))
EOF
)

# Write and commit
mkdir -p "nodes/${NODE_NAME}"
echo "$GPU_JSON" > "nodes/${NODE_NAME}/status.json"

git config user.email "worker@cluster" 2>/dev/null || true
git config user.name "${NODE_NAME}" 2>/dev/null || true
git add "nodes/${NODE_NAME}/status.json"
git diff --cached --quiet || git commit -m "status: ${NODE_NAME} $(date -u +%H:%M)" && git push origin main
```

### Install system cron

```bash
chmod +x ~/bin/report-gpu-status.sh
# Add to crontab:
# */3 * * * * /home/<user>/bin/report-gpu-status.sh >> /tmp/gpu-status.log 2>&1
crontab -e
```

---

## Component 2: Task executor (Claude Code agent)

The Claude Code agent on the worker node polls GitHub for tasks assigned to this node and executes them.

### Poll cycle (CronCreate, every 3 minutes)

```
1. cd ~/cluster-repo && git pull origin main
2. Check nodes/<NODE_NAME>/tasks/*/state.json for status == "pending"
3. For each pending task:
   a. Read nodes/<NODE_NAME>/tasks/<task-id>/prompt.md
   b. Set state.json status → "running", add started_at timestamp, commit + push
   c. Execute the task (see §Task execution)
   d. Write result to nodes/<NODE_NAME>/tasks/<task-id>/result.md
   e. Set state.json status → "done" (or "failed"), add finished_at, commit + push
```

Only process one task at a time per invocation. If multiple tasks are pending, take the oldest first.

### Task execution

When a task is assigned:

1. **Read prompt.md carefully**: understand the objective, implementation notes, success criteria, expected duration

2. **Set up workspace**: create a fresh directory `~/experiments/<task-id>/`

3. **Write code**: implement the experiment based on prompt.md instructions
   - Use the environment available on the node (check what's installed: `conda env list`, `pip list`, etc.)
   - Write clean, runnable code — prioritize correctness over cleverness
   - Save all code to `~/experiments/<task-id>/`

4. **Run the experiment**:
   - Capture stdout/stderr to a log file
   - Monitor for errors; if the run fails, investigate and attempt one fix before marking as failed
   - Record key metrics as they appear

5. **Write result.md**:

```markdown
---
task_id: <task-id>
exp_id: <exp-id from prompt>
node: <NODE_NAME>
started_at: <ISO>
finished_at: <ISO>
status: done | failed
---

## Results

<key metrics, numbers, observations>

## Code location
~/experiments/<task-id>/  (also committed to GitHub at experiments/code/<task-id>/)

## Logs
<first and last 20 lines of run log, or key excerpts>

## Notes
<anything surprising, what worked, what didn't>
```

6. **Commit code and result to GitHub**:
   ```bash
   cp -r ~/experiments/<task-id>/ ~/cluster-repo/experiments/code/<task-id>/
   git add experiments/code/<task-id>/ nodes/<NODE_NAME>/tasks/<task-id>/result.md
   git commit -m "result: <task-id> — <one-line outcome>"
   git push origin main
   ```

7. **Update state.json** → `"done"` or `"failed"`, push.

### Error handling

- If the code fails to run: make one debugging attempt (read the error, fix the most likely cause, re-run)
- If it fails again: mark state as `"failed"`, write the error to result.md, push, move on
- Never loop indefinitely trying to fix a broken run — fail fast, let the PM know

### Environment hygiene

- Each experiment runs in its own directory
- Clean up GPU memory after each run (`torch.cuda.empty_cache()` or process exit)
- Do not leave zombie processes; check `nvidia-smi` after each run

---

## Cold start / session resume

On each Claude Code session start on a worker node:

1. Read `NODE_NAME` from env
2. Register the poll cron via CronCreate (3-minute interval)
3. Do an immediate poll cycle (don't wait for first cron fire)
4. Report to PM via GitHub: update status.json with current GPU state
