#!/usr/bin/env bash
# Common loop detection logic for PR-CI dispatch scripts.
# Sourced by pr_ci_nixelo_dispatch.sh and pr_ci_starthub_dispatch.sh.
#
# Required env before sourcing:
#   REPO_NAME    - "nixelo" or "starthub"
#   REPO_DIR     - absolute path to repo
#   TMUX_SESSION - tmux session name
#   MAX_IDENTICAL - max identical dispatches before escalation (default 3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/terminal_classifier.sh"
source "$SCRIPT_DIR/terminal_mode_guard.sh"

OPENCODECTL="$HOME/Desktop/shadow/scripts/opencodectl"

STATE_FILE="$HOME/Desktop/shadow/heartbeat-dispatch-state.json"
MAX_IDENTICAL="${MAX_IDENTICAL:-3}"
GH="$(command -v gh)"

# ── helpers ──────────────────────────────────────────────────────────────────

json_get() {
  # json_get <file> <repo> <field>
  # Minimal jq-free JSON field extraction (single depth under repo key).
  local file="$1" repo="$2" field="$3"
  # Use node since it's always available
  node -e "
    const fs = require('fs');
    try {
      const d = JSON.parse(fs.readFileSync('$file','utf8'));
      console.log(d['$repo']?.['$field'] ?? '');
    } catch { console.log(''); }
  "
}

json_set() {
  # json_set <file> <repo> <field> <value>
  local file="$1" repo="$2" field="$3" value="$4"
  node -e "
    const fs = require('fs');
    let d = {};
    try { d = JSON.parse(fs.readFileSync(process.argv[1],'utf8')); } catch {}
    if (!d[process.argv[2]]) d[process.argv[2]] = {};
    d[process.argv[2]][process.argv[3]] = process.argv[4];
    fs.writeFileSync(process.argv[1], JSON.stringify(d, null, 2) + '\n');
  " "$file" "$repo" "$field" "$value"
}

json_set_num() {
  local file="$1" repo="$2" field="$3" value="$4"
  node -e "
    const fs = require('fs');
    let d = {};
    try { d = JSON.parse(fs.readFileSync(process.argv[1],'utf8')); } catch {}
    if (!d[process.argv[2]]) d[process.argv[2]] = {};
    d[process.argv[2]][process.argv[3]] = Number(process.argv[4]);
    fs.writeFileSync(process.argv[1], JSON.stringify(d, null, 2) + '\n');
  " "$file" "$repo" "$field" "$value"
}

ensure_state_file() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
  fi
}

# Protected branches that should never get /pr dispatched
PROTECTED_BRANCHES="main dev master"

is_protected_branch() {
  local current_branch
  current_branch="$(cd "$REPO_DIR" && git branch --show-current 2>/dev/null || echo "")"
  for b in $PROTECTED_BRANCHES; do
    [[ "$current_branch" == "$b" ]] && return 0
  done
  return 1
}

get_current_hash() {
  cd "$REPO_DIR" && git log -1 --format="%h" 2>/dev/null || echo "unknown"
}

get_ahead_count() {
  cd "$REPO_DIR"
  local branch
  branch="$(git branch --show-current 2>/dev/null || echo "")"
  [[ -n "$branch" ]] || {
    echo "unknown"
    return 0
  }

  git rev-list --count "origin/${branch}..${branch}" 2>/dev/null || echo "unknown"
}

push_current_branch_if_needed() {
  cd "$REPO_DIR"
  local branch ahead
  branch="$(git branch --show-current 2>/dev/null || echo "")"
  [[ -n "$branch" ]] || {
    echo "NOOP:push-state-unknown — could not determine current branch"
    return 1
  }

  ahead="$(git rev-list --count "origin/${branch}..${branch}" 2>/dev/null || echo "unknown")"
  if [[ "$ahead" == "unknown" ]]; then
    echo "NOOP:push-state-unknown — could not determine whether branch is ahead"
    return 1
  fi

  if [[ "$ahead" == "0" ]]; then
    return 1
  fi

  if git push origin "$branch" >/dev/null 2>&1; then
    echo "PUSHED:branch=${branch} ahead=${ahead}"
    return 0
  fi

  echo "ERROR:push-failed branch=${branch} ahead=${ahead}"
  return 2
}

get_pane_text() {
  tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | tail -20
}

get_pane_target() {
  tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -n1
}

dismiss_rating_prompt() {
  local pane_text
  local pane_target
  pane_text="$(get_pane_text)"
  pane_target="$(get_pane_target)"
  if echo "$pane_text" | grep -q "How is Claude doing"; then
    [[ -n "$pane_target" ]] || return 0
    send_tmux_text_enter "$pane_target" "0"
    sleep 2
  fi
}

is_terminal_idle() {
  local state
  state="$(classify_terminal_for_send "$TMUX_SESSION")"
  [[ "$state" == IDLE:* ]]
}

send_command() {
  local cmd="$1"
  local pane_target pane_text
  pane_target="$(get_pane_target)"
  [[ -n "$pane_target" ]] || return 1

  pane_text="$(get_pane_text)"
  if printf '%s\n' "$pane_text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -Fqx -- "$cmd"; then
    submit_tmux_enter "$pane_target"
    return 0
  fi

  send_tmux_text_enter "$pane_target" "$cmd"
}

alert_telegram() {
  local msg="$1"
  local token="${TELEGRAM_BOT_TOKEN:-}"
  [[ -n "$token" ]] || return 0

  curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=780599199" \
    --data-urlencode "text=${msg}" \
    >/dev/null 2>&1 || true
}

get_repo_slug() {
  cd "$REPO_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo ""
}

count_unresolved_review_threads() {
  local pr_number="$1"
  local repo_slug owner repo

  repo_slug="$(get_repo_slug)"
  [[ -n "$repo_slug" ]] || {
    echo "0"
    return 0
  }

  owner="${repo_slug%%/*}"
  repo="${repo_slug#*/}"

  gh api graphql \
    -f owner="$owner" \
    -f repo="$repo" \
    -F number="$pr_number" \
    -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved } } } } }' \
    --jq '[(.data.repository.pullRequest.reviewThreads.nodes // [])[] | select(.isResolved == false)] | length' \
    2>/dev/null || echo "0"
}

count_new_human_review_comments() {
  local pr_number="$1"
  local last_commit_date

  cd "$REPO_DIR"
  last_commit_date="$(git log -1 --format=%cI 2>/dev/null || echo "")"
  [[ -n "$last_commit_date" ]] || {
    echo "0"
    return 0
  }

  gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
    --jq "[.[] | select(.created_at > \"${last_commit_date}\") | select(.user.type == \"User\")] | length" \
    2>/dev/null || echo "0"
}

# ── done-done detection ──────────────────────────────────────────────────────

# Check if PR is fully done: CI green + ahead=0 + no unresolved bot comments needing fixes.
# If done, disable the cron job and notify via Telegram.
# Args: $1 = cron job ID, $2 = PR number
# Returns 0 if done (caller should exit), 1 if not done.
check_done_done() {
  local cron_id="$1" pr_number="$2"

  # 1. Check unpushed commits
  cd "$REPO_DIR"
  local branch
  branch="$(git branch --show-current)"
  local ahead
  ahead="$(git rev-list --count "origin/${branch}..${branch}" 2>/dev/null || echo "unknown")"
  if [[ "$ahead" != "0" ]]; then
    # There are unpushed commits — push them first
    echo "PUSH: ${ahead} unpushed commits on ${branch}"
    git push origin "$branch" 2>/dev/null || true
    echo "NOOP:pushed-commits — wait for CI to re-run"
    return 1
  fi

  # 2. Check for unresolved review comments (bot or human)
  local comments_needing_work
  comments_needing_work="$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
    --jq '[.[] | select(.path != null)] | length' 2>/dev/null || echo "0")"

  # Check if there are any HUMAN review comments posted after the last commit.
  # Bot comments (CodeRabbit, Copilot, codex-connector, etc.) are excluded —
  # they always appear after pushes and would create an infinite loop.
  local last_commit_date
  last_commit_date="$(git log -1 --format=%cI 2>/dev/null || echo "")"
  local unaddressed_comments="0"
  if [[ -n "$last_commit_date" ]]; then
    unaddressed_comments="$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
      --jq "[.[] | select(.created_at > \"${last_commit_date}\") | select(.user.type != \"Bot\") | select(.user.login != \"Copilot\")] | length" 2>/dev/null || echo "0")"
  fi

  if [[ "$unaddressed_comments" -gt 0 ]]; then
    # There are human review comments posted after our last commit — need to address them
    return 1
  fi

  # 3. All done — disable cron and notify
  "$OPENCODECTL" cron disable "$cron_id" 2>/dev/null || true
  alert_telegram "✅ ${REPO_NAME} PR #${pr_number} is done-done! All CI green, no unpushed commits, no unaddressed comments. PR-CI cron disabled. Ready for human review/merge."
  echo "DONE: PR #${pr_number} is complete — cron disabled, Telegram notified"
  return 0
}

# ── main loop detection logic ────────────────────────────────────────────────

# Returns:
#   0 = dispatch allowed (command in $DISPATCH_CMD)
#   1 = dispatch blocked (loop detected, already escalated)
check_and_dispatch() {
  local default_cmd="$1"

  ensure_state_file

  local current_hash
  current_hash="$(get_current_hash)"

  local last_hash last_cmd loop_count
  last_hash="$(json_get "$STATE_FILE" "$REPO_NAME" "last_commit_hash")"
  last_cmd="$(json_get "$STATE_FILE" "$REPO_NAME" "last_dispatch_command")"
  loop_count="$(json_get "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count")"
  loop_count="${loop_count:-0}"

  # Dismiss rating prompts before anything
  dismiss_rating_prompt

  # Check if terminal is idle
  if ! is_terminal_idle; then
    echo "NOOP:terminal-busy"
    return 1
  fi

  # New commit = progress! Reset loop counter.
  if [[ "$current_hash" != "$last_hash" ]]; then
    json_set "$STATE_FILE" "$REPO_NAME" "last_commit_hash" "$current_hash"
    json_set_num "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count" 0
    json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_command" "$default_cmd"
    json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    DISPATCH_CMD="$default_cmd"
    return 0
  fi

  # Same hash — check if we're looping
  loop_count=$((loop_count + 1))

  if [[ "$loop_count" -ge "$MAX_IDENTICAL" ]]; then
    # STALLED:loop — escalate with CI log intelligence
    echo "STALLED:loop (${loop_count} identical dispatches, no new commit)"

    # Try to get specific CI failure info
    local ci_failure_info
    ci_failure_info="$(get_ci_failure_details 2>/dev/null || echo "")"

    if [[ -n "$ci_failure_info" ]]; then
      # Craft specific instruction from CI logs
      local specific_cmd="$ci_failure_info"
      json_set_num "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count" 0
      json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_command" "specific-ci-fix"
      json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      DISPATCH_CMD="$specific_cmd"
      return 0
    else
      # Can't get CI details — alert human
      local doubled=$((MAX_IDENTICAL * 2))
      if [[ "$loop_count" -ge "$doubled" ]]; then
        alert_telegram "🚨 ${REPO_NAME} PR-CI stuck: ${loop_count} dispatches with no progress. Last hash: ${current_hash}. Needs human intervention."
        echo "BLOCKED:alerted-human"
        # Don't reset counter — keep blocking until commit appears
        json_set_num "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count" "$loop_count"
        return 1
      fi
      # First escalation round — try default one more time
      json_set_num "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count" "$loop_count"
      DISPATCH_CMD="$default_cmd"
      return 0
    fi
  fi

  # Under threshold — normal dispatch
  json_set_num "$STATE_FILE" "$REPO_NAME" "identical_dispatch_count" "$loop_count"
  json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_command" "$default_cmd"
  json_set "$STATE_FILE" "$REPO_NAME" "last_dispatch_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DISPATCH_CMD="$default_cmd"
  return 0
}
