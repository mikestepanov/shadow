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

set_tmux_pane_path() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/tmux_pane_path"
}

set_tmux_pane_content() {
  printf '%s' "$1" > "$FAKE_STATE_DIR/tmux_pane_content"
}

set_tmux_pane_command() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/tmux_pane_command"
}

set_tmux_pane_pid() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/tmux_pane_pid"
}

set_tmux_cursor_y() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/tmux_cursor_y"
}

set_ps_sid() {
  printf '%s\n' "$1" > "$FAKE_STATE_DIR/ps_sid"
}

set_ps_tree() {
  printf '%s' "$1" > "$FAKE_STATE_DIR/ps_tree"
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

pane_id_file="$state_dir/tmux_pane_id"
pane_path_file="$state_dir/tmux_pane_path"
pane_content_file="$state_dir/tmux_pane_content"
pane_cmd_file="$state_dir/tmux_pane_command"
pane_pid_file="$state_dir/tmux_pane_pid"
cursor_y_file="$state_dir/tmux_cursor_y"
send_keys_count_file="$state_dir/tmux_send_keys_count"

command_name="${1:-}"
case "$command_name" in
  has-session)
    session="${3:-${2:-}}"
    session="${session#-t }"
    session="${session#-t}"
    session_file="$state_dir/tmux_session_${session}"
    if [[ -f "$session_file" ]] && [[ $(cat "$session_file") == present ]]; then
      exit 0
    fi
    exit 1
    ;;
  list-panes)
    if [[ -f "$pane_id_file" ]]; then
      cat "$pane_id_file"
    else
      printf '%%1\n'
    fi
    exit 0
    ;;
  display-message)
    case "${*: -1}" in
      '#{pane_current_path}')
        if [[ -f "$pane_path_file" ]]; then
          cat "$pane_path_file"
        else
          printf '%s\n' "$HOME/Desktop/nixelo"
        fi
        ;;
      '#{pane_current_command}')
        if [[ -f "$pane_cmd_file" ]]; then
          cat "$pane_cmd_file"
        else
          printf 'opencode\n'
        fi
        ;;
      '#{pane_pid}')
        if [[ -f "$pane_pid_file" ]]; then
          cat "$pane_pid_file"
        else
          printf '4242\n'
        fi
        ;;
      '#{cursor_y}')
        if [[ -f "$cursor_y_file" ]]; then
          cat "$cursor_y_file"
        else
          printf '25\n'
        fi
        ;;
      *)
        printf '\n'
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    if [[ -f "$pane_content_file" ]]; then
      cat "$pane_content_file"
    fi
    exit 0
    ;;
  set-buffer)
    exit 0
    ;;
  paste-buffer)
    if [[ -n "${FAKE_TMUX_PASTE_CONTENT:-}" ]]; then
      printf '%s' "$FAKE_TMUX_PASTE_CONTENT" > "$pane_content_file"
    fi
    exit 0
    ;;
  send-keys)
    count=0
    if [[ -f "$send_keys_count_file" ]]; then
      count="$(cat "$send_keys_count_file")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$send_keys_count_file"
    if [[ -n "${FAKE_TMUX_CLEAR_AFTER_SEND_KEYS_COUNT:-}" && "$count" -ge "$FAKE_TMUX_CLEAR_AFTER_SEND_KEYS_COUNT" ]]; then
      printf '%s' "${FAKE_TMUX_AFTER_ENTER_CONTENT:-}" > "$pane_content_file"
    fi
    exit 0
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

arg_value() {
  local needle="$1"
  shift
  local args=("$@")
  local index
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[$index]}" == "$needle" ]]; then
      if (( index + 1 < ${#args[@]} )); then
        printf '%s\n' "${args[$((index + 1))]}"
      fi
      return 0
    fi
  done
  return 1
}

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

if [[ ${1:-} == pr && ${2:-} == checks ]]; then
  printf '%s\n' "${FAKE_GH_PR_CHECKS:-}"
  exit 0
fi

if [[ ${1:-} == pr && ${2:-} == merge ]]; then
  exit "${FAKE_GH_MERGE_EXIT:-0}"
fi

if [[ ${1:-} == pr && ${2:-} == view ]]; then
  json_field="$(arg_value --json "$@" || true)"
  query="$(arg_value -q "$@" || arg_value --jq "$@" || true)"

  case "$json_field" in
    reviewDecision)
      printf '%s\n' "${FAKE_GH_REVIEW_DECISION:-NONE}"
      ;;
    state)
      printf '%s\n' "${FAKE_GH_PR_STATE:-MERGED}"
      ;;
    headRefOid)
      printf '%s\n' "${FAKE_GH_HEAD_SHA:-deadbeef}"
      ;;
    reviews)
      printf '%s\n' "${FAKE_GH_CHANGES_REQUESTED_COUNT:-0}"
      ;;
    statusCheckRollup)
      if [[ "$query" == *'FAILURE'* || "$query" == *'FAILED'* || "$query" == *'ACTION_REQUIRED'* ]]; then
        printf '%s\n' "${FAKE_GH_STATUSCHECK_FAILING_COUNT:-0}"
      else
        printf '%s\n' "${FAKE_GH_STATUSCHECK_PENDING_COUNT:-0}"
      fi
      ;;
    *)
      printf '%s\n' "${FAKE_GH_PR_STATE:-MERGED}"
      ;;
  esac
  exit 0
fi

if [[ ${1:-} == repo && ${2:-} == view ]]; then
  printf '%s\n' "${FAKE_GH_REPO_SLUG:-NixeloApp/nixelo}"
  exit 0
fi

if [[ ${1:-} == api && ${2:-} == graphql ]]; then
  printf '%s\n' "${FAKE_GH_GRAPHQL_RESULT:-0}"
  exit 0
fi

if [[ ${1:-} == api ]]; then
  endpoint="${2:-}"
  query="$(arg_value --jq "$@" || arg_value -q "$@" || true)"

  if [[ "$endpoint" == *'/check-suites'* ]]; then
    if [[ "$query" == *'FAILURE'* || "$query" == *'FAILED'* || "$query" == *'ACTION_REQUIRED'* || "$query" == *'STARTUP_FAILURE'* ]]; then
      printf '%s\n' "${FAKE_GH_CHECK_SUITES_FAILING_COUNT:-0}"
    else
      printf '%s\n' "${FAKE_GH_CHECK_SUITES_PENDING_COUNT:-0}"
    fi
    exit 0
  fi

  if [[ "$endpoint" == *'/status'* ]]; then
    if [[ "$query" == *'PENDING'* ]]; then
      printf '%s\n' "${FAKE_GH_COMMIT_STATUS_PENDING_COUNT:-0}"
    else
      printf '%s\n' "${FAKE_GH_COMMIT_STATUS_FAILING_COUNT:-0}"
    fi
    exit 0
  fi

  printf '%s\n' "${FAKE_GH_API_RESULT:-0}"
  exit 0
fi

if [[ ${1:-} == run && ${2:-} == list ]]; then
  printf '%s\n' "${FAKE_GH_RUN_ID:-}"
  exit 0
fi

if [[ ${1:-} == run && ${2:-} == view ]]; then
  printf '%s\n' "${FAKE_GH_RUN_LOG:-}"
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
  rev-list)
    printf '%s\n' "${FAKE_GIT_AHEAD_COUNT:-0}"
    exit 0
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
  push)
    exit "${FAKE_GIT_PUSH_EXIT:-0}"
    ;;
  log)
    printf '%s\n' "${FAKE_GIT_LOG_OUTPUT:-abcdef1}"
    exit 0
    ;;
esac

exit 0
EOF
  chmod +x "$path"
}

write_stub_ps() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_STATE_DIR:?}"

if [[ ${1:-} == -o && ${2:-} == sid= && ${3:-} == -p ]]; then
  if [[ -f "$state_dir/ps_sid" ]]; then
    cat "$state_dir/ps_sid"
  else
    printf '4242\n'
  fi
  exit 0
fi

if [[ ${1:-} == -o && ${2:-} == stat=,comm=,args= && ${3:-} == --forest && ${4:-} == -g ]]; then
  if [[ -f "$state_dir/ps_tree" ]]; then
    cat "$state_dir/ps_tree"
  fi
  exit 0
fi

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

if [[ ${1:-} == lane-field ]]; then
  lane="${2:-}"
  session="${3:-}"
  field="${4:-}"

  case "$lane:$field" in
    manual:workdir)
      printf '%s\n' "${FAKE_MANUAL_WORKDIR:-$HOME/Desktop/$session}"
      exit 0
      ;;
    manual:prompt)
      printf '%s\n' "${FAKE_MANUAL_PROMPT:-Continue the next todo step.}"
      exit 0
      ;;
    agent:workdir)
      printf '%s\n' "${FAKE_AGENT_WORKDIR:-$HOME/Desktop/$session}"
      exit 0
      ;;
    agent:role)
      printf '%s\n' "${FAKE_AGENT_ROLE:-implementer}"
      exit 0
      ;;
    agent:prompt)
      printf '%s\n' "${FAKE_AGENT_PROMPT:-Continue the assigned work.}"
      exit 0
      ;;
    prci:workdir)
      printf '%s\n' "${FAKE_PRCI_WORKDIR:-$HOME/Desktop/$session}"
      exit 0
      ;;
    prci:dispatchScript)
      printf '%s\n' "${FAKE_PRCI_DISPATCH_SCRIPT:?}"
      exit 0
      ;;
  esac
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

next_preflight_call_number() {
  local count_file="${FAKE_STATE_DIR:?}/fake_preflight_call_count"
  local count="0"
  if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  printf '%s\n' "$count"
}

sequence_value() {
  local raw="$1"
  local index="$2"
  local default_value="$3"
  local items=()

  if [[ -z "$raw" ]]; then
    printf '%s\n' "$default_value"
    return
  fi

  IFS=',' read -r -a items <<< "$raw"
  if (( ${#items[@]} == 0 )); then
    printf '%s\n' "$default_value"
    return
  fi

  if (( index <= ${#items[@]} )); then
    printf '%s\n' "${items[$((index - 1))]}"
    return
  fi

  printf '%s\n' "${items[$(( ${#items[@]} - 1 ))]}"
}

terminal_send_preflight() {
  local session="$1"
  local expected_path="$2"
  local preflight_call result state
  TERMINAL_PREFLIGHT_PANE="%1"
  TERMINAL_PREFLIGHT_CURRENT_PATH="$expected_path"
  TERMINAL_PREFLIGHT_EXPECTED_PATH="$expected_path"
  preflight_call="$(next_preflight_call_number)"
  result="$(sequence_value "${FAKE_PREFLIGHT_RESULT_SEQUENCE:-}" "$preflight_call" "${FAKE_PREFLIGHT_RESULT:-ok}")"

  case "$result" in
    ok)
      state="$(sequence_value "${FAKE_PREFLIGHT_STATE_SEQUENCE:-}" "$preflight_call" "${FAKE_PREFLIGHT_STATE:-IDLE:prompt}")"
      TERMINAL_PREFLIGHT_STATE="$state"
      TERMINAL_PREFLIGHT_REASON="ok"
      return 0
      ;;
    busy)
      state="$(sequence_value "${FAKE_PREFLIGHT_STATE_SEQUENCE:-}" "$preflight_call" "${FAKE_PREFLIGHT_STATE:-BUSY:content-changing}")"
      TERMINAL_PREFLIGHT_STATE="$state"
      TERMINAL_PREFLIGHT_REASON="terminal-not-ready"
      return 1
      ;;
    stuck)
      state="$(sequence_value "${FAKE_PREFLIGHT_STATE_SEQUENCE:-}" "$preflight_call" "${FAKE_PREFLIGHT_STATE:-STUCK:no-prompt}")"
      TERMINAL_PREFLIGHT_STATE="$state"
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
  printf 'fake-send %s\n' "$*" >> "${FAKE_LOG:?}"
  return 0
}

submit_tmux_enter() {
  printf 'fake-enter %s\n' "$*" >> "${FAKE_LOG:?}"
  return 0
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
  printf '%s' "The ${mode} automation for ${session} is blocked by ${dirty_count} uncommitted changes on branch ${branch}."
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

write_fake_prci_dispatch() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_PRCI_DISPATCH_OUTPUT:-checks green}"
EOF
  chmod +x "$path"
}

write_fake_terminal_classifier() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

classify_terminal_for_send() {
  printf '%s\n' "${FAKE_CLASSIFIER_STATE:-IDLE:prompt}"
}
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

  mkdir -p "$HOME/Desktop/nixelo" "$HOME/Desktop/StartHub" "$HOME/Desktop/shadow" "$HOME/.openclaw/workspace/.terminal-automation-plans" "$tmp_dir/bin" "$FAKE_STATE_DIR"
  : > "$FAKE_LOG"

  printf '{"enabled": true}\n' > "$HOME/Desktop/shadow/auto-nixelo-enabled.json"
  printf 'fixes\n' > "$FAKE_STATE_DIR/git_branch"
  : > "$FAKE_STATE_DIR/git_status"
  printf 'present\n' > "$FAKE_STATE_DIR/tmux_session_nixelo"
  printf 'present\n' > "$FAKE_STATE_DIR/tmux_session_starthub"

  write_stub_systemctl "$tmp_dir/bin/systemctl"
  write_stub_journalctl "$tmp_dir/bin/journalctl"
  write_stub_tmux "$tmp_dir/bin/tmux"
  write_stub_gh "$tmp_dir/bin/gh"
  write_stub_git "$tmp_dir/bin/git"
  write_stub_ps "$tmp_dir/bin/ps"
  write_stub_date "$tmp_dir/bin/date"
  write_stub_sleep "$tmp_dir/bin/sleep"
  write_stub_curl "$tmp_dir/bin/curl"

  export TEST_FAKE_OPENCODECTL="$tmp_dir/fake-opencodectl"
  export TEST_FAKE_TERMINAL_MODE_GUARD="$tmp_dir/fake-terminal-mode-guard.sh"
  export TEST_FAKE_TIMERS_INSTALL="$tmp_dir/fake-timers-install"
  export TEST_FAKE_IS_DONE_DONE="$tmp_dir/fake-is-done-done.sh"
  export TEST_FAKE_PRCI_DISPATCH="$tmp_dir/fake-prci-dispatch.sh"
  export TEST_FAKE_TERMINAL_CLASSIFIER="$tmp_dir/fake-terminal-classifier.sh"

  write_fake_opencodectl "$TEST_FAKE_OPENCODECTL"
  write_fake_terminal_mode_guard "$TEST_FAKE_TERMINAL_MODE_GUARD"
  write_fake_timers_install "$TEST_FAKE_TIMERS_INSTALL"
  write_fake_is_done_done "$TEST_FAKE_IS_DONE_DONE"
  write_fake_prci_dispatch "$TEST_FAKE_PRCI_DISPATCH"
  write_fake_terminal_classifier "$TEST_FAKE_TERMINAL_CLASSIFIER"

  set_tmux_pane_path "$HOME/Desktop/nixelo"
  set_tmux_pane_content ''
  set_tmux_pane_command 'opencode'
  set_tmux_pane_pid '4242'
  set_tmux_cursor_y '25'
  set_ps_sid '4242'
  set_ps_tree ''
  printf '%%1\n' > "$FAKE_STATE_DIR/tmux_pane_id"

  export FAKE_MANUAL_WORKDIR="$HOME/Desktop/nixelo"
  export FAKE_MANUAL_PROMPT="Continue the next todo step."
  export FAKE_AGENT_WORKDIR="$HOME/Desktop/nixelo"
  export FAKE_AGENT_ROLE="implementer"
  export FAKE_AGENT_PROMPT="Continue the assigned work."
  export FAKE_PRCI_WORKDIR="$HOME/Desktop/nixelo"
  export FAKE_PRCI_DISPATCH_SCRIPT="$TEST_FAKE_PRCI_DISPATCH"

  unset FAKE_GH_OPEN_PR FAKE_GH_MERGED_PR FAKE_GH_MERGE_EXIT FAKE_GH_PR_STATE FAKE_GH_PR_CHECKS FAKE_GH_REVIEW_DECISION FAKE_GH_REPO_SLUG FAKE_GH_GRAPHQL_RESULT FAKE_GH_API_RESULT FAKE_GH_RUN_ID FAKE_GH_RUN_LOG FAKE_GH_HEAD_SHA FAKE_GH_CHANGES_REQUESTED_COUNT FAKE_GH_STATUSCHECK_FAILING_COUNT FAKE_GH_STATUSCHECK_PENDING_COUNT FAKE_GH_CHECK_SUITES_FAILING_COUNT FAKE_GH_CHECK_SUITES_PENDING_COUNT FAKE_GH_COMMIT_STATUS_FAILING_COUNT FAKE_GH_COMMIT_STATUS_PENDING_COUNT FAKE_DONE_DONE_RESULT FAKE_DONE_DONE_OUTPUT FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE FAKE_PREFLIGHT_RESULT_SEQUENCE FAKE_PREFLIGHT_STATE_SEQUENCE FAKE_DATE_BRANCH FAKE_DATE_SINCE FAKE_CLASSIFIER_STATE FAKE_PRCI_DISPATCH_OUTPUT FAKE_TMUX_PASTE_CONTENT FAKE_TMUX_CLEAR_AFTER_SEND_KEYS_COUNT FAKE_TMUX_AFTER_ENTER_CONTENT USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER FAKE_GIT_AHEAD_COUNT FAKE_GIT_PUSH_EXIT FAKE_GIT_LOG_OUTPUT
}

terminal_mode_guard_for_test() {
  if [[ "${USE_REAL_TERMINAL_MODE_GUARD:-0}" == "1" ]]; then
    printf '%s\n' "$ROOT_DIR/scripts/terminal_mode_guard.sh"
  else
    printf '%s\n' "$TEST_FAKE_TERMINAL_MODE_GUARD"
  fi
}

terminal_classifier_for_test() {
  if [[ "${USE_REAL_TERMINAL_CLASSIFIER:-0}" == "1" ]]; then
    printf '%s\n' "$ROOT_DIR/scripts/terminal_classifier.sh"
  else
    printf '%s\n' "$TEST_FAKE_TERMINAL_CLASSIFIER"
  fi
}

run_terminal_automation() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
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

run_auto_cycle_with_real_done_done() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    TIMERS_INSTALL="$TEST_FAKE_TIMERS_INSTALL" \
    IS_DONE_DONE_SCRIPT="$ROOT_DIR/scripts/is_done_done.sh" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_GH_OPEN_PR="${FAKE_GH_OPEN_PR:-}" \
    FAKE_GH_MERGED_PR="${FAKE_GH_MERGED_PR:-}" \
    FAKE_GH_MERGE_EXIT="${FAKE_GH_MERGE_EXIT:-0}" \
    FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-MERGED}" \
    FAKE_GH_HEAD_SHA="${FAKE_GH_HEAD_SHA:-deadbeef}" \
    FAKE_GH_CHANGES_REQUESTED_COUNT="${FAKE_GH_CHANGES_REQUESTED_COUNT:-0}" \
    FAKE_GH_STATUSCHECK_FAILING_COUNT="${FAKE_GH_STATUSCHECK_FAILING_COUNT:-0}" \
    FAKE_GH_STATUSCHECK_PENDING_COUNT="${FAKE_GH_STATUSCHECK_PENDING_COUNT:-0}" \
    FAKE_GH_CHECK_SUITES_FAILING_COUNT="${FAKE_GH_CHECK_SUITES_FAILING_COUNT:-0}" \
    FAKE_GH_CHECK_SUITES_PENDING_COUNT="${FAKE_GH_CHECK_SUITES_PENDING_COUNT:-0}" \
    FAKE_GH_COMMIT_STATUS_FAILING_COUNT="${FAKE_GH_COMMIT_STATUS_FAILING_COUNT:-0}" \
    FAKE_GH_COMMIT_STATUS_PENDING_COUNT="${FAKE_GH_COMMIT_STATUS_PENDING_COUNT:-0}" \
    FAKE_GH_GRAPHQL_RESULT="${FAKE_GH_GRAPHQL_RESULT:-0}" \
    FAKE_GIT_AHEAD_COUNT="${FAKE_GIT_AHEAD_COUNT:-0}" \
    FAKE_DATE_BRANCH="${FAKE_DATE_BRANCH:-2026-04-21-01-12}" \
    FAKE_DATE_SINCE="${FAKE_DATE_SINCE:-2026-04-21 01:08:00}" \
    bash "$ROOT_DIR/scripts/auto_nixelo_cycle.sh"
}

run_real_is_done_done() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_GH_OPEN_PR="${FAKE_GH_OPEN_PR:-}" \
    FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-OPEN}" \
    FAKE_GH_HEAD_SHA="${FAKE_GH_HEAD_SHA:-deadbeef}" \
    FAKE_GH_CHANGES_REQUESTED_COUNT="${FAKE_GH_CHANGES_REQUESTED_COUNT:-0}" \
    FAKE_GH_STATUSCHECK_FAILING_COUNT="${FAKE_GH_STATUSCHECK_FAILING_COUNT:-0}" \
    FAKE_GH_STATUSCHECK_PENDING_COUNT="${FAKE_GH_STATUSCHECK_PENDING_COUNT:-0}" \
    FAKE_GH_CHECK_SUITES_FAILING_COUNT="${FAKE_GH_CHECK_SUITES_FAILING_COUNT:-0}" \
    FAKE_GH_CHECK_SUITES_PENDING_COUNT="${FAKE_GH_CHECK_SUITES_PENDING_COUNT:-0}" \
    FAKE_GH_COMMIT_STATUS_FAILING_COUNT="${FAKE_GH_COMMIT_STATUS_FAILING_COUNT:-0}" \
    FAKE_GH_COMMIT_STATUS_PENDING_COUNT="${FAKE_GH_COMMIT_STATUS_PENDING_COUNT:-0}" \
    FAKE_GH_GRAPHQL_RESULT="${FAKE_GH_GRAPHQL_RESULT:-0}" \
    FAKE_GIT_AHEAD_COUNT="${FAKE_GIT_AHEAD_COUNT:-0}" \
    bash "$ROOT_DIR/scripts/is_done_done.sh" "$@"
}

run_manual_ping() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    FAKE_MANUAL_WORKDIR="$FAKE_MANUAL_WORKDIR" \
    FAKE_MANUAL_PROMPT="$FAKE_MANUAL_PROMPT" \
    bash "$ROOT_DIR/scripts/manual-terminal-ping" "$@"
}

run_agent_ping() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    FAKE_AGENT_WORKDIR="$FAKE_AGENT_WORKDIR" \
    FAKE_AGENT_ROLE="$FAKE_AGENT_ROLE" \
    FAKE_AGENT_PROMPT="$FAKE_AGENT_PROMPT" \
    bash "$ROOT_DIR/scripts/agent-terminal-ping" "$@"
}

run_prci_ping() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    FAKE_PRCI_WORKDIR="$FAKE_PRCI_WORKDIR" \
    FAKE_PRCI_DISPATCH_SCRIPT="$FAKE_PRCI_DISPATCH_SCRIPT" \
    FAKE_PRCI_DISPATCH_OUTPUT="${FAKE_PRCI_DISPATCH_OUTPUT:-checks green}" \
    bash "$ROOT_DIR/scripts/prci-terminal-ping" "$@"
}

run_prci_dispatch_nixelo() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    FAKE_GH_OPEN_PR="${FAKE_GH_OPEN_PR:-}" \
    FAKE_GH_MERGED_PR="${FAKE_GH_MERGED_PR:-}" \
    FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-OPEN}" \
    FAKE_GH_PR_CHECKS="${FAKE_GH_PR_CHECKS:-}" \
    FAKE_GH_REVIEW_DECISION="${FAKE_GH_REVIEW_DECISION:-NONE}" \
    FAKE_GH_REPO_SLUG="${FAKE_GH_REPO_SLUG:-NixeloApp/nixelo}" \
    FAKE_GH_GRAPHQL_RESULT="${FAKE_GH_GRAPHQL_RESULT:-0}" \
    FAKE_GH_API_RESULT="${FAKE_GH_API_RESULT:-0}" \
    FAKE_GH_RUN_ID="${FAKE_GH_RUN_ID:-}" \
    FAKE_GH_RUN_LOG="${FAKE_GH_RUN_LOG:-}" \
    FAKE_GIT_AHEAD_COUNT="${FAKE_GIT_AHEAD_COUNT:-0}" \
    FAKE_GIT_PUSH_EXIT="${FAKE_GIT_PUSH_EXIT:-0}" \
    FAKE_GIT_LOG_OUTPUT="${FAKE_GIT_LOG_OUTPUT:-abcdef1}" \
    bash "$ROOT_DIR/scripts/pr_ci_nixelo_dispatch.sh"
}

run_prci_dispatch_starthub() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$(terminal_mode_guard_for_test)" \
    TERMINAL_CLASSIFIER="$(terminal_classifier_for_test)" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_PREFLIGHT_RESULT="${FAKE_PREFLIGHT_RESULT:-ok}" \
    FAKE_PREFLIGHT_STATE="${FAKE_PREFLIGHT_STATE:-IDLE:prompt}" \
    FAKE_GH_OPEN_PR="${FAKE_GH_OPEN_PR:-}" \
    FAKE_GH_PR_STATE="${FAKE_GH_PR_STATE:-OPEN}" \
    FAKE_GH_PR_CHECKS="${FAKE_GH_PR_CHECKS:-}" \
    FAKE_GH_REVIEW_DECISION="${FAKE_GH_REVIEW_DECISION:-NONE}" \
    FAKE_GH_REPO_SLUG="${FAKE_GH_REPO_SLUG:-StartHub-Academy/StartHub}" \
    FAKE_GH_GRAPHQL_RESULT="${FAKE_GH_GRAPHQL_RESULT:-0}" \
    FAKE_GH_API_RESULT="${FAKE_GH_API_RESULT:-0}" \
    FAKE_GIT_AHEAD_COUNT="${FAKE_GIT_AHEAD_COUNT:-0}" \
    FAKE_GIT_PUSH_EXIT="${FAKE_GIT_PUSH_EXIT:-0}" \
    FAKE_GIT_LOG_OUTPUT="${FAKE_GIT_LOG_OUTPUT:-abcdef1}" \
    bash "$ROOT_DIR/scripts/pr_ci_starthub_dispatch.sh"
}

run_real_terminal_mode_guard() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    TERMINAL_CLASSIFIER="$TEST_FAKE_TERMINAL_CLASSIFIER" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_CLASSIFIER_STATE="${FAKE_CLASSIFIER_STATE:-IDLE:prompt}" \
    bash -lc "$1"
}

run_real_terminal_classifier() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    CONTENT_PROBE_DELAY="${CONTENT_PROBE_DELAY:-0}" \
    bash -lc "$1"
}

run_real_prci_common() {
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    OPENCODECTL="$TEST_FAKE_OPENCODECTL" \
    TERMINAL_MODE_GUARD="$ROOT_DIR/scripts/terminal_mode_guard.sh" \
    TERMINAL_CLASSIFIER="$ROOT_DIR/scripts/terminal_classifier.sh" \
    REPO_NAME="starthub" \
    REPO_DIR="$HOME/Desktop/StartHub" \
    TMUX_SESSION="starthub" \
    MAX_IDENTICAL="3" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    CONTENT_PROBE_DELAY="0" \
    bash -lc "$1"
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

test_manual_ping_reports_busy_noop() {
  setup_fake_env

  FAKE_PREFLIGHT_RESULT="busy"
  FAKE_PREFLIGHT_STATE="BUSY:content-changing"
  export FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE

  run_cmd run_manual_ping nixelo

  assert_status "$RUN_STATUS" 0 "manual ping busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo state=BUSY:content-changing' 'manual busy noop output' || return 1
}

test_manual_ping_sends_prompt_without_todo_tracking() {
  setup_fake_env

  FAKE_MANUAL_PROMPT='Continue the assigned work.'
  export FAKE_MANUAL_PROMPT

  run_cmd run_manual_ping starthub

  assert_status "$RUN_STATUS" 0 "manual ping sends prompt" || return 1
  assert_contains "$RUN_OUTPUT" 'SENT manual session=starthub msg=Continue the assigned work.' 'manual prompt send output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 Continue the assigned work.' 'manual prompt sent to terminal' || return 1
}

test_manual_ping_real_preflight_sends_on_idle_footer() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  FAKE_MANUAL_WORKDIR="$HOME/Desktop/StartHub"
  FAKE_MANUAL_PROMPT='Continue the assigned work.'
  export FAKE_MANUAL_WORKDIR FAKE_MANUAL_PROMPT
  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'Completed response block\n\n  ready footer · ~/Desktop/StartHub\n'

  run_cmd run_manual_ping starthub

  assert_status "$RUN_STATUS" 0 "manual real preflight idle send" || return 1
  assert_contains "$RUN_OUTPUT" 'SENT manual session=starthub msg=Continue the assigned work.' 'manual real preflight send output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'manual real preflight used paste buffer' || return 1
  assert_contains "$command_log" 'tmux paste-buffer -d -b' 'manual real preflight pasted prompt' || return 1
}

test_manual_ping_real_preflight_blocks_background_wait() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  FAKE_MANUAL_WORKDIR="$HOME/Desktop/StartHub"
  export FAKE_MANUAL_WORKDIR
  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'• Waiting for background terminal · pnpm test\n\n  ready footer · ~/Desktop/StartHub\n'

  run_cmd run_manual_ping starthub

  assert_status "$RUN_STATUS" 0 "manual real preflight busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=starthub state=BUSY:background-terminal' 'manual real preflight busy output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-send %1' 'manual real preflight blocked send' || return 1
}

test_manual_ping_prioritizes_dirty_worktree_recovery() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  export USE_REAL_TERMINAL_MODE_GUARD
  set_git_status $' M src/app.tsx\n M src/test.ts'

  run_cmd run_manual_ping nixelo

  assert_status "$RUN_STATUS" 0 "manual ping dirty worktree" || return 1
  assert_contains "$RUN_OUTPUT" 'SENT manual session=nixelo mode=dirty-worktree changes=2' 'manual dirty recovery output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'manual dirty recovery sent prompt' || return 1
}

test_manual_ping_rechecks_before_dirty_worktree_send() {
  setup_fake_env

  set_git_status $' M src/app.tsx\n'
  FAKE_PREFLIGHT_RESULT_SEQUENCE='ok,busy'
  FAKE_PREFLIGHT_STATE_SEQUENCE='IDLE:prompt,BUSY:queued'
  export FAKE_PREFLIGHT_RESULT_SEQUENCE FAKE_PREFLIGHT_STATE_SEQUENCE

  run_cmd run_manual_ping nixelo

  assert_status "$RUN_STATUS" 0 "manual ping dirty recheck" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo state=BUSY:queued note=final-recheck' 'manual dirty recheck output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-send %1' 'manual dirty recheck prevented send' || return 1
}

test_agent_ping_prioritizes_dirty_worktree_recovery() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  export USE_REAL_TERMINAL_MODE_GUARD
  set_git_status $' M src/app.tsx\n'

  run_cmd run_agent_ping nixelo

  assert_status "$RUN_STATUS" 0 "agent ping dirty worktree" || return 1
  assert_contains "$RUN_OUTPUT" 'SENT role=implementer session=nixelo mode=dirty-worktree changes=1' 'agent dirty recovery output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'agent dirty recovery sent prompt' || return 1
}

test_agent_ping_rechecks_before_send() {
  setup_fake_env

  FAKE_PREFLIGHT_RESULT_SEQUENCE='ok,busy'
  FAKE_PREFLIGHT_STATE_SEQUENCE='IDLE:prompt,BUSY:queued'
  export FAKE_PREFLIGHT_RESULT_SEQUENCE FAKE_PREFLIGHT_STATE_SEQUENCE

  run_cmd run_agent_ping nixelo

  assert_status "$RUN_STATUS" 0 "agent ping final recheck" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy role=implementer session=nixelo state=BUSY:queued note=final-recheck' 'agent final recheck output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-send %1' 'agent final recheck prevented send' || return 1
}

test_agent_ping_real_preflight_sends_on_idle_footer() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'Completed response block\n\n  ready footer · ~/Desktop/nixelo\n'

  run_cmd run_agent_ping nixelo

  assert_status "$RUN_STATUS" 0 "agent real preflight idle send" || return 1
  assert_contains "$RUN_OUTPUT" 'SENT role=implementer session=nixelo' 'agent real preflight send output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'agent real preflight used paste buffer' || return 1
  assert_contains "$command_log" 'tmux paste-buffer -d -b' 'agent real preflight pasted prompt' || return 1
}

test_agent_ping_real_preflight_blocks_background_wait() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'• background terminal is still running\n\n  ready footer · ~/Desktop/nixelo\n'

  run_cmd run_agent_ping nixelo

  assert_status "$RUN_STATUS" 0 "agent real preflight busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy role=implementer session=nixelo state=BUSY:background-terminal' 'agent real preflight busy output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-send %1' 'agent real preflight blocked send' || return 1
}

test_prci_ping_reports_busy_noop() {
  setup_fake_env

  FAKE_PREFLIGHT_RESULT="busy"
  FAKE_PREFLIGHT_STATE="BUSY:content-changing"
  export FAKE_PREFLIGHT_RESULT FAKE_PREFLIGHT_STATE

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci ping busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo state=BUSY:content-changing' 'prci busy noop output' || return 1
}

test_prci_ping_prioritizes_dirty_worktree_recovery() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  export USE_REAL_TERMINAL_MODE_GUARD
  set_git_status $' M src/app.tsx\n M src/test.ts\n M src/third.ts'

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci ping dirty worktree" || return 1
  assert_contains "$RUN_OUTPUT" 'PR-CI: SENT dirty-worktree session=nixelo changes=3' 'prci dirty recovery output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-prci-dispatch.sh' 'prci dispatch skipped while dirty' || return 1
  assert_contains "$command_log" 'tmux set-buffer -b' 'prci dirty recovery sent prompt' || return 1
}

test_prci_ping_rechecks_before_dirty_worktree_send() {
  setup_fake_env

  set_git_status $' M src/app.tsx\n'
  FAKE_PREFLIGHT_RESULT_SEQUENCE='ok,busy'
  FAKE_PREFLIGHT_STATE_SEQUENCE='IDLE:prompt,BUSY:queued'
  export FAKE_PREFLIGHT_RESULT_SEQUENCE FAKE_PREFLIGHT_STATE_SEQUENCE

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci ping dirty recheck" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo state=BUSY:queued note=final-recheck' 'prci dirty recheck output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-send %1' 'prci dirty recheck prevented send' || return 1
  assert_not_contains "$command_log" 'fake-prci-dispatch.sh' 'prci dirty recheck skipped dispatch' || return 1
}

test_prci_ping_runs_dispatch_script() {
  setup_fake_env

  FAKE_PRCI_DISPATCH_OUTPUT='checks green and comments resolved'
  export FAKE_PRCI_DISPATCH_OUTPUT

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci ping dispatch" || return 1
  assert_contains "$RUN_OUTPUT" 'PR-CI: checks green and comments resolved' 'prci dispatch output' || return 1
}

test_prci_ping_real_preflight_runs_dispatch_on_idle_footer() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'Completed response block\n\n  ready footer · ~/Desktop/nixelo\n'
  FAKE_PRCI_DISPATCH_OUTPUT='checks green and comments resolved'
  export FAKE_PRCI_DISPATCH_OUTPUT

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci real preflight idle dispatch" || return 1
  assert_contains "$RUN_OUTPUT" 'PR-CI: checks green and comments resolved' 'prci real preflight dispatch output' || return 1
}

test_prci_ping_real_preflight_blocks_background_wait() {
  setup_fake_env

  USE_REAL_TERMINAL_MODE_GUARD=1
  USE_REAL_TERMINAL_CLASSIFIER=1
  export USE_REAL_TERMINAL_MODE_GUARD USE_REAL_TERMINAL_CLASSIFIER
  set_tmux_pane_command 'node'
  set_tmux_pane_content $'• Waited for background terminal · pnpm test\n\n  ready footer · ~/Desktop/nixelo\n'

  run_cmd run_prci_ping nixelo

  assert_status "$RUN_STATUS" 0 "prci real preflight busy noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:terminal-busy session=nixelo state=BUSY:background-terminal' 'prci real preflight busy output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'fake-prci-dispatch.sh' 'prci real preflight blocked dispatch' || return 1
}

test_prci_dispatch_pushes_ahead_branch_first() {
  setup_fake_env

  FAKE_GH_OPEN_PR='51'
  FAKE_GIT_AHEAD_COUNT='2'
  export FAKE_GH_OPEN_PR FAKE_GIT_AHEAD_COUNT

  run_cmd run_prci_dispatch_nixelo

  assert_status "$RUN_STATUS" 0 "prci dispatch pushes ahead branch" || return 1
  assert_contains "$RUN_OUTPUT" 'PUSHED:branch=fixes ahead=2' 'push output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'git push origin fixes' 'push command executed' || return 1
}

test_prci_dispatch_fixes_review_issues_even_when_ci_green() {
  setup_fake_env

  FAKE_GH_OPEN_PR='51'
  FAKE_GH_PR_CHECKS=$'CodeRabbit pass\nUnit pass'
  FAKE_GH_REVIEW_DECISION='CHANGES_REQUESTED'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS FAKE_GH_REVIEW_DECISION

  run_cmd run_prci_dispatch_nixelo

  assert_status "$RUN_STATUS" 0 "prci dispatch green review issues" || return 1
  assert_contains "$RUN_OUTPUT" 'OK: CI green but review issues found' 'green review issues output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 /fix-pr-comments' 'fix pr comments dispatched' || return 1
}

test_starthub_prci_dispatch_opens_pr_when_missing() {
  setup_fake_env

  set_git_branch 'feature-shells'
  FAKE_GH_OPEN_PR=''
  export FAKE_GH_OPEN_PR

  run_cmd run_prci_dispatch_starthub

  assert_status "$RUN_STATUS" 0 "starthub prci dispatch no pr" || return 1
  assert_contains "$RUN_OUTPUT" 'OK: no open PR, dispatched /pr' 'starthub /pr output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 /pr' 'starthub /pr dispatched' || return 1
}

test_starthub_prci_dispatch_green_noops_without_review_issues() {
  setup_fake_env

  set_git_branch 'feature-shells'
  FAKE_GH_OPEN_PR='77'
  FAKE_GH_PR_CHECKS=$'Unit pass\nPlaywright pass'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS

  run_cmd run_prci_dispatch_starthub

  assert_status "$RUN_STATUS" 0 "starthub prci green noop" || return 1
  assert_contains "$RUN_OUTPUT" 'NOOP:ci-green — all checks passing, no unresolved review issues' 'starthub green noop output' || return 1
}

test_starthub_prci_dispatch_green_fixes_unresolved_threads() {
  setup_fake_env

  set_git_branch 'feature-shells'
  FAKE_GH_OPEN_PR='77'
  FAKE_GH_PR_CHECKS=$'Unit pass\nPlaywright pass'
  FAKE_GH_GRAPHQL_RESULT='2'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS FAKE_GH_GRAPHQL_RESULT

  run_cmd run_prci_dispatch_starthub

  assert_status "$RUN_STATUS" 0 "starthub prci green review issues" || return 1
  assert_contains "$RUN_OUTPUT" 'OK: CI green but review issues found (2 threads, 0 new human comments), dispatched /fix-pr-comments' 'starthub green review issues output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 /fix-pr-comments' 'starthub green review issues dispatched' || return 1
}

test_starthub_prci_dispatch_pending_fixes_changes_requested() {
  setup_fake_env

  set_git_branch 'feature-shells'
  FAKE_GH_OPEN_PR='77'
  FAKE_GH_PR_CHECKS=$'Unit pending'
  FAKE_GH_REVIEW_DECISION='CHANGES_REQUESTED'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS FAKE_GH_REVIEW_DECISION

  run_cmd run_prci_dispatch_starthub

  assert_status "$RUN_STATUS" 0 "starthub prci pending changes requested" || return 1
  assert_contains "$RUN_OUTPUT" 'OK: CI pending but review issues found (0 threads, 0 new human comments), dispatched /fix-pr-comments' 'starthub pending review issues output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 /fix-pr-comments' 'starthub pending review issues dispatched' || return 1
}

test_prci_dispatch_reports_push_failure() {
  setup_fake_env

  FAKE_GH_OPEN_PR='51'
  FAKE_GIT_AHEAD_COUNT='2'
  FAKE_GIT_PUSH_EXIT='1'
  export FAKE_GH_OPEN_PR FAKE_GIT_AHEAD_COUNT FAKE_GIT_PUSH_EXIT

  run_cmd run_prci_dispatch_nixelo

  assert_status "$RUN_STATUS" 1 "prci dispatch push failure" || return 1
  assert_contains "$RUN_OUTPUT" 'ERROR:push-failed branch=fixes ahead=2' 'push failure output' || return 1
}

test_prci_dispatch_escalates_stalled_loop_with_ci_details() {
  setup_fake_env

  FAKE_GH_OPEN_PR='51'
  FAKE_GH_PR_CHECKS=$'Unknown fail'
  FAKE_GH_RUN_ID='12345'
  FAKE_GH_RUN_LOG='error TS2345: type mismatch'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS FAKE_GH_RUN_ID FAKE_GH_RUN_LOG
  set_tmux_pane_content 'previous summary block'

  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch loop warmup 1" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch loop warmup 2" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch loop warmup 3" || return 1
  run_cmd run_prci_dispatch_nixelo

  assert_status "$RUN_STATUS" 0 "prci dispatch loop escalation" || return 1
  assert_contains "$RUN_OUTPUT" 'OK: dispatched to nixelo (CI: failing)' 'loop escalation dispatch output' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'fake-send %1 CI is failing with these specific errors.' 'specific ci fix dispatched' || return 1
}

test_prci_dispatch_alerts_human_after_repeated_stall() {
  setup_fake_env

  FAKE_GH_OPEN_PR='51'
  FAKE_GH_PR_CHECKS=$'Biome fail'
  export FAKE_GH_OPEN_PR FAKE_GH_PR_CHECKS

  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 1" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 2" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 3" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 4" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 5" || return 1
  run_cmd run_prci_dispatch_nixelo
  assert_status "$RUN_STATUS" 0 "prci dispatch alert warmup 6" || return 1
  run_cmd run_prci_dispatch_nixelo

  assert_status "$RUN_STATUS" 0 "prci dispatch human alert" || return 1
  assert_contains "$RUN_OUTPUT" 'BLOCKED:alerted-human' 'human alert output' || return 1
}

test_prci_common_repastes_when_command_only_in_history() {
  setup_fake_env

  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_command 'opencode'
  set_tmux_cursor_y '40'
  set_tmux_pane_content $'Usage:\n- /fix-pr-comments - current branch\n- /fix-pr-comments 1570 - specific PR\n\n  ready footer · ~/Desktop/StartHub\n'

  run_cmd run_real_prci_common "source '$ROOT_DIR/scripts/pr_ci_dispatch_common.sh'; send_command '/fix-pr-comments'"

  assert_status "$RUN_STATUS" 0 "prci common history repaste" || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'prci common repasted command from history state' || return 1
  assert_contains "$command_log" 'tmux paste-buffer -d -b' 'prci common pasted command from history state' || return 1
}

test_prci_common_submits_when_command_buffered_at_prompt() {
  setup_fake_env

  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_command 'opencode'
  set_tmux_cursor_y '2'
  set_tmux_pane_content $'  notes\n  /fix-pr-comments\n\n  ready footer · ~/Desktop/StartHub\n'

  run_cmd run_real_prci_common "source '$ROOT_DIR/scripts/pr_ci_dispatch_common.sh'; send_command '/fix-pr-comments'"

  assert_status "$RUN_STATUS" 0 "prci common prompt submit" || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux send-keys -t %1 Enter' 'prci common submitted buffered command' || return 1
  assert_not_contains "$command_log" 'tmux paste-buffer -d -b' 'prci common did not repaste buffered command' || return 1
}

test_prci_common_double_enters_slash_command_after_paste() {
  setup_fake_env

  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_command 'opencode'
  set_tmux_cursor_y '2'
  set_tmux_pane_content $'  idle\n  ready footer · ~/Desktop/StartHub\n'
  export FAKE_TMUX_PASTE_CONTENT=$'  expanded command body\n\n  ready footer · ~/Desktop/StartHub\n'
  export FAKE_TMUX_CLEAR_AFTER_SEND_KEYS_COUNT='2'
  export FAKE_TMUX_AFTER_ENTER_CONTENT=$'  submitted\n\n  ready footer · ~/Desktop/StartHub\n'

  run_cmd run_real_prci_common "source '$ROOT_DIR/scripts/pr_ci_dispatch_common.sh'; send_command '/fix-pr-comments'; printf 'result=%s\n' \"\$SEND_COMMAND_RESULT\""

  assert_status "$RUN_STATUS" 0 "prci common slash double enter" || return 1
  assert_contains "$RUN_OUTPUT" 'result=slash-double-enter' 'prci common slash double enter result' || return 1

  local command_log send_count
  command_log="$(cat "$FAKE_LOG")"
  send_count="$(grep -c 'tmux send-keys -t %1 Enter' "$FAKE_LOG" || true)"
  assert_contains "$command_log" 'tmux paste-buffer -d -b' 'prci common slash double enter pasted command' || return 1
  if [[ "$send_count" != "2" ]]; then
    printf 'ASSERT FAIL prci common slash double enter count\nexpected=2 actual=%s\noutput:\n%s\n' "$send_count" "$command_log" >&2
    return 1
  fi
}

test_terminal_classifier_rejects_shell_only() {
  setup_fake_env

  set_tmux_pane_command 'bash'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier shell-only" || return 1
  assert_contains "$RUN_OUTPUT" 'STUCK:shell-only' 'shell-only classification' || return 1
}

test_terminal_classifier_reports_busy_runner() {
  setup_fake_env

  set_ps_tree $' S opencode opencode\n S node pnpm vitest run'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier busy runner" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:runner' 'busy runner classification' || return 1
}

test_terminal_classifier_reports_busy_queued() {
  setup_fake_env

  set_tmux_pane_content $'line 1\nMessages to be submitted\n'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier busy queued" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:queued' 'busy queued classification' || return 1
}

test_terminal_classifier_reports_busy_gutter_queued() {
  setup_fake_env

  set_tmux_pane_content $'line 1\n  ┃   QUEUED\n'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier busy gutter queued" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:queued' 'gutter queued classification' || return 1
}

test_terminal_classifier_reports_busy_background_terminal_wait() {
  setup_fake_env

  set_tmux_pane_content $'• Waited for background terminal · pnpm --filter @app/backend test\n\n  ready footer · ~/Desktop/StartHub\n'
  set_tmux_pane_command 'node'
  set_tmux_pane_path "$HOME/Desktop/StartHub"

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal starthub"

  assert_status "$RUN_STATUS" 0 "classifier background terminal wait" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:background-terminal' 'background terminal wait classification' || return 1
}

test_terminal_classifier_reports_busy_background_terminal_running() {
  setup_fake_env

  set_tmux_pane_content $'• background terminal is still running\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier background terminal running" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:background-terminal' 'background terminal running classification' || return 1
}

test_terminal_classifier_reports_busy_waiting_for_background_terminal() {
  setup_fake_env

  set_tmux_pane_content $'• Waiting for background terminal · pnpm test\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier waiting for background terminal" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:background-terminal' 'waiting for background terminal classification' || return 1
}

test_terminal_classifier_reports_busy_tail_work_indicator() {
  setup_fake_env

  set_tmux_cursor_y '80'
  set_tmux_pane_content $'Completed output block\n• Working (6m 58s • esc to interrupt)\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier tail work indicator" || return 1
  assert_contains "$RUN_OUTPUT" 'BUSY:work-indicator' 'tail work indicator classification' || return 1
}

test_terminal_classifier_ignores_stale_background_wait_outside_recent_tail() {
  setup_fake_env

  set_tmux_pane_content $'• Waited for background terminal · pnpm test\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\nline 11\nline 12\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier stale background wait ignored" || return 1
  assert_contains "$RUN_OUTPUT" 'IDLE:static-ready-ui' 'stale background wait ignored classification' || return 1
}

test_terminal_classifier_ignores_stale_work_marker_outside_recent_tail() {
  setup_fake_env

  set_tmux_pane_content $'• Working (6m 58s • esc to interrupt)\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier stale work marker ignored" || return 1
  assert_contains "$RUN_OUTPUT" 'IDLE:static-ready-ui' 'stale work marker ignored classification' || return 1
}

test_terminal_classifier_reports_stuck_without_prompt() {
  setup_fake_env

  set_tmux_pane_content $'Completed output block\nstatic footer only\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier stuck without prompt" || return 1
  assert_contains "$RUN_OUTPUT" 'STUCK:no-prompt' 'stuck no prompt classification' || return 1
}

test_terminal_classifier_accepts_generic_footer_ready_ui() {
  setup_fake_env

  set_tmux_pane_content $'Committed the completed work.\n\n  ready footer · ~/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier generic footer ready" || return 1
  assert_contains "$RUN_OUTPUT" 'IDLE:static-ready-ui' 'generic footer ready classification' || return 1
}

test_terminal_classifier_accepts_absolute_path_footer_ready_ui() {
  setup_fake_env

  set_tmux_pane_content $'Completed response block.\n\n  status footer · '"$HOME"$'/Desktop/nixelo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier absolute footer ready" || return 1
  assert_contains "$RUN_OUTPUT" 'IDLE:static-ready-ui' 'absolute footer ready classification' || return 1
}

test_terminal_classifier_rejects_unrelated_footer_path() {
  setup_fake_env

  set_tmux_pane_content $'Completed response block.\n\n  ready footer · ~/Desktop/other-repo\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal nixelo"

  assert_status "$RUN_STATUS" 0 "classifier unrelated footer path" || return 1
  assert_contains "$RUN_OUTPUT" 'STUCK:no-prompt' 'unrelated footer path rejected' || return 1
}

test_terminal_classifier_accepts_footer_for_current_path_only() {
  setup_fake_env

  set_tmux_pane_path "$HOME/Desktop/StartHub"
  set_tmux_pane_content $'Completed response block.\n\n  idle footer · ~/Desktop/StartHub\n'
  set_tmux_pane_command 'node'

  run_cmd run_real_terminal_classifier "source '$ROOT_DIR/scripts/terminal_classifier.sh'; classify_terminal starthub"

  assert_status "$RUN_STATUS" 0 "classifier current path footer ready" || return 1
  assert_contains "$RUN_OUTPUT" 'IDLE:static-ready-ui' 'current path footer ready classification' || return 1
}

test_terminal_mode_guard_reports_path_mismatch() {
  setup_fake_env

  set_tmux_pane_path '/wrong/path'

  run_cmd run_real_terminal_mode_guard "source '$ROOT_DIR/scripts/terminal_mode_guard.sh'; if terminal_send_preflight nixelo '$HOME/Desktop/nixelo'; then echo ok; else echo reason=\"\$TERMINAL_PREFLIGHT_REASON\" current=\"\$TERMINAL_PREFLIGHT_CURRENT_PATH\"; fi"

  assert_status "$RUN_STATUS" 0 "guard path mismatch" || return 1
  assert_contains "$RUN_OUTPUT" 'reason=path-mismatch current=/wrong/path' 'guard path mismatch output' || return 1
}

test_terminal_mode_guard_rejects_shell_only() {
  setup_fake_env

  FAKE_CLASSIFIER_STATE='STUCK:shell-only'
  export FAKE_CLASSIFIER_STATE

  run_cmd run_real_terminal_mode_guard "source '$ROOT_DIR/scripts/terminal_mode_guard.sh'; if terminal_send_preflight nixelo '$HOME/Desktop/nixelo'; then echo ok; else echo reason=\"\$TERMINAL_PREFLIGHT_REASON\" state=\"\$TERMINAL_PREFLIGHT_STATE\"; fi"

  assert_status "$RUN_STATUS" 0 "guard shell-only rejection" || return 1
  assert_contains "$RUN_OUTPUT" 'reason=terminal-not-ready state=STUCK:shell-only' 'guard rejects shell-only pane' || return 1
}

test_terminal_mode_guard_uses_paste_buffer_send_path() {
  setup_fake_env

  run_cmd run_real_terminal_mode_guard "source '$ROOT_DIR/scripts/terminal_mode_guard.sh'; send_tmux_text_enter '%1' 'hello world'"

  assert_status "$RUN_STATUS" 0 "guard paste buffer send" || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_contains "$command_log" 'tmux set-buffer -b' 'guard uses tmux set-buffer' || return 1
  assert_contains "$command_log" 'tmux paste-buffer -d -b' 'guard uses tmux paste-buffer' || return 1
  assert_contains "$command_log" 'tmux send-keys -t %1 Enter' 'guard sends enter after paste' || return 1
}

test_is_done_done_blocks_pending_check_suites() {
  setup_fake_env

  FAKE_GH_OPEN_PR='55'
  FAKE_GH_HEAD_SHA='dd303612ab37f6bb5d7375294f2086c394567cf5'
  FAKE_GH_CHECK_SUITES_PENDING_COUNT='2'
  export FAKE_GH_OPEN_PR FAKE_GH_HEAD_SHA FAKE_GH_CHECK_SUITES_PENDING_COUNT

  run_cmd run_real_is_done_done nixelo

  assert_status "$RUN_STATUS" 2 "is_done_done pending check suites" || return 1
  assert_contains "$RUN_OUTPUT" 'NOT-READY:commit-check-suites-pending (pending=2)' 'pending check suites gate output' || return 1
}

test_is_done_done_blocks_pending_commit_status_contexts() {
  setup_fake_env

  FAKE_GH_OPEN_PR='55'
  FAKE_GH_HEAD_SHA='dd303612ab37f6bb5d7375294f2086c394567cf5'
  FAKE_GH_COMMIT_STATUS_PENDING_COUNT='1'
  export FAKE_GH_OPEN_PR FAKE_GH_HEAD_SHA FAKE_GH_COMMIT_STATUS_PENDING_COUNT

  run_cmd run_real_is_done_done nixelo

  assert_status "$RUN_STATUS" 2 "is_done_done pending commit statuses" || return 1
  assert_contains "$RUN_OUTPUT" 'NOT-READY:commit-status-contexts-pending (pending=1)' 'pending commit status gate output' || return 1
}

test_auto_cycle_waits_for_real_done_done_check_suites() {
  setup_fake_env

  FAKE_GH_OPEN_PR='50'
  FAKE_GH_HEAD_SHA='dd303612ab37f6bb5d7375294f2086c394567cf5'
  FAKE_GH_CHECK_SUITES_PENDING_COUNT='2'
  export FAKE_GH_OPEN_PR FAKE_GH_HEAD_SHA FAKE_GH_CHECK_SUITES_PENDING_COUNT

  set_unit_state active "prci-terminal-nixelo.timer" active
  set_unit_state enabled "prci-terminal-nixelo.timer" enabled
  set_unit_state active "prci-terminal-nixelo.service" inactive

  run_cmd run_auto_cycle_with_real_done_done

  assert_status "$RUN_STATUS" 0 "auto cycle real gate pending check suites" || return 1
  assert_contains "$RUN_OUTPUT" 'WAIT:NOT-READY:commit-check-suites-pending (pending=2)' 'auto cycle waits on queued check suites' || return 1

  local command_log
  command_log="$(cat "$FAKE_LOG")"
  assert_not_contains "$command_log" 'systemctl --user disable --now prci-terminal-nixelo.timer' 'prci stays enabled while queued suites remain' || return 1
  assert_not_contains "$command_log" 'gh pr merge 50 --squash --delete-branch' 'auto cycle does not merge with queued suites' || return 1
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
  run_test 'manual ping reports busy noop' test_manual_ping_reports_busy_noop
  run_test 'manual ping sends prompt without todo tracking' test_manual_ping_sends_prompt_without_todo_tracking
  run_test 'manual ping real preflight sends on idle footer' test_manual_ping_real_preflight_sends_on_idle_footer
  run_test 'manual ping real preflight blocks background wait' test_manual_ping_real_preflight_blocks_background_wait
  run_test 'manual ping prioritizes dirty worktree recovery' test_manual_ping_prioritizes_dirty_worktree_recovery
  run_test 'manual ping rechecks before dirty-worktree send' test_manual_ping_rechecks_before_dirty_worktree_send
  run_test 'agent ping prioritizes dirty worktree recovery' test_agent_ping_prioritizes_dirty_worktree_recovery
  run_test 'agent ping rechecks before send' test_agent_ping_rechecks_before_send
  run_test 'agent ping real preflight sends on idle footer' test_agent_ping_real_preflight_sends_on_idle_footer
  run_test 'agent ping real preflight blocks background wait' test_agent_ping_real_preflight_blocks_background_wait
  run_test 'prci ping reports busy noop' test_prci_ping_reports_busy_noop
  run_test 'prci ping prioritizes dirty worktree recovery' test_prci_ping_prioritizes_dirty_worktree_recovery
  run_test 'prci ping rechecks before dirty-worktree send' test_prci_ping_rechecks_before_dirty_worktree_send
  run_test 'prci ping runs dispatch script' test_prci_ping_runs_dispatch_script
  run_test 'prci ping real preflight runs dispatch on idle footer' test_prci_ping_real_preflight_runs_dispatch_on_idle_footer
  run_test 'prci ping real preflight blocks background wait' test_prci_ping_real_preflight_blocks_background_wait
  run_test 'prci dispatch pushes ahead branch first' test_prci_dispatch_pushes_ahead_branch_first
  run_test 'prci dispatch fixes review issues even when ci is green' test_prci_dispatch_fixes_review_issues_even_when_ci_green
  run_test 'starthub prci dispatch opens pr when missing' test_starthub_prci_dispatch_opens_pr_when_missing
  run_test 'starthub prci dispatch green noops without review issues' test_starthub_prci_dispatch_green_noops_without_review_issues
  run_test 'starthub prci dispatch green fixes unresolved threads' test_starthub_prci_dispatch_green_fixes_unresolved_threads
  run_test 'starthub prci dispatch pending fixes changes requested' test_starthub_prci_dispatch_pending_fixes_changes_requested
  run_test 'prci dispatch reports push failure' test_prci_dispatch_reports_push_failure
  run_test 'prci dispatch escalates stalled loop with ci details' test_prci_dispatch_escalates_stalled_loop_with_ci_details
  run_test 'prci dispatch alerts human after repeated stall' test_prci_dispatch_alerts_human_after_repeated_stall
  run_test 'prci common repastes when command only in history' test_prci_common_repastes_when_command_only_in_history
  run_test 'prci common submits when command buffered at prompt' test_prci_common_submits_when_command_buffered_at_prompt
  run_test 'prci common double-enters slash command after paste' test_prci_common_double_enters_slash_command_after_paste
  run_test 'terminal classifier rejects shell-only pane' test_terminal_classifier_rejects_shell_only
  run_test 'terminal classifier reports busy runner' test_terminal_classifier_reports_busy_runner
  run_test 'terminal classifier reports busy queued' test_terminal_classifier_reports_busy_queued
  run_test 'terminal classifier reports busy gutter queued' test_terminal_classifier_reports_busy_gutter_queued
  run_test 'terminal classifier reports busy background terminal wait' test_terminal_classifier_reports_busy_background_terminal_wait
  run_test 'terminal classifier reports busy background terminal running' test_terminal_classifier_reports_busy_background_terminal_running
  run_test 'terminal classifier reports busy waiting for background terminal' test_terminal_classifier_reports_busy_waiting_for_background_terminal
  run_test 'terminal classifier reports busy tail work indicator' test_terminal_classifier_reports_busy_tail_work_indicator
  run_test 'terminal classifier ignores stale background wait outside recent tail' test_terminal_classifier_ignores_stale_background_wait_outside_recent_tail
  run_test 'terminal classifier ignores stale work marker outside recent tail' test_terminal_classifier_ignores_stale_work_marker_outside_recent_tail
  run_test 'terminal classifier reports stuck without prompt' test_terminal_classifier_reports_stuck_without_prompt
  run_test 'terminal classifier accepts generic footer ready ui' test_terminal_classifier_accepts_generic_footer_ready_ui
  run_test 'terminal classifier accepts absolute path footer ready ui' test_terminal_classifier_accepts_absolute_path_footer_ready_ui
  run_test 'terminal classifier rejects unrelated footer path' test_terminal_classifier_rejects_unrelated_footer_path
  run_test 'terminal classifier accepts footer for current path only' test_terminal_classifier_accepts_footer_for_current_path_only
  run_test 'terminal mode guard reports path mismatch' test_terminal_mode_guard_reports_path_mismatch
  run_test 'terminal mode guard rejects shell-only pane' test_terminal_mode_guard_rejects_shell_only
  run_test 'terminal mode guard uses paste-buffer send path' test_terminal_mode_guard_uses_paste_buffer_send_path
  run_test 'is_done_done blocks pending check suites' test_is_done_done_blocks_pending_check_suites
  run_test 'is_done_done blocks pending commit status contexts' test_is_done_done_blocks_pending_commit_status_contexts
  run_test 'auto cycle waits for real done-done check suites' test_auto_cycle_waits_for_real_done_done_check_suites
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
