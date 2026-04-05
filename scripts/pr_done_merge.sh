#!/usr/bin/env bash
# YO — DO NOT MODIFY THIS FILE UNLESS EXPLICITLY REQUESTED BY THE USER.
# pr_done_merge.sh — Generic done-done detection + merge for any repo
# Usage: pr_done_merge.sh <repo>   (nixelo|starthub)
#
# Steps:
#   1. Check done-done gates (CI green, 0 ahead, no changes requested)
#   2. Disable PR-CI cron
#   3. Merge PR (squash + delete branch)
#   4. Checkout target branch (nixelo→main, starthub→dev)
#   5. Pull
#
# Exit codes:
#   0 = merged or nothing to do
#   1 = error
#   2 = waiting (not done-done yet)
#
# Output: single status line

set -euo pipefail

REPO="${1:-}"

if [[ -z "$REPO" ]]; then
  echo "ERROR:usage — pr_done_merge.sh <nixelo|starthub>"
  exit 1
fi

# --- Repo config ---
case "$REPO" in
  nixelo)
    REPO_DIR="$HOME/Desktop/nixelo"
    TARGET_BRANCH="main"
    PR_CI_CRON_ID="c1ac22ab-b891-4b8f-bbdb-ea9fe9d0825c"
    ;;
  starthub)
    REPO_DIR="$HOME/Desktop/StartHub"
    TARGET_BRANCH="dev"
    PR_CI_CRON_ID="4e8a1a98-a905-4f77-9373-9332f7e46e77"
    ;;
  *)
    echo "ERROR:unknown-repo ($REPO)"
    exit 1
    ;;
esac

TELEGRAM_TO="780599199"

cd "$REPO_DIR"

# --- Helpers ---

send_telegram() {
  openclaw message send --channel telegram --to "$TELEGRAM_TO" --message "$1" 2>/dev/null || true
}

# --- Check if PR-CI is enabled ---
if ! openclaw cron list --all 2>/dev/null | grep -q "pr-ci-$REPO.*ok"; then
  echo "SKIP:pr-ci-not-enabled"
  exit 0
fi

# --- Single done-done gate (all checks in one place) ---
SCRIPT_DIR_MERGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +e
gate_output=$("$SCRIPT_DIR_MERGE/is_done_done.sh" "$REPO" 2>&1)
gate_exit=$?
set -e

if [[ $gate_exit -eq 2 ]]; then
  echo "WAIT:not-done-yet ($gate_output)"
  exit 2
fi

if [[ $gate_exit -ne 0 ]]; then
  echo "$gate_output"
  exit $gate_exit
fi

# Extract PR number from gate output
branch=$(git branch --show-current)
pr_number=$(gh pr list --head "$branch" --json number -q '.[0].number' 2>/dev/null || echo "")

# --- All gates passed: MERGE ---
echo "DONE-DONE:merging $REPO PR #$pr_number"

# Disable PR-CI before merge attempt (will be restored on true failure)
openclaw cron disable "$PR_CI_CRON_ID" 2>/dev/null

# Merge
if gh pr merge "$pr_number" --squash --delete-branch 2>/dev/null; then
  send_telegram "✅ ${REPO^} PR #$pr_number merged! CI green, all comments resolved."
else
  # Fail-safe: gh can return non-zero even when merge eventually succeeds server-side.
  pr_state_after_failure=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

  if [[ "$pr_state_after_failure" == "MERGED" ]]; then
    send_telegram "✅ ${REPO^} PR #$pr_number is merged (gh merge returned non-zero, recovered by state check). Continuing lifecycle."
  else
    # True failure: restore PR-CI so automation does not stall disabled.
    openclaw cron enable "$PR_CI_CRON_ID" 2>/dev/null || true
    send_telegram "⚠️ ${REPO^} PR #$pr_number done-done but merge failed (state=$pr_state_after_failure). PR-CI re-enabled; check manually."
    echo "ERROR:merge-failed state=$pr_state_after_failure"
    exit 1
  fi
fi

sleep 2

# Checkout target branch and pull
git checkout "$TARGET_BRANCH" 2>/dev/null
git pull --ff-only 2>/dev/null

echo "MERGED:$REPO PR #$pr_number → $TARGET_BRANCH"
exit 0
