#!/usr/bin/env bash
# auto_nixelo_cycle.sh — Nixelo-specific post-merge lifecycle
# Calls pr_done_merge.sh for the generic done-done + merge,
# then creates a new date branch and re-enables manual cron.
#
# Exit codes:
#   0 = action taken or nothing to do
#   1 = error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$HOME/Desktop/nixelo"
TMUX_SESSION="nixelo"
MANUAL_TIMER="manual-terminal-nixelo.timer"
TELEGRAM_TO="780599199"

send_telegram() {
  openclaw message send --channel telegram --to "$TELEGRAM_TO" --message "$1" 2>/dev/null || true
}

# --- Phase 1: Generic done-done + merge ---
set +e
output=$("$SCRIPT_DIR/pr_done_merge.sh" nixelo 2>&1)
exit_code=$?
set -e

echo "$output"

# If not merged (waiting, skip, or error), stop here
if [[ $exit_code -ne 0 ]] || [[ ! "$output" =~ ^MERGED: && ! "$output" =~ ^DONE-DONE: ]]; then
  exit $exit_code
fi

# --- Phase 2: Nixelo-specific — new branch + restart manual cron ---
cd "$REPO_DIR"

# Create new date branch
new_branch=$(date '+%Y-%m-%d-%H-%M')
git checkout -b "$new_branch" 2>/dev/null

# Verify terminal is ready
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  send_telegram "⚠️ Auto-nixelo: tmux session '$TMUX_SESSION' missing. Can't enable manual cron."
  echo "ERROR:tmux-missing"
  exit 1
fi

pane=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id}' | head -n1)
pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')

if [[ "$pane_cmd" == "bash" ]]; then
  tmux send-keys -t "$TMUX_SESSION" "cc" Enter
  sleep 3
fi

# Clear stale pane history to prevent false done-loop detection by nudge script
# NOTE: Do NOT use tmux send-keys here — cc/cdx interprets it as user input
tmux clear-history -t "$TMUX_SESSION" 2>/dev/null

# Enable manual timer
systemctl --user start "$MANUAL_TIMER" 2>/dev/null

send_telegram "🔄 Auto-nixelo: new branch \`$new_branch\` created. Manual cron enabled. Let's go!"
echo "CYCLED:new-branch=$new_branch"
exit 0
