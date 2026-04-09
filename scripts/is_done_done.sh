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

# --- Gate 1: All CI checks passing (no failures, no pending) ---
failing=$(gh pr view "$pr_number" --json statusCheckRollup \
  -q '[.statusCheckRollup[]? | if .__typename=="CheckRun" then (.conclusion // .status) else (.state // .conclusion // .status) end | ascii_upcase | select(.=="FAILURE" or .=="FAILED" or .=="ERROR" or .=="TIMED_OUT" or .=="CANCELLED" or .=="ACTION_REQUIRED")] | length' 2>/dev/null || echo "999")
pending=$(gh pr view "$pr_number" --json statusCheckRollup \
  -q '[.statusCheckRollup[]? | if .__typename=="CheckRun" then (.status // .conclusion) else (.state // .status // .conclusion) end | ascii_upcase | select(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="REQUESTED" or .=="WAITING")] | length' 2>/dev/null || echo "999")

if [[ "$failing" != "0" ]]; then
  echo "NOT-READY:ci-failing (failing=$failing)"
  exit 2
fi

if [[ "$pending" != "0" ]]; then
  echo "NOT-READY:ci-pending (pending=$pending)"
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
