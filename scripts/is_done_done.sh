#!/usr/bin/env bash
# is_done_done.sh — Single source of truth for PR merge-readiness.
# Used by: pr_done_merge.sh, pr_ci_*_dispatch.sh, heartbeat
#
# Usage: is_done_done.sh <nixelo|starthub>
#
# Exit codes:
#   0 = done-done (safe to merge)
#   2 = not ready (reason printed to stdout)
#   1 = error

set -euo pipefail

REPO="${1:-}"

if [[ -z "$REPO" ]]; then
  echo "ERROR:usage — is_done_done.sh <nixelo|starthub>"
  exit 1
fi

case "$REPO" in
  nixelo)
    REPO_DIR="$HOME/Desktop/nixelo"
    TARGET_BRANCH="dev"
    OWNER="NixeloApp"
    REPO_NAME="nixelo"
    ;;
  starthub)
    REPO_DIR="$HOME/Desktop/StartHub"
    TARGET_BRANCH="dev"
    OWNER="StartHub-Academy"
    REPO_NAME="StartHub"
    ;;
  *)
    echo "ERROR:unknown-repo ($REPO)"
    exit 1
    ;;
esac

cd "$REPO_DIR"

count_pr_rollup() {
  local pr_number="$1"
  local kind="$2"
  local query=""

  case "$kind" in
    failing)
      query='[.statusCheckRollup[]? | if .__typename=="CheckRun" then (.conclusion // .status) else (.state // .conclusion // .status) end | ascii_upcase | select(.=="FAILURE" or .=="FAILED" or .=="ERROR" or .=="TIMED_OUT" or .=="CANCELLED" or .=="ACTION_REQUIRED")] | length'
      ;;
    pending)
      query='[.statusCheckRollup[]? | if .__typename=="CheckRun" then (.status // .conclusion) else (.state // .status // .conclusion) end | ascii_upcase | select(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="REQUESTED" or .=="WAITING")] | length'
      ;;
    *)
      echo "ERR"
      return 0
      ;;
  esac

  gh pr view "$pr_number" --json statusCheckRollup -q "$query" 2>/dev/null || echo "ERR"
}

count_commit_check_suites() {
  local head_sha="$1"
  local kind="$2"
  local query=""

  case "$kind" in
    failing)
      query='[.check_suites[]? | (.conclusion // "") | ascii_upcase | select(.=="FAILURE" or .=="FAILED" or .=="ERROR" or .=="TIMED_OUT" or .=="CANCELLED" or .=="ACTION_REQUIRED" or .=="STALE" or .=="STARTUP_FAILURE")] | length'
      ;;
    pending)
      query='[.check_suites[]? | (.status // "") | ascii_upcase | select(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="REQUESTED" or .=="WAITING")] | length'
      ;;
    *)
      echo "ERR"
      return 0
      ;;
  esac

  gh api "repos/${OWNER}/${REPO_NAME}/commits/${head_sha}/check-suites?per_page=100" --jq "$query" 2>/dev/null || echo "ERR"
}

count_commit_status_contexts() {
  local head_sha="$1"
  local kind="$2"
  local query=""

  case "$kind" in
    failing)
      query='[.statuses[]? | (.state // "") | ascii_upcase | select(.=="FAILURE" or .=="FAILED" or .=="ERROR")] | length'
      ;;
    pending)
      query='[.statuses[]? | (.state // "") | ascii_upcase | select(.=="PENDING")] | length'
      ;;
    *)
      echo "ERR"
      return 0
      ;;
  esac

  gh api "repos/${OWNER}/${REPO_NAME}/commits/${head_sha}/status" --jq "$query" 2>/dev/null || echo "ERR"
}

# --- Find open PR on current branch ---
branch=$(git branch --show-current)

if [[ "$branch" == "$TARGET_BRANCH" ]]; then
  echo "SKIP:already-on-target-branch"
  exit 2
fi

pr_number=$(gh pr list --head "$branch" --json number -q '.[0].number' 2>/dev/null || echo "")

if [[ -z "$pr_number" ]]; then
  echo "SKIP:no-open-pr"
  exit 2
fi

pr_head_sha=$(gh pr view "$pr_number" --json headRefOid -q '.headRefOid' 2>/dev/null || echo "")
if [[ -z "$pr_head_sha" ]]; then
  echo "NOT-READY:cannot-read-pr-head-sha"
  exit 2
fi

# --- Gate 1: All CI checks passing (no failures, no pending) ---
failing=$(count_pr_rollup "$pr_number" failing)
pending=$(count_pr_rollup "$pr_number" pending)

if [[ "$failing" == "ERR" || "$pending" == "ERR" ]]; then
  echo "NOT-READY:cannot-check-pr-rollup"
  exit 2
fi

if [[ "$failing" != "0" ]]; then
  echo "NOT-READY:ci-failing (failing=$failing)"
  exit 2
fi

if [[ "$pending" != "0" ]]; then
  echo "NOT-READY:ci-pending (pending=$pending)"
  exit 2
fi

# --- Gate 1b: Commit-level check suites on the head SHA must also be finished ---
# statusCheckRollup can lag or omit newly queued suites for the current head commit.
suite_failing=$(count_commit_check_suites "$pr_head_sha" failing)
suite_pending=$(count_commit_check_suites "$pr_head_sha" pending)

if [[ "$suite_failing" == "ERR" || "$suite_pending" == "ERR" ]]; then
  echo "NOT-READY:cannot-check-commit-check-suites"
  exit 2
fi

if [[ "$suite_failing" != "0" ]]; then
  echo "NOT-READY:commit-check-suites-failing (failing=$suite_failing)"
  exit 2
fi

if [[ "$suite_pending" != "0" ]]; then
  echo "NOT-READY:commit-check-suites-pending (pending=$suite_pending)"
  exit 2
fi

# --- Gate 1c: Commit status contexts on the head SHA must also be settled ---
status_failing=$(count_commit_status_contexts "$pr_head_sha" failing)
status_pending=$(count_commit_status_contexts "$pr_head_sha" pending)

if [[ "$status_failing" == "ERR" || "$status_pending" == "ERR" ]]; then
  echo "NOT-READY:cannot-check-commit-status-contexts"
  exit 2
fi

if [[ "$status_failing" != "0" ]]; then
  echo "NOT-READY:commit-status-contexts-failing (failing=$status_failing)"
  exit 2
fi

if [[ "$status_pending" != "0" ]]; then
  echo "NOT-READY:commit-status-contexts-pending (pending=$status_pending)"
  exit 2
fi

# --- Gate 2: No unpushed commits ---
ahead=$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "999")
if [[ "$ahead" != "0" ]]; then
  echo "NOT-READY:unpushed-commits (ahead=$ahead)"
  exit 2
fi

# --- Gate 3: No CHANGES_REQUESTED reviews ---
changes_requested=$(gh pr view "$pr_number" --json reviews \
  -q '[.reviews[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo "0")
if [[ "$changes_requested" != "0" ]]; then
  echo "NOT-READY:changes-requested (count=$changes_requested)"
  exit 2
fi

# --- Gate 4: No unresolved review threads (GraphQL — covers threaded conversations) ---
unresolved_threads=$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved}}}}}' \
  -F owner="$OWNER" -F name="$REPO_NAME" -F n="$pr_number" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes | [ .[] | select(.isResolved==false) ] | length' 2>/dev/null || echo "ERR")

if [[ "$unresolved_threads" == "ERR" ]]; then
  echo "NOT-READY:cannot-check-review-threads (gh api error)"
  exit 2
fi

if [[ "$unresolved_threads" != "0" ]]; then
  echo "NOT-READY:unresolved-review-threads (count=$unresolved_threads)"
  exit 2
fi

echo "DONE-DONE:pr=$pr_number branch=$branch"
exit 0
