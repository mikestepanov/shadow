#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERMINAL_CLASSIFIER="${TERMINAL_CLASSIFIER:-$SCRIPT_DIR/terminal_classifier.sh}"
source "$TERMINAL_CLASSIFIER"

TERMINAL_PREFLIGHT_PANE=""
TERMINAL_PREFLIGHT_STATE=""
TERMINAL_PREFLIGHT_REASON=""
TERMINAL_PREFLIGHT_CURRENT_PATH=""
TERMINAL_PREFLIGHT_EXPECTED_PATH=""

reset_terminal_preflight() {
  TERMINAL_PREFLIGHT_PANE=""
  TERMINAL_PREFLIGHT_STATE=""
  TERMINAL_PREFLIGHT_REASON=""
  TERMINAL_PREFLIGHT_CURRENT_PATH=""
  TERMINAL_PREFLIGHT_EXPECTED_PATH=""
}

tmux_first_pane() {
  tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | head -n1
}

terminal_send_preflight() {
  local session="$1"
  local expected_path="$2"

  reset_terminal_preflight
  TERMINAL_PREFLIGHT_EXPECTED_PATH="$expected_path"

  if ! tmux has-session -t "$session" 2>/dev/null; then
    TERMINAL_PREFLIGHT_REASON="session-missing"
    return 1
  fi

  TERMINAL_PREFLIGHT_PANE="$(tmux_first_pane "$session")"
  if [[ -z "$TERMINAL_PREFLIGHT_PANE" ]]; then
    TERMINAL_PREFLIGHT_REASON="pane-missing"
    return 1
  fi

  TERMINAL_PREFLIGHT_CURRENT_PATH="$(tmux display-message -p -t "$TERMINAL_PREFLIGHT_PANE" '#{pane_current_path}' 2>/dev/null || true)"
  if [[ "$TERMINAL_PREFLIGHT_CURRENT_PATH" != "$expected_path" ]]; then
    TERMINAL_PREFLIGHT_REASON="path-mismatch"
    return 1
  fi

  TERMINAL_PREFLIGHT_STATE="$(classify_terminal_for_send "$session")"
  if [[ "$TERMINAL_PREFLIGHT_STATE" != IDLE:* ]]; then
    TERMINAL_PREFLIGHT_REASON="terminal-not-ready"
    return 1
  fi

  TERMINAL_PREFLIGHT_REASON="ok"
  return 0
}

send_tmux_text_enter() {
  local target="$1"
  shift
  local txt="$*"
  local buffer_name="opencode-send-$$-$RANDOM"

  tmux set-buffer -b "$buffer_name" -- "$txt"
  tmux paste-buffer -d -b "$buffer_name" -t "$target"
  sleep 1
  tmux send-keys -t "$target" Enter
  sleep 0.12
}

submit_tmux_enter() {
  local target="$1"
  tmux send-keys -t "$target" Enter
  sleep 0.12
}

repo_dirty_worktree_count() {
  local workdir="$1"
  local status
  status="$(cd "$workdir" 2>/dev/null && git status --porcelain 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    echo 0
    return 0
  fi

  printf '%s\n' "$status" | wc -l | tr -d '[:space:]'
}

dirty_worktree_recovery_prompt() {
  local mode="$1"
  local session="$2"
  local workdir="$3"
  local dirty_count="$4"
  local branch

  branch="$(cd "$workdir" 2>/dev/null && git branch --show-current 2>/dev/null || echo "current-branch")"

  printf '%s' "The ${mode} automation for ${session} is blocked by ${dirty_count} uncommitted changes on branch ${branch}. Stop starting new work. Finish the current changes completely: inspect the latest commit, hook, or validation failure; fix the blocker; run the required local checks; commit all completed changes; and push the branch. If commit or push fails again, keep fixing the blocker until the worktree is clean."
}
