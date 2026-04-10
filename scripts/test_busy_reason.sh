#!/usr/bin/env bash
# Regression probe for terminal_classifier.sh
# Run: bash test_busy_reason.sh <tmux-session>
# Reports the shared terminal classification used by automation.

set -euo pipefail
session="${1:-nixelo}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/terminal_classifier.sh"

pane="$(tmux list-panes -t "$session" -F '#{pane_id}' | head -n1)"

state="$(classify_terminal "$session")"
echo "terminal_state: $state"

if [[ "$state" == IDLE:* ]]; then
  echo "RESULT: IDLE"
else
  echo "RESULT: NOT_IDLE"
fi

# Cross-check: any recent SENT in journal?
last_sent=$(journalctl --user -u "manual-terminal-${session}.service" --since "-30min" --no-pager 2>/dev/null | grep "SENT" | tail -1 || echo "NONE")
last_noop=$(journalctl --user -u "manual-terminal-${session}.service" --since "-30min" --no-pager 2>/dev/null | grep "NOOP" | tail -1 || echo "NONE")
echo "last_sent (30min): $last_sent"
echo "last_noop (30min): $last_noop"
