#!/usr/bin/env bash
# watcher.sh — Deterministic health checker for terminal automation.
# Runs every 1-2 min via systemd timer. No AI, no judgment, no tmux input.
# Outputs structured JSON to STATE_FILE for the heartbeat AI to read.
# YO — DO NOT MODIFY THIS FILE UNLESS EXPLICITLY REQUESTED BY THE USER.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$HOME/Desktop/axon/watcher-state.json"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH=$(date +%s)

# --- Config ---
declare -A REPO_PATH=( [nixelo]="$HOME/Desktop/nixelo" [starthub]="$HOME/Desktop/StartHub" )
declare -A REPO_TMUX=( [nixelo]="nixelo" [starthub]="starthub" )
declare -A REPO_MANUAL_TIMER=( [nixelo]="manual-terminal-nixelo.timer" [starthub]="manual-terminal-starthub.timer" )
declare -A REPO_AGENT_TIMER=( [nixelo]="agent-terminal-nixelo.timer" [starthub]="agent-terminal-starthub.timer" )
declare -A REPO_PRCI_CRON=( [nixelo]="pr-ci-nixelo" [starthub]="pr-ci-starthub" )
STALE_MINUTES=120

# --- Helpers ---
json_str() { printf '%s' "$1" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || printf '"%s"' "$1"; }
timer_state() { local r; r=$(systemctl --user is-active "$1" 2>/dev/null) || r="inactive"; echo "${r%%$'\n'*}"; }
timer_enabled() {
  local r
  r=$(systemctl --user show "$1" --property=UnitFileState --value 2>/dev/null || echo "unknown")
  [[ -n "$r" ]] || r="unknown"
  echo "${r%%$'\n'*}"
}

service_stuck() {
  local svc="$1"
  local state
  state=$(systemctl --user show "$svc" --property=ActiveState --value 2>/dev/null || echo "unknown")
  if [[ "$state" == "activating" ]]; then
    local since_epoch
    since_epoch=$(systemctl --user show "$svc" --property=ExecMainStartTimestampMonotonic --value 2>/dev/null || echo "0")
    # Check if service has been activating for more than 5 minutes
    local active_since
    active_since=$(systemctl --user show "$svc" --property=ActiveEnterTimestamp --value 2>/dev/null || echo "")
    if [[ -n "$active_since" && "$active_since" != "n/a" ]]; then
      local active_epoch
      active_epoch=$(date -d "$active_since" +%s 2>/dev/null || echo "0")
      local elapsed=$(( EPOCH - active_epoch ))
      if (( elapsed > 300 )); then
        echo "stuck:${elapsed}s"
        return
      fi
    fi
    echo "activating"
    return
  fi
  echo "ok"
}

last_sent_age() {
  local svc="$1"
  local last_sent
  last_sent=$(journalctl --user -u "$svc" --since "-60min" --no-pager 2>/dev/null | grep "SENT" | tail -1 | awk '{print $1" "$2" "$3}')
  if [[ -z "$last_sent" ]]; then
    echo "none_in_60min"
    return
  fi
  local sent_epoch
  sent_epoch=$(date -d "$last_sent" +%s 2>/dev/null || echo "0")
  local age=$(( EPOCH - sent_epoch ))
  echo "${age}s"
}

nudge_stats_10min() {
  local svc="$1"
  local sent noop
  sent=$(journalctl --user -u "$svc" --since "-10min" --no-pager 2>/dev/null | grep -c "SENT" || true)
  sent="${sent:-0}"; sent="$(echo "$sent" | tr -dc '0-9' | head -c5)"; sent="${sent:-0}"
  noop=$(journalctl --user -u "$svc" --since "-10min" --no-pager 2>/dev/null | grep -c "NOOP" || true)
  noop="${noop:-0}"; noop="$(echo "$noop" | tr -dc '0-9' | head -c5)"; noop="${noop:-0}"
  echo "${sent}:${noop}"
}

tmux_check() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "missing"
    return
  fi
  local pane
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n1)
  local pane_cmd
  pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || echo "unknown")
  echo "$pane_cmd"
}

process_tree_mode() {
  local session="$1"
  local pane
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n1)
  [[ -n "$pane" ]] || { echo "no_pane"; return; }
  local pid
  pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || echo "")
  [[ -n "$pid" ]] || { echo "no_pid"; return; }
  local sid
  sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$sid" ]] || { echo "no_sid"; return; }
  local tree
  tree=$(ps -o args= --forest -g "$sid" 2>/dev/null || echo "")

  if echo "$tree" | grep -q "codex"; then
    echo "cdx"
  elif echo "$tree" | grep -q "claude"; then
    echo "cc"
  elif echo "$tree" | grep -q "node"; then
    echo "node_unknown"
  else
    echo "bash"
  fi
}

has_child_runners() {
  local session="$1"
  local pane
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}' 2>/dev/null | head -n1)
  [[ -n "$pane" ]] || { echo "no_pane"; return; }
  local pid
  pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || echo "")
  [[ -n "$pid" ]] || { echo "false"; return; }
  local sid
  sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$sid" ]] || { echo "false"; return; }
  local tree
  tree=$(ps -o comm= --forest -g "$sid" 2>/dev/null || echo "")
  local runner_count
  runner_count="$(printf '%s\n' "$tree" | grep -Eic '(pnpm|npm|npx|tsx|playwright|vitest|jest|tsc|pytest|python|gradle|mvn|docker|kubectl|make)' || true)"
  runner_count="${runner_count:-0}"
  runner_count="$(echo "$runner_count" | tr -dc '0-9' | head -c5)"
  runner_count="${runner_count:-0}"
  if [[ "$runner_count" -gt 0 ]] 2>/dev/null; then
    echo "true:${runner_count}"
  else
    echo "false"
  fi
}


pane_at_prompt() {
  local session="$1"
  local tail5
  tail5=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -5)
  # Check for Codex prompt (›) or Claude Code prompt (❯)
  if echo "$tail5" | grep -Eq '^[[:space:]]*(›|❯)[[:space:]]'; then
    echo "true"
  else
    echo "false"
  fi
}

commit_age_seconds() {
  local repo="$1"
  local ct
  ct=$(git -C "$repo" log -1 --format="%ct" 2>/dev/null || echo "0")
  echo $(( EPOCH - ct ))
}

commit_info() {
  local repo="$1"
  git -C "$repo" log -1 --format="%h|%s" 2>/dev/null || echo "unknown|unknown"
}

open_pr_count() {
  local slug="$1"
  local branch="$2"
  gh pr list --repo "$slug" --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo "ERR"
}

cron_health() {
  local cron_name="$1"
  # Search cron list output for the cron by name
  local line
  line=$(openclaw cron list --all 2>/dev/null | grep -i "$cron_name" || echo "")
  if [[ -z "$line" ]]; then
    echo "not_found"
    return
  fi
  if echo "$line" | grep -q "error"; then
    echo "error"
  elif echo "$line" | grep -q "disabled"; then
    echo "disabled"
  elif echo "$line" | grep -q "ok\|running"; then
    echo "ok"
  else
    echo "unknown"
  fi
}

conflict_check() {
  local repo="$1"
  local manual_active agent_active prci_enabled
  manual_active=$(timer_state "${REPO_MANUAL_TIMER[$repo]}")
  agent_active=$(timer_state "${REPO_AGENT_TIMER[$repo]}")
  prci_enabled=$(cron_health "${REPO_PRCI_CRON[$repo]}")

  local active_count=0
  [[ "$manual_active" == "active" ]] && (( active_count++ ))
  [[ "$agent_active" == "active" ]] && (( active_count++ ))
  [[ "$prci_enabled" == "ok" ]] && (( active_count++ ))

  if (( active_count > 1 )); then
    echo "CONFLICT:${manual_active}/${agent_active}/${prci_enabled}"
  else
    echo "clean"
  fi
}

# --- Unit file existence check ---
unit_check() {
  local unit="$1"
  local loaded
  loaded=$(systemctl --user show "$unit" --property=LoadState --value 2>/dev/null || echo "not-found")
  echo "$loaded"
}

# --- Build per-repo status ---
repo_status() {
  local repo="$1"
  local session="${REPO_TMUX[$repo]}"
  local path="${REPO_PATH[$repo]}"
  local manual_timer="${REPO_MANUAL_TIMER[$repo]}"
  local manual_service="${manual_timer%.timer}.service"
  local agent_timer="${REPO_AGENT_TIMER[$repo]}"

  local tmux_cmd; tmux_cmd=$(tmux_check "$session")
  local mode; mode=$(process_tree_mode "$session")
  local children; children=$(has_child_runners "$session")
  local at_prompt; at_prompt=$(pane_at_prompt "$session")
  local commit_age; commit_age=$(commit_age_seconds "$path")
  local commit; commit=$(commit_info "$path")
  local manual_state; manual_state=$(timer_state "$manual_timer")
  local manual_enabled; manual_enabled=$(timer_enabled "$manual_timer")
  local agent_state; agent_state=$(timer_state "$agent_timer")
  local agent_enabled; agent_enabled=$(timer_enabled "$agent_timer")
  local svc_health; svc_health=$(service_stuck "$manual_service")
  local conflict; conflict=$(conflict_check "$repo")

  # Nudge delivery (only relevant if manual timer is active)
  local sent_noop="n/a"
  local last_sent="n/a"
  if [[ "$manual_state" == "active" ]]; then
    sent_noop=$(nudge_stats_10min "$manual_service")
    last_sent=$(last_sent_age "$manual_service")
  fi

  local stale="false"
  if (( commit_age > STALE_MINUTES * 60 )); then
    stale="true"
  fi

  # Idle + no nudge detection (hard gate)
  local idle_no_nudge="false"
  if [[ "$manual_state" == "active" && "$at_prompt" == "true" ]]; then
    local sent_count="${sent_noop%%:*}"
    if [[ "$sent_count" == "0" ]]; then
      idle_no_nudge="true"
    fi
  fi

  # Build alerts
  local alerts=""
  [[ "$svc_health" == stuck:* ]] && alerts="${alerts}SERVICE_STUCK,"
  [[ "$stale" == "true" && "$at_prompt" == "true" ]] && alerts="${alerts}STALE_AND_IDLE,"
  [[ "$idle_no_nudge" == "true" ]] && alerts="${alerts}IDLE_NO_NUDGE,"
  [[ "$conflict" == CONFLICT:* ]] && alerts="${alerts}CONFLICT,"
  [[ "$tmux_cmd" == "missing" ]] && alerts="${alerts}TMUX_MISSING,"
  alerts="${alerts%,}"  # strip trailing comma
  [[ -z "$alerts" ]] && alerts="none"

  cat <<REPO_JSON
    "${repo}": {
      "tmux": "${tmux_cmd}",
      "mode": "${mode}",
      "child_runners": "${children}",
      "at_prompt": ${at_prompt},
      "commit_age_s": ${commit_age},
      "commit": $(json_str "$commit"),
      "stale": ${stale},
      "manual_timer": "${manual_state}",
      "manual_enabled": "${manual_enabled}",
      "agent_timer": "${agent_state}",
      "agent_enabled": "${agent_enabled}",
      "service_health": "${svc_health}",
      "nudge_sent_noop_10m": "${sent_noop}",
      "last_sent_age": "${last_sent}",
      "idle_no_nudge": ${idle_no_nudge},
      "conflict": "${conflict}",
      "alerts": "${alerts}"
    }
REPO_JSON
}

# --- Cron health ---
heartbeat_cron=$(cron_health "Heartbeat")
prci_nixelo=$(cron_health "pr-ci-nixelo")
prci_starthub=$(cron_health "pr-ci-starthub")

# --- Unit existence check ---
units_ok="true"
missing_units=""
for unit in manual-terminal-nixelo.timer manual-terminal-starthub.timer agent-terminal-nixelo.timer agent-terminal-starthub.timer; do
  load=$(unit_check "$unit")
  if [[ "$load" == "not-found" ]]; then
    units_ok="false"
    missing_units="${missing_units}${unit},"
  fi
done
missing_units="${missing_units%,}"

# --- Nixelo PR status (if pr-ci is on) ---
nixelo_pr="n/a"
nixelo_branch="n/a"
if [[ "$prci_nixelo" == "ok" ]]; then
  nixelo_branch=$(git -C "${REPO_PATH[nixelo]}" branch --show-current 2>/dev/null || echo "unknown")
  local_pr_count=$(open_pr_count "NixeloApp/nixelo" "$nixelo_branch")
  nixelo_pr="count:${local_pr_count}"
fi

# --- Build output ---
nixelo_status=$(repo_status "nixelo")
starthub_status=$(repo_status "starthub")

# Collect all alerts
all_alerts=""
for repo in nixelo starthub; do
  repo_alerts=$(echo "$nixelo_status$starthub_status" | grep "\"alerts\"" | head -1)
done
# Just check if any repo has non-"none" alerts
has_alerts="false"
if echo "$nixelo_status" | grep '"alerts": "' | grep -qv '"none"'; then
  has_alerts="true"
fi
if echo "$starthub_status" | grep '"alerts": "' | grep -qv '"none"'; then
  has_alerts="true"
fi

cat > "$STATE_FILE" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "epoch": ${EPOCH},
  "crons": {
    "heartbeat": "${heartbeat_cron}",
    "pr_ci_nixelo": "${prci_nixelo}",
    "pr_ci_starthub": "${prci_starthub}"
  },
  "units_ok": ${units_ok},
  "missing_units": "${missing_units}",
  "nixelo_pr": "${nixelo_pr}",
  "nixelo_branch": "${nixelo_branch}",
  "repos": {
${nixelo_status},
${starthub_status}
  }
}
EOF

# Print summary to stdout for journalctl
echo "WATCHER:${TIMESTAMP} heartbeat=${heartbeat_cron} prci_nix=${prci_nixelo} prci_sh=${prci_starthub} units=${units_ok}"
for repo in nixelo starthub; do
  alerts=$(grep -A20 "\"${repo}\"" "$STATE_FILE" | grep '"alerts"' | head -1 | sed 's/.*: "//;s/".*//')
  echo "  ${repo}: alerts=${alerts}"
done

exit 0
