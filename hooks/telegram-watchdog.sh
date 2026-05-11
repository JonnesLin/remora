#!/usr/bin/env bash
# Telegram plugin watchdog — runs after every response via Claude Code Stop hook.
# If the Telegram bun server is not running, sends /reload-plugins to the tmux session.

TMUX_SESSION="${REMORA_TMUX_SESSION:-remora-telegram}"

# Check if the Telegram bun server process is alive
if ! pgrep -f "telegram.*server\.ts" > /dev/null 2>&1; then
    # Only act if we're inside a tmux session we can target
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux send-keys -t "$TMUX_SESSION" '/reload-plugins' Enter
    fi
fi
