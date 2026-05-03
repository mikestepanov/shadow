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
TERMINAL_QUESTION_PANE=""
TERMINAL_QUESTION_STATUS=""
TERMINAL_QUESTION_REASON=""

reset_terminal_preflight() {
  TERMINAL_PREFLIGHT_PANE=""
  TERMINAL_PREFLIGHT_STATE=""
  TERMINAL_PREFLIGHT_REASON=""
  TERMINAL_PREFLIGHT_CURRENT_PATH=""
  TERMINAL_PREFLIGHT_EXPECTED_PATH=""
}

reset_terminal_question() {
  TERMINAL_QUESTION_PANE=""
  TERMINAL_QUESTION_STATUS=""
  TERMINAL_QUESTION_REASON=""
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

  # Retry classification up to 3 times with delays
  local attempts=0
  while (( attempts < 3 )); do
    TERMINAL_PREFLIGHT_STATE="$(classify_terminal_for_send "$session")"
    if [[ "$TERMINAL_PREFLIGHT_STATE" == IDLE:* ]]; then
      TERMINAL_PREFLIGHT_REASON="ok"
      return 0
    fi
    sleep 1
    (( attempts++ ))
  done

  TERMINAL_PREFLIGHT_REASON="terminal-not-ready"
  return 1
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

normalize_opencode_question_text() {
  local text="$1"
  printf '%s\n' "$text" | tail -100 | sed -E 's/^[[:space:]│┃╎╏▏▎▍▌▋▊▉█▐▕→▣▢▪⬝╹▀]+//'
}

is_opencode_question_ui() {
  local text="$1"
  local normalized
  normalized="$(normalize_opencode_question_text "$text")"

  printf '%s\n' "$normalized" | grep -Eq '(^# Questions$|Asked [0-9]+ question|enter submit.*esc dismiss)'
}

opencode_question_custom_answer_index() {
  local text="$1"
  local normalized line

  normalized="$(normalize_opencode_question_text "$text")"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)\.[[:space:]]+Type[[:space:]]+your[[:space:]]+own[[:space:]]+answer[[:space:]]*$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$normalized"

  return 1
}

opencode_question_autonomy_answer() {
  local session="$1"
  local repo_context=""

  case "$session" in
    nixelo)
      repo_context=' For Nixelo, recover priority and work order from ai-todos/README.md and the referenced ai-todos files. If the active queue is empty, promote the highest-priority non-blocked AI todo according to that todo order and continue without asking. Keep ai-todos accurate as you work. Do not run TypeScript or Biome checks; run only narrowly relevant checks if needed. Commit completed work with no verify and push.'
      ;;
    starthub)
      repo_context=' For StartHub, preserve architecture, type safety, and current task scope. You may create required task-scoped source, migration, and test/spec files in existing project directories.'
      ;;
  esac

  printf '%s' "Proceed autonomously. Use a 10x engineer bar: if the gap you found needs a complete overhaul to solve correctly, do the overhaul.${repo_context} Stay inside the active task scope. Do not create docs, secrets, credential files, deployment/Kubernetes/AWS changes, dependency changes, destructive scripts, git history rewrites, or out-of-scope files. If the question truly requires restricted action, product input, secrets, production/deployment access, destructive git history rewrites, or action outside the active task scope, stop and report BLOCKED_HUMAN with the reason. Otherwise make the safe local decision and continue."
}

select_opencode_custom_answer() {
  local pane="$1"
  local custom_index="$2"
  local answer="$3"
  local step

  [[ "$custom_index" =~ ^[0-9]+$ ]] || return 1
  (( custom_index >= 1 )) || return 1

  for ((step = 1; step < custom_index; step++)); do
    tmux send-keys -t "$pane" Down
    sleep 0.05
  done

  submit_tmux_enter "$pane"
  send_tmux_text_enter "$pane" "$answer"
}

answer_automatable_opencode_question() {
  local session="$1"
  local expected_path="$2"
  local pane current_path text custom_index answer

  reset_terminal_question

  if ! tmux has-session -t "$session" 2>/dev/null; then
    TERMINAL_QUESTION_STATUS="none"
    TERMINAL_QUESTION_REASON="session-missing"
    return 1
  fi

  pane="$(tmux_first_pane "$session")"
  if [[ -z "$pane" ]]; then
    TERMINAL_QUESTION_STATUS="none"
    TERMINAL_QUESTION_REASON="pane-missing"
    return 1
  fi

  TERMINAL_QUESTION_PANE="$pane"
  current_path="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null || true)"
  if [[ "$current_path" != "$expected_path" ]]; then
    TERMINAL_QUESTION_STATUS="none"
    TERMINAL_QUESTION_REASON="path-mismatch"
    return 1
  fi

  text="$(tmux capture-pane -t "$pane" -p 2>/dev/null || true)"
  if ! is_opencode_question_ui "$text"; then
    TERMINAL_QUESTION_STATUS="none"
    TERMINAL_QUESTION_REASON="no-question"
    return 1
  fi

  if ! answer="$(opencode_question_autonomy_answer "$session")"; then
    TERMINAL_QUESTION_STATUS="blocked"
    TERMINAL_QUESTION_REASON="unhandled-question"
    return 2
  fi

  if ! custom_index="$(opencode_question_custom_answer_index "$text")"; then
    TERMINAL_QUESTION_STATUS="blocked"
    TERMINAL_QUESTION_REASON="custom-answer-missing"
    return 2
  fi

  if select_opencode_custom_answer "$pane" "$custom_index" "$answer"; then
    TERMINAL_QUESTION_STATUS="answered"
    TERMINAL_QUESTION_REASON="custom-autonomy-answer"
    return 0
  fi

  TERMINAL_QUESTION_STATUS="blocked"
  TERMINAL_QUESTION_REASON="custom-answer-failed"
  return 2
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
