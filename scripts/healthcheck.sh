#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/Desktop/axon/watcher-state.json"
SUMMARY_FILE="$HOME/Desktop/axon/health-summary.json"
MAX_AGE_S="${AXON_MAX_STATE_AGE_S:-300}"

declare -A EXPECTED_UNIT_FILE_STATE=(
  [watcher.timer]="enabled"
  [agent-terminal-starthub.timer]="masked"
)

failures=0

ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

unit_state() {
  systemctl --user show "$1" --property=ActiveState --value 2>/dev/null || echo unknown
}

unit_file_state() {
  systemctl --user show "$1" --property=UnitFileState --value 2>/dev/null || echo unknown
}

check_unit_policy() {
  local unit="$1"
  local load_state="$2"
  local file_state="$3"
  local active_state="$4"
  local expected="${EXPECTED_UNIT_FILE_STATE[$unit]:-}"

  if [[ "$load_state" != "loaded" && "$load_state" != "masked" ]]; then
    fail "$unit load=$load_state unit_file_state=$file_state active=$active_state"
    return
  fi

  if [[ -n "$expected" && "$file_state" != "$expected" ]]; then
    fail "$unit policy expected=$expected actual=$file_state active=$active_state"
    return
  fi

  ok "$unit load=$load_state unit_file_state=$file_state active=$active_state"
}

printf 'OpenClaw health check\n'

watcher_timer_active="$(unit_state watcher.timer)"
watcher_timer_enabled="$(unit_file_state watcher.timer)"
check_unit_policy watcher.timer loaded "$watcher_timer_enabled" "$watcher_timer_active"

if [[ "$watcher_timer_active" != "active" ]]; then
  fail "watcher.timer active=$watcher_timer_active"
fi

if [[ -f "$STATE_FILE" ]]; then
  ok "state file present: $STATE_FILE"
else
  fail "state file missing: $STATE_FILE"
fi

if [[ -f "$STATE_FILE" ]]; then
  state_summary="$(python3 - "$STATE_FILE" "$MAX_AGE_S" <<'PY'
import json
import sys
import time

state_path = sys.argv[1]
max_age = int(sys.argv[2])

with open(state_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

epoch = int(data.get('epoch', 0))
age = int(time.time()) - epoch if epoch else 10**9
heartbeat = data.get('crons', {}).get('heartbeat', 'missing')
units_ok = data.get('units_ok', False)
missing_units = data.get('missing_units', '')
repos = data.get('repos', {})
nixelo = repos.get('nixelo', {})
starthub = repos.get('starthub', {})

print(f"age={age}")
print(f"heartbeat={heartbeat}")
print(f"units_ok={str(units_ok).lower()}")
print(f"missing_units={missing_units}")
print(f"fresh={'true' if age <= max_age else 'false'}")
print(f"nixelo_mode={nixelo.get('mode', 'missing')}")
print(f"nixelo_alerts={nixelo.get('alerts', 'missing')}")
print(f"nixelo_manual={nixelo.get('manual_timer', 'missing')}/{nixelo.get('manual_enabled', 'missing')}")
print(f"nixelo_agent={nixelo.get('agent_timer', 'missing')}/{nixelo.get('agent_enabled', 'missing')}")
print(f"starthub_mode={starthub.get('mode', 'missing')}")
print(f"starthub_alerts={starthub.get('alerts', 'missing')}")
print(f"starthub_manual={starthub.get('manual_timer', 'missing')}/{starthub.get('manual_enabled', 'missing')}")
print(f"starthub_agent={starthub.get('agent_timer', 'missing')}/{starthub.get('agent_enabled', 'missing')}")
PY
)"

  state_age="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("age","unknown"))')"
  state_heartbeat="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("heartbeat","missing"))')"
  state_units_ok="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("units_ok","false"))')"
  state_missing_units="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("missing_units",""))')"
  state_fresh="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("fresh","false"))')"
  nixelo_mode="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("nixelo_mode","missing"))')"
  nixelo_alerts="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("nixelo_alerts","missing"))')"
  nixelo_manual="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("nixelo_manual","missing"))')"
  nixelo_agent="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("nixelo_agent","missing"))')"
  starthub_mode="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("starthub_mode","missing"))')"
  starthub_alerts="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("starthub_alerts","missing"))')"
  starthub_manual="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("starthub_manual","missing"))')"
  starthub_agent="$(printf '%s\n' "$state_summary" | python3 -c 'import sys; d=dict(line.strip().split("=",1) for line in sys.stdin if "=" in line); print(d.get("starthub_agent","missing"))')"

  if [[ "$state_fresh" == "true" ]]; then
    ok "watcher-state freshness age=${state_age}s"
  else
    fail "watcher-state stale age=${state_age}s max=${MAX_AGE_S}s"
  fi

  if [[ "$state_heartbeat" == "ok" ]]; then
    ok "watcher-state heartbeat=$state_heartbeat"
  else
    fail "watcher-state heartbeat=$state_heartbeat"
  fi

  if [[ "$state_units_ok" == "true" ]]; then
    ok "watcher-state units_ok=true"
  else
    fail "watcher-state units_ok=false missing_units=$state_missing_units"
  fi

  printf 'Summary nixelo  mode=%s alerts=%s manual=%s agent=%s\n' "$nixelo_mode" "$nixelo_alerts" "$nixelo_manual" "$nixelo_agent"
  printf 'Summary starthub mode=%s alerts=%s manual=%s agent=%s\n' "$starthub_mode" "$starthub_alerts" "$starthub_manual" "$starthub_agent"
fi

cron_summary="$(openclaw cron list --all --json 2>/dev/null | python3 -c 'import json, sys
data = json.load(sys.stdin)
jobs = {job.get("name"): job for job in data.get("jobs", [])}
for name in ("Heartbeat", "pr-ci-nixelo", "pr-ci-starthub"):
    state = jobs.get(name, {}).get("state", {})
    enabled = jobs.get(name, {}).get("enabled")
    status = state.get("lastStatus", "never")
    running = "true" if "runningAtMs" in state else "false"
    print(f"{name}|enabled={str(enabled).lower()}|status={status}|running={running}")')"

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  name="${line%%|*}"
  payload="${line#*|}"
  enabled="$(printf '%s\n' "$payload" | python3 -c 'import sys; d=dict(part.split("=",1) for part in sys.stdin.read().strip().split("|") if "=" in part); print(d.get("enabled","unknown"))')"
  status="$(printf '%s\n' "$payload" | python3 -c 'import sys; d=dict(part.split("=",1) for part in sys.stdin.read().strip().split("|") if "=" in part); print(d.get("status","unknown"))')"
  running="$(printf '%s\n' "$payload" | python3 -c 'import sys; d=dict(part.split("=",1) for part in sys.stdin.read().strip().split("|") if "=" in part); print(d.get("running","false"))')"

  if [[ "$name" == "Heartbeat" ]]; then
    if [[ "$status" == "ok" || "$running" == "true" ]]; then
      ok "$name enabled=$enabled status=$status running=$running"
    else
      fail "$name enabled=$enabled status=$status running=$running"
    fi
  else
    if [[ "$status" == "error" || "$status" == "not_found" || "$status" == "unknown" ]]; then
      fail "$name enabled=$enabled status=$status running=$running"
    else
      ok "$name enabled=$enabled status=$status running=$running"
    fi
  fi
done <<< "$cron_summary"

for unit in manual-terminal-nixelo.timer manual-terminal-starthub.timer agent-terminal-nixelo.timer agent-terminal-starthub.timer; do
  load_state="$(systemctl --user show "$unit" --property=LoadState --value 2>/dev/null || echo not-found)"
  file_state="$(unit_file_state "$unit")"
  active_state="$(unit_state "$unit")"
  check_unit_policy "$unit" "$load_state" "$file_state" "$active_state"
done

if (( failures > 0 )); then
  python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys

summary_path = sys.argv[1]
summary = {
    "schema_version": 1,
    "ok": False,
    "failures": True,
}

with open(summary_path, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2)
    f.write('\n')
PY
  printf 'RESULT fail count=%s\n' "$failures"
  exit 1
fi

python3 - "$STATE_FILE" "$SUMMARY_FILE" "$MAX_AGE_S" <<'PY'
import json
import sys
import time

state_path = sys.argv[1]
summary_path = sys.argv[2]
max_age = int(sys.argv[3])

with open(state_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

epoch = int(data.get('epoch', 0))
age = int(time.time()) - epoch if epoch else None
repos = data.get('repos', {})

summary = {
    "schema_version": 1,
    "ok": True,
    "generated_from": state_path,
    "generated_at_epoch": int(time.time()),
    "watcher": {
        "timestamp": data.get('timestamp'),
        "age_s": age,
        "fresh": age is not None and age <= max_age,
        "units_ok": bool(data.get('units_ok', False)),
        "missing_units": data.get('missing_units', ''),
    },
    "crons": data.get('crons', {}),
    "repos": {
        name: {
            "mode": repo.get('mode'),
            "alerts": repo.get('alerts'),
            "manual_timer": repo.get('manual_timer'),
            "manual_enabled": repo.get('manual_enabled'),
            "agent_timer": repo.get('agent_timer'),
            "agent_enabled": repo.get('agent_enabled'),
            "service_health": repo.get('service_health'),
            "at_prompt": repo.get('at_prompt'),
        }
        for name, repo in repos.items()
    }
}

with open(summary_path, 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2)
    f.write('\n')
PY

ok "wrote summary json: $SUMMARY_FILE"

printf 'RESULT ok\n'
