#!/usr/bin/env bash
# PR-CI dispatch for StartHub with loop detection + CI-aware routing.
set -euo pipefail

REPO_NAME="starthub"
REPO_DIR="$HOME/Desktop/StartHub"
TMUX_SESSION="starthub"
MAX_IDENTICAL=3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/pr_ci_dispatch_common.sh"

# ── CI failure extraction (starthub-specific) ────────────────────────────────

get_ci_failure_details() {
  cd "$REPO_DIR"
  local run_id
  run_id="$(gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
  [[ -z "$run_id" ]] && return 1

  local log_output
  log_output="$(gh run view "$run_id" --log-failed 2>/dev/null | tail -40 || echo "")"
  [[ -z "$log_output" ]] && return 1

  local errors
  errors="$(echo "$log_output" | grep -E '(FAIL|Error|error|violations|❌|✖|expect.*failed)' | head -8)"

  if [[ -n "$errors" ]]; then
    local failed_checks
    failed_checks="$(gh pr checks "$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number')" 2>/dev/null | grep -E '\bfail\b' | awk '{print $1}' | head -5 || echo "unknown")"
    echo "CI is failing. Fix these specific errors, verify locally, commit and push.

Failed checks: ${failed_checks}

Errors:
${errors}"
  else
    echo "CI is failing. Run the failing tests locally, fix root causes, commit and push."
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

  local failing_arch failing_e2e failing_unit failing_biome failing_playwright
  failing_arch="$(echo "$checks" | grep -i 'Architecture' | grep -c 'fail' || true)"
  failing_e2e="$(echo "$checks" | grep -i 'Backend E2E' | grep -c 'fail' || true)"
  failing_unit="$(echo "$checks" | grep -i 'Unit' | grep -c 'fail' || true)"
  failing_biome="$(echo "$checks" | grep -i 'Biome\|TypeScript' | grep -c 'fail' || true)"
  failing_playwright="$(echo "$checks" | grep -i 'Playwright E2E' | grep -c 'fail' || true)"

  # Build a combined instruction for all failures
  local cmd_parts=()

  if [[ "$failing_arch" -gt 0 ]]; then
    cmd_parts+=("Backend Architecture Validation is failing (MongoDB/GraphQL violations). Run 'pnpm --filter @app/backend test:architecture' locally to see details and fix them.")
  fi
  if [[ "$failing_e2e" -gt 0 ]]; then
    # Get specific failure
    local run_id
    run_id="$(gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")"
    if [[ -n "$run_id" ]]; then
      local e2e_errors
      e2e_errors="$(gh run view "$run_id" --log-failed 2>/dev/null | grep -E '(FAIL|expect.*failed|Error:)' | head -3 || echo "")"
      if [[ -n "$e2e_errors" ]]; then
        cmd_parts+=("Backend E2E tests failing: ${e2e_errors}")
      else
        cmd_parts+=("Backend E2E tests are failing. Run 'pnpm --filter @app/backend test:e2e' locally, fix root cause.")
      fi
    fi
  fi
  if [[ "$failing_biome" -gt 0 ]]; then
    cmd_parts+=("Biome/TypeScript check failing. Run pnpm fixme locally and fix all errors.")
  fi
  if [[ "$failing_unit" -gt 0 ]]; then
    cmd_parts+=("Unit tests failing. Run tests locally and fix.")
  fi
  if [[ "$failing_playwright" -gt 0 ]]; then
    cmd_parts+=("Playwright E2E tests failing. Run locally and fix.")
  fi

  if [[ ${#cmd_parts[@]} -gt 0 ]]; then
    local joined
    joined="$(printf '%s ' "${cmd_parts[@]}")"
    echo "${joined}Commit and push when fixed."
  else
    echo "/fix-pr-comments"
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

CI_STATUS="$(check_ci_status)"

case "$CI_STATUS" in
  green|pending)
    # Even if CI is green/pending, check for unresolved review comments.
    cd "$REPO_DIR"
    pr_number="$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number' 2>/dev/null || echo "")"
    if [[ -n "$pr_number" ]]; then
      review_decision=$(gh pr view "$pr_number" --json reviewDecision -q '.reviewDecision' 2>/dev/null || echo "NONE")

      unresolved_threads="$(count_unresolved_review_threads "$pr_number")"
      unresolved_threads=${unresolved_threads:-0}
      new_human_comments="$(count_new_human_review_comments "$pr_number")"
      new_human_comments=${new_human_comments:-0}

      if [[ "$unresolved_threads" -gt 0 || "$new_human_comments" -gt 0 || "$review_decision" == "CHANGES_REQUESTED" ]]; then
        dismiss_rating_prompt
        if is_terminal_idle; then
          send_command "/fix-pr-comments"
          echo "OK: CI ${CI_STATUS} but review issues found (${unresolved_threads} threads, ${new_human_comments} new human comments), dispatched /fix-pr-comments"
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
      send_command "/pr"
      echo "OK: no open PR, dispatched /pr"
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

DEFAULT_CMD="$(get_smart_command)"

if check_and_dispatch "$DEFAULT_CMD"; then
  send_command "$DISPATCH_CMD"
  echo "OK: dispatched to $TMUX_SESSION (CI: $CI_STATUS)"
fi
