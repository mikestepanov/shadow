#!/usr/bin/env bash
# check-terminal-stale.sh — returns STALE/ACTIVE per repo for heartbeat use
# Usage: check-terminal-stale.sh <session> <repo_path> <stale_minutes>
set -euo pipefail

session="${1:?usage: $0 <session> <repo_path> <stale_minutes>}"
repo_path="${2:?}"
stale_minutes="${3:-120}"

# Check last commit age
last_commit_epoch=$(cd "$repo_path" && git log -1 --format="%ct" 2>/dev/null || echo "0")
now_epoch=$(date +%s)
age_minutes=$(( (now_epoch - last_commit_epoch) / 60 ))

# Check pane state
if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "STALE:session-missing age=${age_minutes}m"
  exit 1
fi

pane=$(tmux list-panes -t "$session" -F '#{pane_id}' | head -n1)
pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')

# Check if at idle prompt (last 5 lines contain bare prompt marker)
pane_tail=$(tmux capture-pane -t "$pane" -p | tail -5)
at_prompt=false
if printf '%s\n' "$pane_tail" | grep -qE '^(❯|›|\$)\s*$'; then
  at_prompt=true
fi

if [[ "$age_minutes" -ge "$stale_minutes" ]]; then
  echo "STALE:commits age=${age_minutes}m pane_cmd=${pane_cmd} at_prompt=${at_prompt}"
  exit 1
fi

if [[ "$at_prompt" == "true" && "$age_minutes" -ge 30 ]]; then
  echo "STALE:idle-prompt age=${age_minutes}m pane_cmd=${pane_cmd}"
  exit 1
fi

echo "ACTIVE age=${age_minutes}m pane_cmd=${pane_cmd} at_prompt=${at_prompt}"
exit 0
