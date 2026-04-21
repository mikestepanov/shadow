#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$HOME/Desktop/nixelo"
TARGET_BRANCH="dev"
TMUX_SESSION="nixelo"
AUTO_GATE_FILE="$HOME/Desktop/shadow/auto-nixelo-enabled.json"
MANUAL_TIMER="manual-terminal-nixelo.timer"
PRCI_TIMER="prci-terminal-nixelo.timer"
TIMERS_INSTALL="$SCRIPT_DIR/timers-install"
TELEGRAM_TO="780599199"

send_telegram() {
  local token="${TELEGRAM_BOT_TOKEN:-}"
  [[ -n "$token" ]] || return 0

  curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${TELEGRAM_TO}" \
    --data-urlencode "text=$1" \
    >/dev/null 2>&1 || true
}

auto_enabled() {
  node -e '
    const fs = require("fs");
    try {
      const parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(parsed && parsed.enabled ? "true" : "false");
    } catch {
      process.stdout.write("false");
    }
  ' "$AUTO_GATE_FILE"
}

run_or_error() {
  local error_prefix="$1"
  shift

  local output=""
  if output="$($@ 2>&1)"; then
    return 0
  fi

  output="${output//$'\n'/; }"
  echo "${error_prefix}${output:+ detail=$output}"
  exit 1
}

wait_for_unit_inactive() {
  local unit="$1"
  local waited_s=0

  while true; do
    local state
    state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" != "active" && "$state" != "activating" && "$state" != "reloading" ]]; then
      return 0
    fi

    if (( waited_s >= 45 )); then
      echo "ERROR:unit-still-active unit=$unit state=$state waited_s=$waited_s"
      exit 1
    fi

    sleep 1
    waited_s=$((waited_s + 1))
  done
}

dirty_worktree_count() {
  local status
  status="$(git status --porcelain)"
  if [[ -z "$status" ]]; then
    echo 0
    return 0
  fi

  printf '%s\n' "$status" | wc -l | tr -d '[:space:]'
}

finish_post_merge_cycle() {
  local pr_number="$1"
  local source_branch="$2"
  local prci_summary="$3"

  local dirty_count
  dirty_count="$(dirty_worktree_count)"
  if [[ "$dirty_count" != "0" ]]; then
    echo "WAIT:POST-MERGE:dirty-worktree branch=$source_branch changes=$dirty_count pr=$pr_number $prci_summary"
    exit 0
  fi

  run_or_error "ERROR:checkout-target-failed target=$TARGET_BRANCH" git checkout "$TARGET_BRANCH"
  run_or_error "ERROR:pull-target-failed target=$TARGET_BRANCH" git pull --ff-only

  local new_branch
  new_branch="$(date '+%Y-%m-%d-%H-%M')"
  if git show-ref --verify --quiet "refs/heads/$new_branch"; then
    echo "ERROR:branch-exists $new_branch"
    exit 1
  fi

  run_or_error "ERROR:create-branch-failed branch=$new_branch" git checkout -b "$new_branch"

  local tmux_state="missing"
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux clear-history -t "$TMUX_SESSION" 2>/dev/null || true
    tmux_state="ready"
  fi

  systemctl --user unmask "$MANUAL_TIMER" >/dev/null 2>&1 || true
  systemctl --user enable --now "$MANUAL_TIMER" >/dev/null 2>&1 || true

  local manual_active
  manual_active="$(timer_active "$MANUAL_TIMER")"
  local manual_enabled
  manual_enabled="$(timer_enabled "$MANUAL_TIMER")"

  if [[ "$manual_active" != "active" || "$manual_enabled" != "enabled" ]]; then
    echo "ERROR:manual-timer-not-ready active=$manual_active enabled=$manual_enabled"
    exit 1
  fi

  send_telegram "🔄 Auto-nixelo: PR #$pr_number merged, switched to $TARGET_BRANCH, created branch $new_branch, manual timer re-enabled, tmux=${tmux_state}."
  echo "CYCLED:new-branch=$new_branch pr=$pr_number prci=$prci_summary manual_active=$manual_active manual_enabled=$manual_enabled tmux=$tmux_state"
  exit 0
}

ensure_timer_installed() {
  "$TIMERS_INSTALL" --install-only "${1%.timer}" >/dev/null
}

timer_active() {
  local state
  state="$(systemctl --user is-active "$1" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    printf '%s\n' "$state"
    return 0
  fi

  echo "inactive"
}

timer_enabled() {
  local state
  state="$(systemctl --user is-enabled "$1" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    printf '%s\n' "$state"
    return 0
  fi

  echo "disabled"
}

if [[ "$(auto_enabled)" != "true" ]]; then
  echo "SKIP:auto-disabled"
  exit 0
fi

ensure_timer_installed "$MANUAL_TIMER"
ensure_timer_installed "$PRCI_TIMER"

cd "$REPO_DIR"

branch="$(git branch --show-current)"
open_pr_number="$(gh pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || echo "")"
merged_pr_number="$(gh pr list --head "$branch" --state merged --json number -q '.[0].number' 2>/dev/null || echo "")"

prci_active="$(timer_active "$PRCI_TIMER")"
prci_enabled="$(timer_enabled "$PRCI_TIMER")"
if [[ "$prci_active" != "active" && "$prci_enabled" != "enabled" ]]; then
  if [[ "$branch" != "$TARGET_BRANCH" && -z "$open_pr_number" && -n "$merged_pr_number" ]]; then
    finish_post_merge_cycle "$merged_pr_number" "$branch" "active=$prci_active enabled=$prci_enabled"
  fi

  echo "SKIP:prci-off active=${prci_active} enabled=${prci_enabled}"
  exit 0
fi

set +e
gate_output="$($SCRIPT_DIR/is_done_done.sh nixelo 2>&1)"
gate_exit=$?
set -e

if [[ $gate_exit -eq 2 ]]; then
  echo "WAIT:${gate_output}"
  exit 0
fi

if [[ $gate_exit -ne 0 ]]; then
  printf '%s\n' "$gate_output" >&2
  exit $gate_exit
fi

wait_for_unit_inactive "prci-terminal-nixelo.service"

pr_number="$open_pr_number"
if [[ -z "$pr_number" ]]; then
  echo "ERROR:no-open-pr-after-done-done"
  exit 1
fi

systemctl --user disable --now "$PRCI_TIMER" >/dev/null 2>&1 || true

prci_active_after_disable="$(timer_active "$PRCI_TIMER")"
prci_enabled_after_disable="$(timer_enabled "$PRCI_TIMER")"

if gh pr merge "$pr_number" --squash --delete-branch 2>/dev/null; then
  :
else
  pr_state_after_failure="$(gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")"
  if [[ "$pr_state_after_failure" != "MERGED" ]]; then
    systemctl --user enable --now "$PRCI_TIMER" >/dev/null 2>&1 || true
    send_telegram "⚠️ Auto-nixelo: PR #$pr_number done-done but merge failed (state=$pr_state_after_failure). Re-enabled $PRCI_TIMER."
    echo "ERROR:merge-failed state=$pr_state_after_failure"
    exit 1
  fi
fi

sleep 2

finish_post_merge_cycle "$pr_number" "$branch" "active=$prci_active_after_disable enabled=$prci_enabled_after_disable"
