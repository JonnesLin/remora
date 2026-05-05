---
name: terminal-self
description: Drive the orchestrator's own terminal via `tmux send-keys` — issue `/clear`, `/compact`, or reconnect a dead channel without leaving the session. Works on any OS as long as the orchestrator runs inside a tmux pane (Linux, Mac with tmux, etc.). Use when the orchestrator needs to reset its own context, compact mid-session, or recover from a dropped MCP-channel connection.
---

# terminal-self

Drive the orchestrator's own Claude Code terminal via `tmux send-keys`. The orchestrator must be able to operate its own UI — no external agent can drive the session that *is* the orchestrator. This is the canonical skill for self-`/clear` and self-`/compact` on **both Linux and Mac**, as long as the orchestrator is launched inside a tmux pane (recommended setup on every host).

For Mac runtimes that are *not* inside tmux and need GUI-level driving (cliclick), see `screen-control/SKILL.md` — but prefer running inside tmux and using this skill.

## When to use

- **Self-`/clear`** (admin-commanded): admin asks the orchestrator to clear its own context. Required before long-lived loops where you don't want trailing context.
- **Self-`/compact`** (admin-commanded): admin asks the orchestrator to compact mid-session.
- **Channel reconnect** (cron-driven): the telegram channel's `bun server.ts` has died (or its API is unreachable) and Claude Code did not auto-respawn it.

## Mechanism — `tmux send-keys` to your own pane

When you run `tmux send-keys -t <pane> "<text>" Enter` from inside the same pane, the keys are queued. After your current turn ends and Claude Code shows the input prompt, the queued keys land in the prompt and the Enter submits them. This is the Linux equivalent of cliclick typing into the active terminal.

**Discover the pane** (orchestrator's own location):

```bash
tmux display-message -p '#S:#I.#P'   # e.g. "5:0.0"
```

**Find the orchestrator pane from outside Claude Code** (used by the cron daemon):

```bash
claude_pid=$(pgrep -f "claude .*--channels plugin:telegram" | head -1)
tty=$(ps -o tty= -p "$claude_pid" | tr -d ' ')
tmux list-panes -a -F '#S:#I.#P #{pane_tty}' | awk -v t="/dev/$tty" '$2==t{print $1; exit}'
```

## Self-`/clear` — admin-commanded only

`/clear` blows away conversation history. **Do not self-clear autonomously** — the risk of losing in-flight obligations outweighs the benefit. Only fire when the admin explicitly asks ("clear context", "/clear", "重置上下文" etc.).

Pre-flight checklist (mandatory):

1. **Persist all in-flight state to disk**:
   - `PROGRESS.md` for the active project — bring it current.
   - Any `tasks/<id>/state.json`, `pending_question.md`, `result.md`.
   - `~/projects/_admin/pending/` — every outstanding orchestrator obligation (auth deadlines, ETAs given to non-admins, "I'll get back to you" promises). See PROTOCOL.md §0.
   - Open task list — make sure each task description encodes enough context for cold restart.
2. **Confirm with admin** that you're about to clear (one short Telegram message — "全部存盘了，准备 /clear，1 分钟内不要发新指令").
3. **Send the keys**:

   ```bash
   tmux send-keys -t <my-pane> "/clear" Enter
   ```

4. After `/clear` runs, the next inbound message will reload `CLAUDE.md` → `PROTOCOL.md` and pick up state from disk. The very next admin message should ideally be one that re-establishes context ("继续 vlmversecast 监控" etc.) rather than a brand-new task.

## Self-`/compact` — admin-commanded

Lower-stakes than `/clear` because compact preserves the summary. But still admin-commanded only. Persist state first (same as `/clear`), then:

```bash
tmux send-keys -t <my-pane> "/compact" Enter
```

## Channel reconnect — cron-driven

Claude Code does NOT auto-respawn channel MCP servers when they die. The only respawn mechanism in v2.1.x is `/reload-plugins`, which reloads every installed plugin. As long as `telegram` is the only installed plugin (currently true), this is effectively channel-only. **If more plugins get installed, re-evaluate — there is no per-server reconnect command yet.**

Monitoring + recovery is owned by an external nohup daemon, not the orchestrator. The orchestrator just needs to know where the moving parts live.

### Files

| Path | Purpose |
|---|---|
| `~/.claude/channels/telegram/healthcheck.sh` | One-shot probe: bot.pid alive + Telegram getMe API. Triggers `/reload-plugins` via tmux send-keys on persistent failure. |
| `~/.claude/channels/telegram/healthcheck-daemon.sh` | Long-running wrapper. Runs healthcheck.sh every 5 min. |
| `~/.claude/channels/telegram/healthcheck.log` | Append-only log. One line per tick. Tail this to see channel health history. |
| `~/.claude/channels/telegram/.healthcheck.daemon.pid` | Daemon PID. |
| `~/.claude/channels/telegram/.healthcheck.cooldown` | Last reload timestamp; blocks repeat reloads inside 5 min. |
| `~/.claude/channels/telegram/.healthcheck.fails` | Consecutive API failure counter (debounce). |

### Probe logic

| Pid | API | Action |
|---|---|---|
| dead | — | Reload immediately (cooldown applies). |
| alive | up | OK, reset fail counter. |
| alive | down | Bump counter. Reload after 3 consecutive fails (≈ 15 min). |

The 3-fail debounce on API-only-down is intentional — short network blips are common and shouldn't reload the channel.

### Modes

- `HEALTHCHECK_MODE=enforce` (default): real reload on failure.
- `HEALTHCHECK_MODE=log_only`: detect + log only; never sends keys. Used during initial validation and as a kill-switch if reload starts misbehaving.

### Start / stop / status

```bash
# Start (default 5-min interval, enforce mode)
nohup /home/colligo/.claude/channels/telegram/healthcheck-daemon.sh > /dev/null 2>&1 &

# Start in log-only mode (test runs, validation)
HEALTHCHECK_MODE=log_only nohup /home/colligo/.claude/channels/telegram/healthcheck-daemon.sh > /dev/null 2>&1 &

# Stop
kill "$(cat ~/.claude/channels/telegram/.healthcheck.daemon.pid)"

# Status
ps -p "$(cat ~/.claude/channels/telegram/.healthcheck.daemon.pid 2>/dev/null)" 2>/dev/null \
    || echo "daemon not running"
tail -10 ~/.claude/channels/telegram/healthcheck.log
```

The daemon is idempotent: starting it again kills any prior instance via the pid file before claiming the slot.

## Admin command vocabulary

When the admin sends one of these via Telegram, the orchestrator should run the corresponding action (after pre-flight):

| Admin says (any language) | Orchestrator action |
|---|---|
| "/clear", "clear context", "重置上下文" | self-`/clear` (full pre-flight) |
| "/compact", "compact", "压缩" | self-`/compact` |
| "reconnect telegram", "重连 telegram", "channel 掉了" | manually invoke healthcheck or directly send `/reload-plugins` |

If the admin's intent is ambiguous (e.g., "重启" could mean clear, compact, or reconnect), confirm before acting.

## Don'ts

- **Don't autonomously `/clear` or `/compact`**. The blast radius is the entire conversation; only the admin can authorize it. (Cron-driven reconnect is the one exception, and only because reload-plugins is reversible.)
- **Don't fire `/reload-plugins` during a long-running operation that depends on plugin tools** (e.g., mid-Telegram-attachment-upload). The cron daemon's 5-min cooldown helps; supplement with awareness.
- **Don't treat `/reload-plugins` as channel-scoped forever**. Currently true because telegram is the only plugin. The moment another plugin is installed, the cron will reload it too — re-check before each new plugin install.
- **Don't send keys to a different tmux session** thinking it's yours. Always discover the pane via `pgrep` → `tty` → `tmux list-panes` rather than hardcoding.

## Verification commands

After installing the daemon:

```bash
# Daemon running?
ps -p "$(cat ~/.claude/channels/telegram/.healthcheck.daemon.pid)" -o pid,etime,cmd

# Last healthcheck tick (should be within INTERVAL_S)
tail -1 ~/.claude/channels/telegram/healthcheck.log

# Force a tick now (without waiting for the daemon)
HEALTHCHECK_MODE=log_only ~/.claude/channels/telegram/healthcheck.sh
```
