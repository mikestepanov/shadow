#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_ORIG="$PATH"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
TMP_DIRS=()

cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}

trap cleanup EXIT

record_tmpdir() {
  TMP_DIRS+=("$1")
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'OK   %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ASSERT FAIL %s\nmissing: %s\noutput:\n%s\n' "$label" "$needle" "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ASSERT FAIL %s\nunexpected: %s\noutput:\n%s\n' "$label" "$needle" "$haystack" >&2
    return 1
  fi
}

assert_status() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'ASSERT FAIL %s\nexpected status=%s actual=%s\noutput:\n%s\n' "$label" "$expected" "$actual" "$RUN_OUTPUT" >&2
    return 1
  fi
}

run_cmd() {
  local output_file status
  output_file="$(mktemp)"
  set +e
  "$@" > "$output_file" 2>&1
  status=$?
  set -e
  RUN_OUTPUT="$(cat "$output_file")"
  rm -f "$output_file"
  RUN_STATUS="$status"
}

key_of() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

set_unit_state() {
  local kind="$1"
  local unit="$2"
  local value="$3"
  printf '%s\n' "$value" > "$FAKE_STATE_DIR/${kind}_$(key_of "$unit")"
}

set_journal_output() {
  local unit="$1"
  local value="$2"
  printf '%s\n' "$value" > "$FAKE_STATE_DIR/journal_$(key_of "$unit")"
}

set_git_branch() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/git_branch"
}

set_git_status() {
  printf '%s' "$1" > "$FAKE_STATE_DIR/git_status"
}

write_stub_systemctl() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_LOG:?}"
state_dir="${FAKE_STATE_DIR:?}"

key_of() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

read_state() {
  local kind="$1"
  local unit="$2"
  local default_value="$3"
  local file="$state_dir/${kind}_$(key_of "$unit")"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf '%s\n' "$default_value"
  fi
}

write_state() {
  local kind="$1"
  local unit="$2"
  local value="$3"
  printf '%s\n' "$value" > "$state_dir/${kind}_$(key_of "$unit")"
}

printf 'systemctl %s\n' "$*" >> "$log_file"

args=("$@")
if [[ ${args[0]:-} == "--user" ]]; then
  args=("${args[@]:1}")
fi

if [[ ${args[0]:-} == "--failed" ]]; then
  exit 0
fi

command_name="${args[0]:-}"
case "$command_name" in
  is-active)
    read_state active "${args[1]}" inactive
    ;;
  is-enabled)
    read_state enabled "${args[1]}" disabled
    ;;
  start)
    write_state active "${args[1]}" active
    ;;
  stop)
    write_state active "${args[1]}" inactive
    ;;
  enable)
    if [[ ${args[1]:-} == "--now" ]]; then
      write_state enabled "${args[2]}" enabled
      write_state active "${args[2]}" active
    else
      write_state enabled "${args[1]}" enabled
    fi
    ;;
  disable)
    if [[ ${args[1]:-} == "--now" ]]; then
      write_state enabled "${args[2]}" disabled
      write_state active "${args[2]}" inactive
    else
      write_state enabled "${args[1]}" disabled
    fi
    ;;
  mask)
    write_state enabled "${args[1]}" masked
    write_state active "${args[1]}" inactive
    ;;
  unmask)
    if [[ $(read_state enabled "${args[1]}" disabled) == masked ]]; then
      write_state enabled "${args[1]}" disabled
    fi
    ;;
  daemon-reload|reset-failed)
    ;;
  show)
    unit="${args[1]}"
    printf 'LoadState=loaded\nUnitFileState=%s\nFragmentPath=/tmp/%s\n' "$(read_state enabled "$unit" disabled)" "$unit"
    ;;
  *)
    ;;
esac
EOF
  chmod +x "$path"
}

write_stub_journalctl() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_STATE_DIR:?}"

key_of() {
  printf '%s' "$1" | tr -c '[:alnum:]' '_'
}

unit=""
while (($#)); do
  case "$1" in
    -u)
      unit="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$unit" ]]; then
  exit 0
fi

file="$state_dir/journal_$(key_of "$unit")"
if [[ -f "$file" ]]; then
  cat "$file"
fi
EOF
  chmod +x "$path"
}

write_stub_tmux() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_LOG:?}"
state_dir="${FAKE_STATE_DIR:?}"

printf 'tmux %s\n' "$*" >> "$log_file"

command_name="${1:-}"
case "$command_name" in
  has-session)
    session="${3:-}"
    session_file="$state_dir/tmux_session_${session}"
    if [[ -f "$session_file" ]] && [[ $(cat "$session_file") == present ]]; then
      exit 0
    fi
    exit 1
    ;;
  clear-history)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$path"
}

write_stub_gh() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_LOG:?}"
printf 'gh %s\n' "$*" >> "$log_file"

if [[ ${1:-} == pr && ${2:-} == list ]]; then
  state="open"
  while (($#)); do
    if [[ $1 == --state ]]; then
      state="$2"
      break
    fi
    shift
  done
  case "$state" in
    open)
      printf '%s' "${FAKE_GH_OPEN_PR:-}"
      ;;
    merged)
      printf '%s' "${FAKE_GH_MERGED_PR:-}"
      ;;
  esac
  exit 0
fi

if [[ ${1:-} == pr && ${2:-} == merge ]]; then
  exit "${FAKE_GH_MERGE_EXIT:-0}"
fi

if [[ ${1:-} == pr && ${2:-} == view ]]; then
  printf '%s\n' "${FAKE_GH_PR_STATE:-MERGED}"
  exit 0
fi

exit 0
EOF
  chmod +x "$path"
}

write_stub_git() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_LOG:?}"
state_dir="${FAKE_STATE_DIR:?}"

printf 'git %s\n' "$*" >> "$log_file"

read_branch() {
  cat "$state_dir/git_branch"
}

write_branch() {
  printf '%s\n' "$1" > "$state_dir/git_branch"
}

case "${1:-}" in
  branch)
    if [[ ${2:-} == --show-current ]]; then
      read_branch
      exit 0
    fi
    ;;
  status)
    if [[ ${2:-} == --porcelain ]]; then
      if [[ -f "$state_dir/git_status" ]]; then
        cat "$state_dir/git_status"
      fi
      exit 0
    fi
    ;;
  show-ref)
    if [[ -f "$state_dir/git_show_ref_exists" ]]; then
      exit 0
    fi
    exit 1
    ;;
  checkout)
    if [[ ${2:-} == -b ]]; then
      write_branch "${3:-}"
      exit 0
    fi
    write_branch "${2:-}"
    exit 0
    ;;
  pull)
    exit 0
    ;;
esac

exit 0
EOF
  chmod +x "$path"
}

write_stub_date() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  '+%Y-%m-%d-%H-%M')
    printf '%s\n' "${FAKE_DATE_BRANCH:-2026-04-21-01-12}"
    ;;
  '+%Y-%m-%d %H:%M:%S')
    printf '%s\n' "${FAKE_DATE_SINCE:-2026-04-21 01:08:00}"
    ;;
  *)
    "${REAL_DATE_BIN:?}" "$@"
    ;;
esac
EOF
  chmod +x "$path"
}

write_stub_sleep() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$path"
}

write_stub_curl() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$path"
}

write_fake_opencodectl() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == cron && ${2:-} == list && ${3:-} == --all && ${4:-} == --json ]]; then
  cat <<'JSON'
[
  {"name":"pr-ci-nixelo","id":"fake-prci-nixelo","enabled":false,"state":{"lastStatus":"disabled"}},
  {"name":"pr-ci-starthub","id":"fake-prci-starthub","enabled":false,"state":{"lastStatus":"disabled"}}
]
JSON
  exit 0
fi

exit 0
EOF
  chmod +x "$path"
}

write_fake_terminal_mode_guard() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TERMINAL_PREFLIGHT_PANE=""
TERMINAL_PREFLIGHT_STATE=""
TERMINAL_PREFLIGHT_REASON=""
TERMINAL_PREFLIGHT_CURRENT_PATH=""
TERMINAL_PREFLIGHT_EXPECTED_PATH=""

terminal_send_preflight() {
  local session="$1"
  local expected_path="$2"
  TERMINAL_PREFLIGHT_PANE="%1"
  TERMINAL_PREFLIGHT_CURRENT_PATH="$expected_path"
  TERMINAL_PREFLIGHT_EXPECTED_PATH="$expected_path"

  case "${FAKE_PREFLIGHT_RESULT:-ok}" in
    ok)
      TERMINAL_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}"
      TERMINAL_PREFLIGHT_REASON="ok"
      return 0
      ;;
    busy)
      TERMINAL_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-BUSY:content-changing}"
      TERMINAL_PREFLIGHT_REASON="terminal-not-ready"
      return 1
      ;;
    stuck)
      TERMINAL_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-STUCK:no-prompt}"
      TERMINAL_PREFLIGHT_REASON="terminal-not-ready"
      return 1
      ;;
    session-missing)
      TERMINAL_PREFLIGHT_REASON="session-missing"
      return 1
      ;;
    path-mismatch)
      TERMINAL_PREFLIGHT_REASON="path-mismatch"
      TERMINAL_PREFLIGHT_CURRENT_PATH="/wrong/path"
      return 1
      ;;
  esac

  printf 'unknown fake preflight result\n' >&2
  return 1
}

send_tmux_text_enter() {
  return 0
}

submit_tmux_enter() {
  return 0
}
EOF
  chmod +x "$path"
}

write_fake_timers_install() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'timers-install %s\n' "$*" >> "${FAKE_LOG:?}"
exit 0
EOF
  chmod +x "$path"
}

write_fake_is_done_done() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_DONE_DONE_RESULT:-done}" in
  done)
    printf '%s\n' "${FAKE_DONE_DONE_OUTPUT:-DONE-DONE:pr=${FAKE_GH_OPEN_PR:-50} branch=fixes}"
    exit 0
    ;;
  wait)
    printf '%s\n' "${FAKE_DONE_DONE_OUTPUT:-NOT-READY:ci-failing (failing=1)}"
    exit 2
    ;;
  error)
    printf '%s\n' "${FAKE_DONE_DONE_OUTPUT:-ERROR:boom}"
    exit 1
    ;;
esac

printf 'invalid fake done-done result\n' >&2
exit 1
EOF
  chmod +x "$path"
}

setup_fake_env() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  record_tmpdir "$tmp_dir"

  export TEST_TMP_DIR="$tmp_dir"
  export HOME="$tmp_dir/home"
  export FAKE_STATE_DIR="$tmp_dir/state"
  export FAKE_LOG="$tmp_dir/commands.log"
  export REAL_DATE_BIN="$(PATH="$PATH_ORIG" command -v date)"
  export PATH="$tmp_dir/bin:$PATH_ORIG"

  mkdir -p "$HOME/Desktop/nixelo" "$HOME/Desktop/shadow" "$HOME/.openclaw/workspace/.terminal-automation-plans" "$tmp_dir/bin" "$FAKE_STATE_DIR"
  : > "$FAKE_LOG"

  printf '{"enabled": true}\n' > "$HOME/Desktop/shadow/auto-nixelo-enabled.json"
  printf 'fixes\n' > "$FAKE_STATE_DIR/git_branch"
  : > "$FAKE_STATE_DIR/git_status"
  printf 'present\n' > "$FAKE_STATE_DIR/tmux_session_nixelo"

  write_stub_systemctl "$tmp_dir/bin/systemctl"
  write_stub_journalctl "$tmp_dir/bin/journalctl"
  write_stub_tmux "$tmp_dir/bin/tmux"
  write_stub_gh "$tmp_dir/bin/gh"
  write_stub_git "$tmp_dir/bin/git"
  write_stub_date "$tmp_dir/bin/date"
  write_stub_sleep "$tmp_dir/bin/sleep"
  write_stub_curl "$tmp_dir/bin/curl"

  export TEST_FAKE_OPENCODECTL="$tmp_dir/fake-opencodectl"
  export TEST_FAKE_TERMINAL_MODE_GUARD="$tmp_dir/fake-terminal-mode-guard.sh"
  export TEST_FAKE_TIMERS_INSTALL="$tmp_dir/fake-timers-install"
  export TEST_FAKE_IS_DONE_DONE="$tmp_dir/fake-is-done-done.sh"

  write_fake_opencodectl "$TEST_FAKE_OPENCODECTL"
  write_fake_terminal_mode_guard "$TEST_FAKE_TERMINAL_MODE_GUARD"
  write_fake_timers_install "$TEST_FAKE_TIMERS_INSTALL"
  write_fake_is_done_done "$TEST_FAKE_IS_DONE_DONE"

  unset FAKE_GH_OPEN_PR FAKE_GH_MERGED_PR FAKE_GH_MERGE_EXIT FAKE_GH_PR_STATE FAKE_DONE_DONE_RESULT FAKE_DONE_DONE_OUTPUT FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE FAKE_DATE_BRANCH FAKE_DATE_SINCE
}

run_terminal_automation() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$TEST_FAKE_TERMINAL_MODE_GUARD" \
    TIMERS_INSTALL="$TEST_FAKE_TIMERS_INSTALL" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    bash "$ROOT_DIR/scripts/terminal-automation" "$@"
}

run_auto_cycle() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    TIMERS_INSTALL="$TEST_FAKE_TIMERS_INSTALL" \
    IS_DONE_DONE_SCRIPT="$TEST_FAKE_IS_DONE_DONE" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_GH_OPEN_PR="${FAKE_GH_OPEN_PR:-}" \
    FAKE_GH_MERGED_PR="${FAKE_GH_MERGED_PR:-}" \
    FAKE_GH_MERGE_EXIT="${FAKE_GH_MERGE_EXIT:-0}" \
    FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-MERGED}" \
    FAKE_DONE_DONE_RESULT="${FAKE_DONE_DONE_RESULT:-done}" \
    FAKE_DONE_DONE_OUTPUT="${FAKE_DONE_DONE_OUTPUT:-DONE-DONE:pr=${FAKE_GH_OPEN_PR:-50} branch=fixes}" \
    FAKE_DATE_BRANCH="${FAKE_DATE_BRANCH:-2026-04-21-01-12}" \
    FAKE_DATE_SINCE="${FAKE_DATE_SINCE:-2026-04-21 01:08:00}" \
    bash "$ROOT_DIR/scripts/auto_nixelo_cycle.sh"
}

run_plan_and_execute() {
  run_cmd run_terminal_automation plan enable-manual nixelo
  assert_status "$RUN_STATUS" 0 "plan enable-manual nixelo" || return 1

  local plan_id
  if [[ ! "$RUN_OUTPUT" =~ PLAN[[:space:]]([0-9-]+) ]]; then
    printf 'ASSERT FAIL plan id parse\noutput:\n%s\n' "$RUN_OUTPUT" >&2
    return 1
  fi
  plan_id="${BASH_REMATCH[1]}"

  run_cmd run_terminal_automation execute "$plan_id"
}

test_terminal_automation_accepts_timestamp_busy() {
  setup_fake_env

  FAKE_PREFLIGHT_RESULT="busy"
  FAKE_PREFLIGHT_STATE="BUSY:content-changing"
  export FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE

  set_journal_output "manual-terminal-nixelo.service" 'Apr 21 01:08:31 nixos opencodectl[1138836]:   "message": "NOOP:terminal-busy session=nixelo state=BUSY:content-changing"'

  run_plan_and_execute

  assert_status "$RUN_STATUS" 0 "execute enable-manual busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'VERIFY_OK manual-terminal-nixelo.timer' 'busy noop verification' || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo' 'busy noop log preserved' || return 1
}

test_terminal_automation_rejects_stuck_terminal() {
  setup_fake_env

  FAKE_PREFLIGHT_RESULT="busy"
  FAKE_PREFLIGHT_STATE="BUSY:content-changing"
  export FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE

  set_journal_output "manual-terminal-nixelo.service" 'Apr 21 01:08:31 nixos opencodectl[1138836]:   "message": "NOOP:terminal-stuck session=nixelo state=STUCK:no-prompt"'

  run_plan_and_execute

  assert_status "$RUN_STATUS" 1 "execute enable-manual stuck noop" || return 1
  assert_contains "$RUN_OUTPUT" 'VERIFY_FAIL manual-terminal-nixelo.timer' 'stuck noop rejected' || return 1
}

test_auto_cycle_skips_when_prci_off() {
  setup_fake_env

  FAKE_GH_OPEN_PR=""
  FAKE_GH_MERGED_PR="50"
  export FAKE_GH_OPEN_PR FAKE_GH_MERGED_PR

  set_unit_state active "prci-terminal-nixelo.timer" inactive
  set_unit_state enabled "prci-terminal-nixelo.timer" disabled

  run_cmd run_auto_cycle

  assert_status "$RUN_STATUS" 0 "auto cycle prci off skip" || return 1
  assert_contains "$RUN_OUTPUT" 'SKIP:prci-off active=inactive enabled=disabled' 'prci off skip output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'gh pr merge' 'no merge when prci off' || return 1
  assert_not_contains "$command_log" 'git checkout dev' 'no branch switch when prci off' || return 1
}

test_auto_cycle_requires_open_pr() {
  setup_fake_env

  FAKE_GH_OPEN_PR=""
  FAKE_DONE_DONE_RESULT="done"
  export FAKE_GH_OPEN_PR FAKE_DONE_DONE_RESULT

  set_unit_state active "prci-terminal-nixelo.timer" active
  set_unit_state enabled "prci-terminal-nixelo.timer" enabled
  set_unit_state active "prci-terminal-nixelo.service" inactive

  run_cmd run_auto_cycle

  assert_status "$RUN_STATUS" 1 "auto cycle missing attached pr" || return 1
  assert_contains "$RUN_OUTPUT" 'ERROR:no-open-pr-after-done-done' 'no open pr hard failure' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'gh pr merge' 'no merge without open pr' || return 1
  assert_not_contains "$command_log" 'systemctl --user disable --now prci-terminal-nixelo.timer' 'no disable without open pr' || return 1
}

test_auto_cycle_waits_for_clean_worktree_before_disabling_prci() {
  setup_fake_env

  FAKE_GH_OPEN_PR="50"
  FAKE_DONE_DONE_RESULT="done"
  export FAKE_GH_OPEN_PR FAKE_DONE_DONE_RESULT

  set_unit_state active "prci-terminal-nixelo.timer" active
  set_unit_state enabled "prci-terminal-nixelo.timer" enabled
  set_unit_state active "prci-terminal-nixelo.service" inactive
  set_git_status $' M src/app.tsx\n M src/test.ts'

  run_cmd run_auto_cycle

  assert_status "$RUN_STATUS" 0 "auto cycle dirty worktree wait" || return 1
  assert_contains "$RUN_OUTPUT" 'WAIT:POST-MERGE:dirty-worktree branch=fixes changes=2 pr=50 active=active enabled=enabled' 'dirty worktree wait output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'systemctl --user disable --now prci-terminal-nixelo.timer' 'prci stays on while waiting' || return 1
  assert_not_contains "$command_log" 'gh pr merge 50 --squash --delete-branch' 'no merge while dirty' || return 1
  assert_not_contains "$command_log" 'git checkout dev' 'no branch switch while dirty' || return 1
}

test_auto_cycle_happy_path_cycles_branch() {
  setup_fake_env

  FAKE_GH_OPEN_PR="50"
  FAKE_DONE_DONE_RESULT="done"
  FAKE_DATE_BRANCH="2026-04-22-12-30"
  export FAKE_GH_OPEN_PR FAKE_DONE_DONE_RESULT FAKE_DATE_BRANCH

  set_unit_state active "prci-terminal-nixelo.timer" active
  set_unit_state enabled "prci-terminal-nixelo.timer" enabled
  set_unit_state active "prci-terminal-nixelo.service" inactive
  set_unit_state active "manual-terminal-nixelo.timer" inactive
  set_unit_state enabled "manual-terminal-nixelo.timer" disabled

  run_cmd run_auto_cycle

  assert_status "$RUN_STATUS" 0 "auto cycle happy path" || return 1
  assert_contains "$RUN_OUTPUT" 'CYCLED:new-branch=2026-04-22-12-30 pr=50' 'happy path cycle output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'systemctl --user disable --now prci-terminal-nixelo.timer' 'disable prci during happy path' || return 1
  assert_contains "$command_log" 'gh pr merge 50 --squash --delete-branch' 'merge attached pr' || return 1
  assert_contains "$command_log" 'git checkout dev' 'checkout target branch' || return 1
  assert_contains "$command_log" 'git checkout -b 2026-04-22-12-30' 'create next branch' || return 1
}

test_auto_cycle_respects_kill_switch() {
  setup_fake_env

  printf '{"enabled": false}\n' > "$HOME/Desktop/shadow/auto-nixelo-enabled.json"

  run_cmd run_auto_cycle

  assert_status "$RUN_STATUS" 0 "auto cycle kill switch" || return 1
  assert_contains "$RUN_OUTPUT" 'SKIP:auto-disabled' 'kill switch output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'systemctl --user' 'no systemctl when auto disabled' || return 1
  assert_not_contains "$command_log" 'gh pr list' 'no github calls when auto disabled' || return 1
}

run_test() {
  local name="$1"
  shift

  TEST_COUNT=$((TEST_COUNT + 1))
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

main() {
  run_test 'terminal automation accepts timestamp-prefixed busy noop' test_terminal_automation_accepts_timestamp_busy
  run_test 'terminal automation rejects stuck noop verification' test_terminal_automation_rejects_stuck_terminal
  run_test 'auto cycle skips when prci is off' test_auto_cycle_skips_when_prci_off
  run_test 'auto cycle requires attached open pr' test_auto_cycle_requires_open_pr
  run_test 'auto cycle waits for clean worktree before disabling prci' test_auto_cycle_waits_for_clean_worktree_before_disabling_prci
  run_test 'auto cycle happy path cycles branch' test_auto_cycle_happy_path_cycles_branch
  run_test 'auto cycle respects kill switch' test_auto_cycle_respects_kill_switch

  printf '\nSummary: %s passed, %s failed, %s total\n' "$PASS_COUNT" "$FAIL_COUNT" "$TEST_COUNT"

  if [[ "$FAIL_COUNT" != 0 ]]; then
    exit 1
  fi
}

main "$@"
