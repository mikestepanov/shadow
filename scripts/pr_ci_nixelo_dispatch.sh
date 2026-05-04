#!/usr/bin/env bash
# PR-CI dispatch for Nixelo with loop detection + CI-aware routing.
set -euo pipefail

REPO_NAME="nixelo"
REPO_DIR="$HOME/Desktop/nixelo"
TMUX_SESSION="nixelo"
MAX_IDENTICAL=3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/pr_ci_dispatch_common.sh"

# ── CI failure extraction (nixelo-specific) ──────────────────────────────────

get_ci_failure_details() {
  cd "$REPO_DIR"
  local run_id
  run_id="$(gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
  [[ -z "$run_id" ]] && return 1

  local log_output
  log_output="$(gh run view "$run_id" --log-failed 2>/dev/null | tail -30 || echo "")"
  [[ -z "$log_output" ]] && return 1

  local errors
  errors="$(echo "$log_output" | grep -E '(error TS|ERROR|FAIL|✖|expect.*failed|Error:)' | head -5)"

  if [[ -n "$errors" ]]; then
    echo "CI is failing with these specific errors. Fix each one, verify locally, commit and push.

Errors:
${errors}"
  else
    echo "CI is failing. Run pnpm fixme locally, fix any errors, commit and push."
  fi
}

# ── Determine which check is failing and pick the right command ──────────────

get_smart_command() {
  cd "$REPO_DIR"
  local pr_number
  pr_number="$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number' 2>/dev/null || echo "")"
  [[ -z "$pr_number" ]] && { echo "/fix-pr-comments"; return; }

  local checks
  checks="$(gh pr checks "$pr_number" 2>/dev/null || echo "")"

  # Check which specific jobs are failing
  local failing_biome failing_e2e failing_unit failing_backend
  failing_biome="$(echo "$checks" | grep -i 'Biome' | grep -c 'fail' || true)"
  failing_e2e="$(echo "$checks" | grep -i 'E2E' | grep -c 'fail' || true)"
  failing_unit="$(echo "$checks" | grep -i 'Unit' | grep -c 'fail' || true)"
  failing_backend="$(echo "$checks" | grep -i 'Backend' | grep -c 'fail' || true)"

  if [[ "$failing_e2e" -gt 0 ]]; then
    # Get specific E2E failure details
    local run_id
    run_id="$(gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
    if [[ -n "$run_id" ]]; then
      local e2e_errors
      e2e_errors="$(gh run view "$run_id" --log-failed 2>/dev/null | grep -E '(›.*spec\.ts|expect.*failed|Error:.*element|timeout)' | head -5 || echo "")"
      if [[ -n "$e2e_errors" ]]; then
        echo "E2E tests are failing. Fix these specific failures, run the failing test locally to verify, commit and push:

${e2e_errors}"
        return
      fi
    fi
    echo "E2E tests are failing. Run pnpm playwright locally on the failing shard, identify the root cause, fix it, commit and push."
  elif [[ "$failing_biome" -gt 0 ]]; then
    echo "Biome/TypeScript check is failing. Run pnpm fixme locally, fix all errors, commit and push."
  elif [[ "$failing_unit" -gt 0 ]]; then
    echo "Unit tests are failing. Run pnpm test locally, fix the failing tests, commit and push."
  elif [[ "$failing_backend" -gt 0 ]]; then
    echo "Backend tests are failing. Run backend tests locally, fix the failures, commit and push."
  else
    prci_autonomous_research_prompt "CI is failing, but PR-CI could not classify the failing check from GitHub status output"
  fi
}

# ── CI status check ──────────────────────────────────────────────────────────

check_ci_status() {
  cd "$REPO_DIR"
  local pr_number
  pr_number="$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number' 2>/dev/null || echo "")"
  [[ -z "$pr_number" ]] && { echo "no-pr"; return; }

  local checks
  checks="$(gh pr checks "$pr_number" 2>/dev/null || echo "")"
  [[ -z "$checks" ]] && { echo "unknown"; return; }

  if echo "$checks" | grep -qE '\bfail\b'; then
    echo "failing"
  elif echo "$checks" | grep -qE '\bpending\b'; then
    echo "pending"
  else
    echo "green"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

if push_output="$(push_current_branch_if_needed)"; then
  echo "$push_output"
  exit 0
else
  push_rc=$?
  if [[ $push_rc -eq 2 ]]; then
    echo "$push_output"
    exit 1
  fi
  if [[ -n "${push_output:-}" ]]; then
    echo "$push_output"
    exit 0
  fi
fi

CI_STATUS="$(check_ci_status)"

case "$CI_STATUS" in
  green|pending)
    # Even if CI is green/pending, check for unresolved review comments
    cd "$REPO_DIR"
    pr_number="$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number' 2>/dev/null || echo "")"
    if [[ -n "$pr_number" ]]; then
      # Check for review decision
      review_decision=$(gh pr view "$pr_number" --json reviewDecision -q '.reviewDecision' 2>/dev/null || echo "NONE")
      
      unresolved_threads="$(count_unresolved_review_threads "$pr_number")"
      if [[ "$unresolved_threads" == "-1" ]]; then
        echo "NOOP:review-check-failed — could not fetch unresolved review threads"
        exit 0
      fi
      new_human_comments="$(count_new_human_review_comments "$pr_number")"
      if [[ "$new_human_comments" == "-1" ]]; then
        echo "NOOP:review-check-failed — could not fetch new human review comments"
        exit 0
      fi

      if [[ "$unresolved_threads" -gt 0 || "$new_human_comments" -gt 0 || "$review_decision" == "CHANGES_REQUESTED" ]]; then
        # There are unresolved review issues - send fix command
        dismiss_rating_prompt
        if is_terminal_idle; then
          if send_command "/fix-pr-comments"; then
            echo "OK: CI ${CI_STATUS} but review issues found (${unresolved_threads} threads, ${new_human_comments} new human comments), dispatched /fix-pr-comments$(send_result_suffix)"
          else
            echo "NOOP:send-failed — review issues found but terminal did not accept /fix-pr-comments$(send_result_suffix)"
          fi
        else
          echo "NOOP:terminal-busy — review issues found but terminal working"
        fi
        exit 0
      fi
    fi
    
    if [[ "$CI_STATUS" == "pending" ]]; then
      echo "NOOP:ci-pending — checks still running, no unresolved issues"
    else
      echo "NOOP:ci-green — all checks passing, no unresolved review issues"
    fi
    exit 0
    ;;
  no-pr)
    if is_protected_branch; then
      echo "NOOP:on-protected-branch"
      exit 0
    fi
    dismiss_rating_prompt
    if is_terminal_idle; then
      if send_command "/pr"; then
        echo "OK: no open PR, dispatched /pr$(send_result_suffix)"
      else
        echo "NOOP:send-failed — needs /pr but terminal did not accept command$(send_result_suffix)"
      fi
    else
      echo "NOOP:terminal-busy — needs /pr but terminal is working"
    fi
    exit 0
    ;;
  unknown)
    echo "NOOP:ci-unknown — could not read CI status"
    exit 0
    ;;
esac

# CI is failing — pick the right command based on which check failed
DEFAULT_CMD="$(get_smart_command)"

if check_and_dispatch "$DEFAULT_CMD"; then
  if send_command "$DISPATCH_CMD"; then
    echo "OK: dispatched to $TMUX_SESSION (CI: $CI_STATUS)$(send_result_suffix)"
  else
    echo "NOOP:send-failed — CI ${CI_STATUS}, terminal did not accept dispatch$(send_result_suffix)"
  fi
fi
