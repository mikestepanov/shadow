#!/usr/bin/env bash
# terminal_classifier.sh — Unified, agnostic terminal state classifier.
#
# Single function: classify_terminal <session>
# Returns: BUSY|IDLE|STUCK + reason on stdout
#
# Decision hierarchy (ordered by reliability):
#   1. Process tree (most reliable — kernel-level truth)
#   2. Queue markers in pane text (Codex/Claude/Gemini agnostic patterns)
#   3. Content-change probe (2 snapshots, 2s apart, volatile lines stripped)
#   4. Prompt cursor position (least reliable — cosmetic, can lie)
#
# Used by: manual-terminal-ping, pr-ci dispatch, watcher, heartbeat
#
# HARD RULES:
#   - If process tree shows child runners → BUSY, no exceptions
#   - If queue marker visible → BUSY, no exceptions
#   - If content changing → BUSY, no exceptions
#   - IDLE only when ALL of: no runners, no queue, content static, cursor on prompt
#   - STUCK when: content static + no runners + no prompt + no recognizable ready UI
set -euo pipefail

# ── Tuning ──────────────────────────────────────────────────────────
CONTENT_PROBE_DELAY="${CONTENT_PROBE_DELAY:-2}"  # seconds between snapshots
SEND_STABILITY_DELAY="${SEND_STABILITY_DELAY:-3}"
RECENT_TAIL_CONTEXT_LINES="${RECENT_TAIL_CONTEXT_LINES:-5}"

# Volatile patterns stripped before content-diff (timers, progress, counters)
VOLATILE_STRIP='/(Working \(|Waiting for|esc to interrupt|esc interrupt|% left|background terminal|·.*running|Worked for|Messages to be submitted)/d'

# Process names that indicate real work (child runners)
RUNNER_RE='(pnpm|npm|npx|tsx|playwright|vitest|jest|tsc|pytest|python|gradle|mvn|docker|kubectl|aws|curl|wget|make|sh|bash.*-c|go test|cargo test|node.*playwright|node.*jest|node.*vitest)'

# Queue marker patterns (agnostic across Codex/Claude/Gemini)
QUEUE_RE='(Messages to be submitted|Press up to edit queued messages|queued messages|^QUEUED[[:space:]]*$)'

# Explicit waiting/running UI markers that mean the harness is still busy even
# when the footer path is visible and the process tree is quiet.
BACKGROUND_WAIT_RE='(Waiting for background terminal|Waited for background terminal|background terminal.*running)'
TAIL_WORK_RE='(Working \(|esc to interrupt|esc interrupt)'

# Prompt glyphs
# OpenCode uses a box-drawing gutter for the live input row.
PROMPT_RE='^[[:space:]]*(>|›|❯|┃)([[:space:]]*$|[[:space:]]+.*)'

# Active work indicators (only meaningful within 5 lines of cursor)
WORK_INDICATOR_RE='(Working \(|esc to interrupt|esc interrupt|Waiting for background terminal)'

# Static UI markers that indicate the harness is still interactive.
READY_UI_RE='(ctrl\+p commands|OpenCode [0-9]|Ask anything\.\.\.|tab agents|Build[[:space:]]+[[:alnum:].-]+)'

# ── Helpers ─────────────────────────────────────────────────────────

_pane_id() {
  tmux list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | head -n1
}

_pane_pid() {
  tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null
}

_pane_cmd() {
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

_cursor_y() {
  tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null || echo ""
}

_process_tree() {
  local pid="$1"
  local sid
  sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -z "$sid" ]] && return
  ps -o stat=,comm=,args= --forest -g "$sid" 2>/dev/null || true
}

_has_child_runners() {
  local tree="$1"
  # Exclude shell, codex, and claude agent lines — they are the terminal host, not child runners
  # Also exclude LSP/language server processes that are always running but not actual work
  local filtered
  filtered=$(printf '%s\n' "$tree" | grep -Ev '(bash|codex|claude|MainThread|opencode|tsserver|biome|lsp-proxy|typingsInstaller)')
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -qE "$RUNNER_RE"; then
      return 0
    fi
  done <<< "$filtered"
  return 1
}

_pane_text() {
  tmux capture-pane -t "$1" -p 2>/dev/null
}

_pane_path() {
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null || true
}

_recent_nonempty_tail() {
  local text="$1"
  printf '%s\n' "$text" | awk 'NF { print }' | tail -n "$RECENT_TAIL_CONTEXT_LINES"
}

_recent_marker_near_tail() {
  local text="$1"
  local pattern="$2"
  local max_distance_from_end="$3"
  local recent_tail total_lines match_line

  recent_tail=$(_recent_nonempty_tail "$text")
  [[ -n "$recent_tail" ]] || return 1

  total_lines=$(printf '%s\n' "$recent_tail" | awk 'END { print NR }')
  match_line=$(printf '%s\n' "$recent_tail" | nl -ba | grep -E "$pattern" | tail -1 | awk '{print $1}' || true)

  [[ -n "$match_line" ]] || return 1
  (( total_lines - match_line <= max_distance_from_end ))
}

_has_queue_marker() {
  local text="$1"
  printf '%s\n' "$text" | tail -30 | sed -E 's/^[[:space:]│┃╎╏▏▎▍▌▋▊▉█▐▕]+//' | grep -Eiq "$QUEUE_RE"
}

_has_recent_background_wait() {
  local text="$1"
  _recent_marker_near_tail "$text" "$BACKGROUND_WAIT_RE" 2
}

_has_recent_tail_work_marker() {
  local text="$1"
  _recent_marker_near_tail "$text" "$TAIL_WORK_RE" 3
}

_content_hash() {
  # Hash pane content with volatile lines stripped
  printf '%s\n' "$1" | sed -E "$VOLATILE_STRIP" | md5sum | cut -d' ' -f1
}

_cursor_on_prompt() {
  local pane="$1"
  local cy start end window_text
  cy=$(_cursor_y "$pane")
  [[ -z "$cy" || ! "$cy" =~ ^[0-9]+$ ]] && return 1

  start=$((cy - 2))
  end=$((cy + 2))
  (( start < 1 )) && start=1

  window_text=$(_pane_text "$pane" | sed -n "${start},${end}p")
  printf '%s\n' "$window_text" | grep -Eq "$PROMPT_RE"
}

_work_indicator_near_cursor() {
  local pane="$1"
  local cy
  cy=$(_cursor_y "$pane")
  [[ -z "$cy" || ! "$cy" =~ ^[0-9]+$ ]] && return 1
  (( cy < 5 )) && return 1
  local above
  above=$(_pane_text "$pane" | sed -n "$((cy-4)),$((cy))p")
  # Only return busy if there's an actual "Working (" indicator, not just UI elements like Build/GPT-5.4
  printf '%s\n' "$above" | grep -Eiq "Working \("
}

_looks_like_footer_path_ready_ui() {
  local pane="$1"
  local tail_text pane_path home_prefix home_relative line trimmed expected_path alt_path

  pane_path=$(_pane_path "$pane")
  [[ -n "$pane_path" ]] || return 1

  expected_path="$pane_path"
  alt_path=""
  home_prefix="${HOME%/}/"
  if [[ "$pane_path" == "$HOME" ]]; then
    alt_path='~'
  elif [[ "$pane_path" == "$home_prefix"* ]]; then
    home_relative="${pane_path#"$home_prefix"}"
    alt_path="~/${home_relative}"
  fi

  tail_text=$(_pane_text "$pane" | awk 'NF { print }' | tail -5)
  while IFS= read -r line; do
    trimmed="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ "$trimmed" == *' · '* ]] || continue
    if [[ "$trimmed" == *" · $expected_path" ]]; then
      return 0
    fi
    if [[ -n "$alt_path" && "$trimmed" == *" · $alt_path" ]]; then
      return 0
    fi
  done <<< "$tail_text"

  return 1
}

_looks_like_static_ready_ui() {
  local pane="$1"
  local tail_text
  tail_text=$(_pane_text "$pane" | tail -40)

  if printf '%s\n' "$tail_text" | grep -Eiq "$READY_UI_RE"; then
    return 0
  fi

  _looks_like_footer_path_ready_ui "$pane"
}

# ── Main classifier ────────────────────────────────────────────────

classify_terminal() {
  local session="$1"
  local pane pane_cmd pid tree text

  # Validate session exists
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "STUCK:session-missing"
    return
  fi

  pane=$(_pane_id "$session")
  [[ -z "$pane" ]] && { echo "STUCK:no-pane"; return; }

  pane_cmd=$(_pane_cmd "$pane")

  # Bare shell means the automation host fell out of OpenCode.
  # Never type prompts into a raw shell and call it ready.
  [[ "$pane_cmd" == "bash" || "$pane_cmd" == "zsh" || "$pane_cmd" == "fish" ]] && {
    echo "STUCK:shell-only"
    return
  }

  pid=$(_pane_pid "$pane")
  tree=$(_process_tree "$pid")
  text=$(_pane_text "$pane")

  # ── Layer 1: Process tree (kernel truth) ──
  if _has_child_runners "$tree"; then
    echo "BUSY:runner"
    return
  fi

  # ── Layer 2: Queue markers (text-based but high confidence) ──
  if _has_queue_marker "$text"; then
    echo "BUSY:queued"
    return
  fi

  # ── Layer 2b: Explicit wait/running markers in the recent tail ──
  # Some harnesses show a static footer path while still waiting on a
  # background terminal or active work item. Those states are busy, not idle.
  if _has_recent_background_wait "$text"; then
    echo "BUSY:background-terminal"
    return
  fi

  if _has_recent_tail_work_marker "$text"; then
    echo "BUSY:work-indicator"
    return
  fi

  # ── Layer 3: Work indicator near cursor ──
  # If cursor is on prompt but Working/esc-to-interrupt is within 5 lines,
  # the CLI is mid-task (showing prompt cosmetically while processing).
  # BUT: if Working timer shows 10+ minutes AND content is static, it's stuck.
  if _work_indicator_near_cursor "$pane"; then
    local work_minutes=0 work_line
    work_line=$(_pane_text "$pane" | grep -oE 'Working \([0-9]+m' | tail -1 || true)
    if [[ -n "$work_line" ]]; then
      work_minutes=$(echo "$work_line" | grep -oE '[0-9]+' || echo 0)
    fi
    if (( work_minutes >= 10 )); then
      # 10+ min Working — but if a background terminal is running, that's
      # normal (foreground waits while bg process does real work).
      # NEVER declare stuck when background terminals are active.
      if printf '%s\n' "$text" | tail -30 | grep -Eiq 'background terminal.*(running|esc to interrupt)'; then
        echo "BUSY:work-indicator"
        return
      fi
      # No bg terminal — quick content-diff to confirm stuck
      local qh1 qh2
      qh1=$(_content_hash "$text")
      sleep 2
      qh2=$(_content_hash "$(_pane_text "$pane")")
      if [[ "$qh1" == "$qh2" ]]; then
        echo "STUCK:stale-working"
        return
      fi
    fi
    echo "BUSY:work-indicator"
    return
  fi

  # ── Layer 4: Content-change probe ──
  local hash1 hash2
  hash1=$(_content_hash "$text")
  sleep "$CONTENT_PROBE_DELAY"
  text=$(_pane_text "$pane")  # re-capture after delay
  hash2=$(_content_hash "$text")

  if [[ "$hash1" != "$hash2" ]]; then
    echo "BUSY:content-changing"
    return
  fi

  # ── Layer 5: Static ready UI detection ──
  # The harness can be ready for input even when the visible prompt is not
  # rendered near the cursor (completed response screen, static footer-only UI).
  if _looks_like_static_ready_ui "$pane"; then
    echo "IDLE:static-ready-ui"
    return
  fi

  # ── Layer 6: Prompt cursor position ──
  # Content is static, no runners, no queue — check if cursor is on prompt
  if _cursor_on_prompt "$pane"; then
    echo "IDLE:prompt"
    return
  fi

  # Content static, no runners, no queue, no prompt → stuck/wedged
  echo "STUCK:no-prompt"
}

# ── Convenience wrappers ───────────────────────────────────────────

is_busy() {
  local state
  state=$(classify_terminal "$1")
  [[ "$state" == BUSY:* ]]
}

is_idle() {
  local state
  state=$(classify_terminal "$1")
  [[ "$state" == IDLE:* ]]
}

is_stuck() {
  local state
  state=$(classify_terminal "$1")
  [[ "$state" == STUCK:* ]]
}

classify_terminal_for_send() {
  local session="$1"
  local state
  local attempts=0
  local max_attempts=3

  while (( attempts < max_attempts )); do
    state=$(classify_terminal "$session")
    if [[ "$state" == IDLE:* ]]; then
      echo "$state"
      return
    fi
    sleep "$SEND_STABILITY_DELAY"
    (( attempts++ ))
  done

  # Final state after retries
  echo "$state"
}

is_idle_for_send() {
  local state
  state=$(classify_terminal_for_send "$1")
  [[ "$state" == IDLE:* ]]
}

# CLI mode detection (reused from old guard)
mode_from_tree() {
  local pane="$1"
  local pid sid tree
  pid=$(tmux display-message -p -t "$pane" '#{pane_pid}')
  sid=$(ps -o sid= -p "$pid" | tr -d ' ')
  tree=$(ps -o pid,ppid,command --forest -g "$sid" || true)
  if echo "$tree" | grep -qE '(/bin/codex|codex --dangerously-bypass-approvals-and-sandbox)'; then
    echo "cdx"; return
  fi
  if echo "$tree" | grep -qE '(^| )claude( |$)'; then
    echo "cc"; return
  fi
  echo "unknown"
}

# Allow sourcing or direct invocation
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 1 ]]; then
    echo "usage: $0 <session>" >&2
    exit 2
  fi
  classify_terminal "$1"
fi
