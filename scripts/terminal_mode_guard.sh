#!/usr/bin/env bash
set -euo pipefail

log_guard(){ printf '%s\n' "$*"; }

ta_unit_on(){
  local unit="$1"
  local a e
  a=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  e=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
  [[ "$a" == "active" && "$e" == "enabled" ]]
}

mode_from_tree(){
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

busy_reason(){
  local pane_id="$1"
  local pane_cmd pane_pid sid tree pane_tail pstate

  pane_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}')
  [[ "$pane_cmd" == "bash" ]] && { echo "idle:shell"; return; }

  # Capture tail early for queue/background guards.
  pane_tail=$(tmux capture-pane -t "$pane_id" -p | tail -80)

  # Hard busy guard: queued outbound messages means the terminal is already saturated.
  # Must be model/CLI-agnostic across Codex/Claude/Gemini style UIs.
  if printf '%s\n' "$pane_tail" | grep -Eiq '(Messages to be submitted after next tool call|Press up to edit queued messages|^[[:space:]]*[↳].+|^[[:space:]]*[>-][[:space:]]+Read[[:space:]]+todos|queued messages|queued-input)'; then
    echo "busy:queued-input"
    return
  fi

  # Hard busy guard: background terminal activity should block new nudges.
  # Only match ACTIVE indicators. Past-tense "Waited for background terminal" is historical.
  # Check last 15 lines to avoid stale scrollback matches.
  # Cross-check with process tree: if no child runners are active, the "background terminal"
  # indicator is stale UI decoration — don't block nudges on it.
  if printf '%s\n' "$pane_tail" | tail -15 | grep -Eiq '([0-9]+ background terminal running|Waiting for background terminal|esc to interrupt.*background terminal)'; then
    local bg_pane_pid bg_sid bg_tree
    bg_pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}')
    bg_sid=$(ps -o sid= -p "$bg_pane_pid" | tr -d ' ')
    bg_tree=$(ps -o stat=,comm=,args= --forest -g "$bg_sid" 2>/dev/null || true)
    if printf '%s\n' "$bg_tree" | grep -Eiq '(^|[[:space:]])(pnpm|npm|npx|tsx|playwright|vitest|jest|tsc|pytest|python|gradle|mvn|docker|kubectl|aws|curl|wget|make|sh|bash.*-c)([[:space:]]|$)|(^|[[:space:]])(go test|cargo test)([[:space:]]|$)'; then
      echo "busy:background-terminal"
      return
    fi
    # No active child processes — background terminal indicator is stale, fall through
  fi

  # Snapshot-diff: if content is actively changing, terminal is busy.
  # Strip volatile lines (timer counters, progress bars, % left) that change every second
  # but don't indicate real work — prevents false "busy:content-changing" on phantom bg terminals.
  local snap1 snap2
  local strip_volatile='/(Working \(|Waiting for|esc to interrupt|% left|background terminal|·.*running)/d'
  snap1=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | sed -E "$strip_volatile" | md5sum | cut -d' ' -f1)
  sleep 3
  snap2=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | sed -E "$strip_volatile" | md5sum | cut -d' ' -f1)
  if [[ "$snap1" != "$snap2" ]]; then
    echo "busy:content-changing"
    return
  fi

  # Process-tree runners are busy regardless of prompt cosmetics.
  pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}')
  sid=$(ps -o sid= -p "$pane_pid" | tr -d ' ')
  tree=$(ps -o stat=,comm=,args= --forest -g "$sid" 2>/dev/null || true)
  if printf '%s\n' "$tree" | grep -Eiq '(^|[[:space:]])(pnpm|npm|npx|tsx|playwright|vitest|jest|tsc|pytest|python|gradle|mvn|docker|kubectl|aws|curl|wget|make)([[:space:]]|$)|(^|[[:space:]])(go test|cargo test)([[:space:]]|$)'; then
    echo "busy:runner"
    return
  fi

  # Prompt check first — if prompt is definitively clean, terminal is idle
  # regardless of stale Working text in scrollback above the prompt.
  pstate=$(prompt_state "$pane_id")
  if [[ "$pstate" == "clean_prompt" ]]; then
    echo "idle:clean-prompt"
    return
  fi
  if [[ "$pstate" == "dirty_prompt" ]]; then
    echo "idle:dirty-prompt"
    return
  fi

  # Working indicator check: only reaches here if prompt is ambiguous.
  # If pane shows "Working (" in last 8 lines AND no clean prompt detected,
  # the terminal is actively processing. (8 lines to avoid matching stale scrollback)
  if printf '%s\n' "$pane_tail" | tail -8 | grep -Eiq 'Working \('; then
    echo "busy:working-indicator"
    return
  fi

  # UI markers can indicate work when prompt is not confidently detected.
  if printf '%s\n' "$pane_tail" | grep -Eiq '(Working \(|esc to interrupt|background terminal running|is running…|Effecting…|Drizzling\.\.\.|Cogitating|Prestidigitating|Cooking\.\.\.|Ruminating\.\.\.|Conjuring\.\.\.|Synthesizing|Thinking\.\.\.)'; then
    echo "busy:ui-marker"
    return
  fi

  echo "ambiguous:not-prompt"
}

is_terminal_busy(){
  local pane_id="$1"
  local r
  r=$(busy_reason "$pane_id")
  # Fail-closed: only idle:* is definitively not busy.
  # busy:* and ambiguous:* both count as busy to avoid interrupting mid-thought work.
  [[ "$r" != idle:* ]]
}

cc_line_count_tail(){
  local pane="$1"
  tmux capture-pane -t "$pane" -p | tail -60 | grep -Ec '^[[:space:]]*cc[[:space:]]*$' || true
}

prompt_state(){
  local pane="$1"
  local cy cx pline pline_norm

  cy=$(tmux display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null || echo "")
  cx=$(tmux display-message -p -t "$pane" '#{cursor_x}' 2>/dev/null || echo "")
  if [[ "$cy" =~ ^[0-9]+$ ]]; then
    pline=$(tmux capture-pane -t "$pane" -p | sed -n "$((cy+1))p" || true)
    # Cursor line may be a UI hint line below the prompt; ignore unless it is a prompt line.
    if ! printf '%s\n' "$pline" | grep -Eq '^[[:space:]]*(>|›|❯)'; then
      # Cursor might be on a wrapped continuation line below the prompt.
      # Scan upward (up to 10 lines) from cursor to find the actual prompt line.
      local scan_pline="" scan_i
      for scan_i in $(seq "$cy" -1 $((cy > 10 ? cy - 10 : 0))); do
        scan_pline=$(tmux capture-pane -t "$pane" -p | sed -n "$((scan_i + 1))p" || true)
        if printf '%s\n' "$scan_pline" | grep -Eq '^[[:space:]]*(>|›|❯)'; then
          pline="$scan_pline"
          break
        fi
      done
      # If no prompt found scanning up, pline stays empty
      [[ -z "$scan_pline" || "$pline" != "$scan_pline" ]] && pline=""
    fi
  else
    pline=""
  fi

  # No fallback scrollback scan — stale › glyphs in Codex output cause false "idle" detection.
  # If cursor isn't on a prompt line, we can't confirm idle state.

  if [[ -z "$pline" ]]; then
    echo "not_prompt"
    return
  fi

  pline_norm=$(printf '%s' "$pline" | tr '\302\240' ' ')

  # Clean prompt: cursor is on a line with only the prompt glyph.
  # Check the 3 lines immediately above cursor for ACTIVE work indicators.
  # If Working/esc-to-interrupt is within 5 lines of cursor, terminal is working
  # even though cursor is on prompt. If not, terminal is genuinely idle.
  if printf '%s\n' "$pline_norm" | grep -Eq '^[[:space:]]*(>|›|❯)[[:space:]]*$'; then
    # Check 5 lines above cursor for active work
    local above_cursor=""
    if [[ "$cy" =~ ^[0-9]+$ ]] && (( cy >= 5 )); then
      above_cursor=$(tmux capture-pane -t "$pane" -p 2>/dev/null | sed -n "$((cy-4)),$((cy))p")
    fi
    if printf '%s\n' "$above_cursor" | grep -Eiq '(Working \(|esc to interrupt|Messages to be submitted|Waiting for background terminal)'; then
      echo "not_prompt"
      return
    fi
    echo "clean_prompt"
    return
  fi

  # Cursor anchored at prompt column in some CLIs can show ghost/suggestion text on same line.
  if [[ "$cx" =~ ^[0-9]+$ ]] && [[ "$cx" -le 2 ]] && printf '%s\n' "$pline_norm" | grep -Eq '^[[:space:]]*(>|›|❯)[[:space:]]+.+$'; then
    echo "clean_prompt"
    return
  fi

  # Dirty prompt: prompt glyph followed by user-entered text.
  if printf '%s\n' "$pline_norm" | grep -Eq '^[[:space:]]*(>|›|❯)[[:space:]]+.+$'; then
    echo "dirty_prompt"
    return
  fi

  echo "not_prompt"
}

wait_for_prompt_ready(){
  local pane="$1"
  local tries="${2:-20}"
  local i=0
  while [[ "$i" -lt "$tries" ]]; do
    if ! is_terminal_busy "$pane"; then
      case "$(prompt_state "$pane")" in
        clean_prompt) return 0 ;;
        dirty_prompt) return 2 ;;
      esac
    fi
    i=$((i+1))
    sleep 0.15
  done
  return 1
}

clear_dirty_prompt_buffer(){
  local pane="$1"
  tmux send-keys -t "$pane" C-u
  sleep 0.10
  local s
  s=$(prompt_state "$pane")
  [[ "$s" == "clean_prompt" ]]
}

send_tmux_text_enter(){
  local target="$1"; shift
  local txt="$*"

  # Carbon-copy behavior: literal text send, then Enter (no extra guard/flush logic).
  tmux send-keys -t "$target" -l -- "$txt"
  sleep 0.10
  tmux send-keys -t "$target" Enter
  sleep 0.12

  return 0
}

RATE_LIMIT_STATE_FILE="${RATE_LIMIT_STATE_FILE:-$HOME/.openclaw/workspace/cli-rate-limit-state.json}"

cli_fallback(){
  local preferred="$1"
  case "$preferred" in
    cc)  echo "cdx" ;;
    cdx) echo "cc" ;;
    *)   echo "" ;;
  esac
}

# Check persisted rate-limit state file. Returns 0 if cli is rate-limited, 1 if not.
is_cli_rate_limited(){
  local cli="$1"
  local now limited resets_at
  [[ -f "$RATE_LIMIT_STATE_FILE" ]] || return 1
  limited=$(grep -o "\"$cli\"[^}]*}" "$RATE_LIMIT_STATE_FILE" | grep -o '"limited":[^,}]*' | head -1 | sed 's/.*://' | tr -d ' ')
  [[ "$limited" == "true" ]] || return 1
  resets_at=$(grep -o "\"$cli\"[^}]*}" "$RATE_LIMIT_STATE_FILE" | grep -o '"resets_at":[^,}]*' | head -1 | sed 's/.*://' | tr -d ' ')
  now=$(date +%s)
  if [[ -n "$resets_at" && "$resets_at" != "null" && "$now" -ge "$resets_at" ]]; then
    # Expired — clear the flag
    mark_cli_rate_limit_clear "$cli"
    return 1
  fi
  return 0
}

# Detect rate limit from pane output and persist it.
detect_and_persist_rate_limit(){
  local pane="$1"
  local tail reset_msg cli_hit=""
  tail=$(tmux capture-pane -t "$pane" -p -S -200 | tail -60)

  if printf '%s\n' "$tail" | grep -Eiq "You've hit your usage limit|usage limit.*codex|purchase more credits"; then
    cli_hit="cdx"
  elif printf '%s\n' "$tail" | grep -Eiq "rate limit|capacity|overloaded.*claude|Claude.*rate.limit|credit balance"; then
    cli_hit="cc"
  fi

  if [[ -z "$cli_hit" ]]; then
    echo "none"
    return 0
  fi

  # Try to parse reset time from message
  reset_msg=$(printf '%s\n' "$tail" | grep -Eio "try again at [^.]*" | head -1 || true)
  local resets_at="null"
  if [[ -n "$reset_msg" ]]; then
    # Attempt date parse; fall back to +4 days if unparseable
    resets_at=$(date -d "${reset_msg#try again at }" +%s 2>/dev/null || echo "null")
  fi
  [[ "$resets_at" == "null" ]] && resets_at=$(( $(date +%s) + 345600 ))

  mark_cli_rate_limit_set "$cli_hit" "$resets_at" "$reset_msg"
  echo "$cli_hit"
  return 0
}

mark_cli_rate_limit_set(){
  local cli="$1" resets_at="$2" message="${3:-}"
  local now
  now=$(date +%s)
  local other
  other=$(cli_fallback "$cli")
  # Read other's current state
  local other_block="{\"limited\": false, \"detected_at\": null, \"resets_at\": null, \"message\": null}"
  if [[ -f "$RATE_LIMIT_STATE_FILE" ]]; then
    local other_limited
    other_limited=$(grep -o "\"$other\"[^}]*}" "$RATE_LIMIT_STATE_FILE" | head -1 || true)
    [[ -n "$other_limited" ]] && other_block="\"$other\": {$( echo "$other_limited" | sed "s/\"$other\"//" | tr -d '{}' )}" && other_block="{$(echo "$other_limited")}"
  fi
  cat > "$RATE_LIMIT_STATE_FILE" <<EOF
{
  "$cli": {"limited": true, "detected_at": $now, "resets_at": $resets_at, "message": "$message"},
  "$other": $(if [[ -f "$RATE_LIMIT_STATE_FILE" ]]; then grep -o "\"$other\"[[:space:]]*:[^}]*}" "$RATE_LIMIT_STATE_FILE" | sed "s/\"$other\"://" | head -1 || echo '{"limited": false, "detected_at": null, "resets_at": null, "message": null}'; else echo '{"limited": false, "detected_at": null, "resets_at": null, "message": null}'; fi)
}
EOF
  log_guard "RATE_LIMIT_PERSISTED:$cli resets_at=$resets_at"
}

mark_cli_rate_limit_clear(){
  local cli="$1"
  [[ -f "$RATE_LIMIT_STATE_FILE" ]] || return 0
  local tmp
  tmp=$(cat "$RATE_LIMIT_STATE_FILE")
  # Simple: rewrite the cli block with limited=false
  printf '%s\n' "$tmp" | sed "s/\"$cli\"[[:space:]]*:[[:space:]]*{[^}]*}/\"$cli\": {\"limited\": false, \"detected_at\": null, \"resets_at\": null, \"message\": null}/" > "$RATE_LIMIT_STATE_FILE"
  log_guard "RATE_LIMIT_CLEARED:$cli"
}

ensure_cli(){
  local pane="$1"
  local preferred="$2"
  local fallback mode pane_cmd

  fallback=$(cli_fallback "$preferred")

  # Check persisted rate-limit state FIRST — no guessing from scrollback
  if is_cli_rate_limited "$preferred"; then
    if [[ -n "$fallback" ]]; then
      log_guard "RATE_LIMITED_PERSISTED:$preferred, using $fallback"
      mode=$(mode_from_tree "$pane")
      pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
      # Already on fallback and running? Done.
      if [[ "$mode" == "$fallback" && "$pane_cmd" != "bash" ]]; then
        log_guard "ALREADY_ON_FALLBACK:$fallback"
        return 0
      fi
      # Need to switch to fallback
      if [[ "$pane_cmd" != "bash" ]]; then
        tmux send-keys -t "$pane" C-c
        sleep 0.5
      fi
      send_tmux_text_enter "$pane" "$fallback" || { log_guard "BLOCKED:fallback-launch-failed ($fallback)"; return 1; }
      sleep 1
      mode=$(mode_from_tree "$pane")
      pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
      if [[ "$mode" == "$fallback" && "$pane_cmd" != "bash" ]]; then
        log_guard "FALLBACK_OK:$fallback"
        return 0
      fi
      log_guard "BLOCKED:fallback-verify-failed (mode=$mode pane_cmd=$pane_cmd)"
      return 1
    fi
    log_guard "BLOCKED:preferred-rate-limited-no-fallback ($preferred)"
    return 1
  fi

  # Check if fallback is also rate-limited (both dead)
  if [[ -n "$fallback" ]] && is_cli_rate_limited "$fallback"; then
    # Preferred is not limited, fallback is — just use preferred normally
    :
  fi

  mode=$(mode_from_tree "$pane")
  pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')

  # Already running preferred and not at bash → good
  if [[ "$mode" == "$preferred" && "$pane_cmd" != "bash" ]]; then
    return 0
  fi

  # Already running fallback → switch to preferred (since preferred is not rate-limited)
  if [[ "$mode" == "$fallback" && "$pane_cmd" != "bash" ]]; then
    tmux send-keys -t "$pane" C-c
    sleep 0.5
    send_tmux_text_enter "$pane" "$preferred" || { log_guard "BLOCKED:preferred-launch-failed ($preferred)"; return 1; }
    sleep 1
    mode=$(mode_from_tree "$pane")
    pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
    if [[ "$mode" == "$preferred" && "$pane_cmd" != "bash" ]]; then
      return 0
    fi
    # Maybe hit rate limit on launch
    local hit
    hit=$(detect_and_persist_rate_limit "$pane")
    if [[ "$hit" == "$preferred" && -n "$fallback" ]]; then
      log_guard "RATE_LIMITED:$preferred on launch, switching to $fallback"
      tmux send-keys -t "$pane" C-c
      sleep 0.5
      send_tmux_text_enter "$pane" "$fallback" || { log_guard "BLOCKED:fallback-launch-failed ($fallback)"; return 1; }
      sleep 1
      mode=$(mode_from_tree "$pane")
      pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
      if [[ "$mode" == "$fallback" && "$pane_cmd" != "bash" ]]; then
        log_guard "FALLBACK_OK:$fallback"
        return 0
      fi
      log_guard "BLOCKED:fallback-verify-failed (mode=$mode pane_cmd=$pane_cmd)"
      return 1
    fi
    log_guard "BLOCKED:preferred-verify-failed (mode=$mode pane_cmd=$pane_cmd)"
    return 1
  fi

  # At bash or unknown — try preferred
  send_tmux_text_enter "$pane" "$preferred" || { log_guard "BLOCKED:preferred-launch-failed ($preferred)"; return 1; }
  sleep 1
  mode=$(mode_from_tree "$pane")
  pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
  if [[ "$mode" == "$preferred" && "$pane_cmd" != "bash" ]]; then
    return 0
  fi

  # Check if we just hit a rate limit on launch
  local hit
  hit=$(detect_and_persist_rate_limit "$pane")
  if [[ "$hit" == "$preferred" && -n "$fallback" ]]; then
    log_guard "RATE_LIMITED:$preferred on launch, switching to $fallback"
    tmux send-keys -t "$pane" C-c
    sleep 0.5
    send_tmux_text_enter "$pane" "$fallback" || { log_guard "BLOCKED:fallback-launch-failed ($fallback)"; return 1; }
    sleep 1
    mode=$(mode_from_tree "$pane")
    pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
    if [[ "$mode" == "$fallback" && "$pane_cmd" != "bash" ]]; then
      log_guard "FALLBACK_OK:$fallback"
      return 0
    fi
    log_guard "BLOCKED:fallback-verify-failed (mode=$mode pane_cmd=$pane_cmd)"
    return 1
  fi

  log_guard "BLOCKED:cli-launch-failed (preferred=$preferred mode=$mode pane_cmd=$pane_cmd)"
  return 1
}

auto_disable_prci_if_manual_on(){
  local manual_unit="$1"
  local _cron_id="$2"
  local conflict_tag="$3"

  if ta_unit_on "$manual_unit"; then
    log_guard "NOOP:manual-mode"
    log_guard "$conflict_tag"
    return 0
  fi

  return 1
}
