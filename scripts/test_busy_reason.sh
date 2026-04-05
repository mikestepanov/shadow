#!/usr/bin/env bash
# Regression tests for busy_reason / is_terminal_busy
# Run: bash test_busy_reason.sh <tmux-session>
# Verifies that an idle prompt is detected as idle even with stale UI markers in scrollback

set -euo pipefail
session="${1:-nixelo}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/terminal_mode_guard.sh"

pane="$(tmux list-panes -t "$session" -F '#{pane_id}' | head -n1)"

reason="$(busy_reason "$pane")"
echo "busy_reason: $reason"

if is_terminal_busy "$pane"; then
  echo "RESULT: BUSY"
else
  echo "RESULT: IDLE"
fi

# Cross-check: is cursor at prompt?
pstate="$(prompt_state "$pane")"
echo "prompt_state: $pstate"

# Cross-check: any recent SENT in journal?
last_sent=$(journalctl --user -u "manual-terminal-${session}.service" --since "-30min" --no-pager 2>/dev/null | grep "SENT" | tail -1 || echo "NONE")
last_noop=$(journalctl --user -u "manual-terminal-${session}.service" --since "-30min" --no-pager 2>/dev/null | grep "NOOP" | tail -1 || echo "NONE")
echo "last_sent (30min): $last_sent"
echo "last_noop (30min): $last_noop"
