#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/Desktop/axon/watcher-state.json"

printf 'OpenClaw recent\n'

if [[ ! -f "$STATE_FILE" ]]; then
  printf 'missing watcher state: %s\n' "$STATE_FILE"
  exit 1
fi

python3 - "$STATE_FILE" <<'PY'
import json
import sys
import time

state_path = sys.argv[1]
with open(state_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

epoch = int(data.get('epoch', 0))
age = int(time.time()) - epoch if epoch else None

print(f"watcher timestamp={data.get('timestamp')} age_s={age}")
crons = data.get('crons', {})
print(
    "crons "
    f"heartbeat={crons.get('heartbeat', 'missing')} "
    f"pr_ci_nixelo={crons.get('pr_ci_nixelo', 'missing')} "
    f"pr_ci_starthub={crons.get('pr_ci_starthub', 'missing')}"
)

for repo_name in ('nixelo', 'starthub'):
    repo = data.get('repos', {}).get(repo_name, {})
    print(
        f"repo {repo_name} "
        f"mode={repo.get('mode', 'missing')} "
        f"alerts={repo.get('alerts', 'missing')} "
        f"manual={repo.get('manual_timer', 'missing')}/{repo.get('manual_enabled', 'missing')} "
        f"agent={repo.get('agent_timer', 'missing')}/{repo.get('agent_enabled', 'missing')} "
        f"service={repo.get('service_health', 'missing')}"
    )
PY

heartbeat_line="$(openclaw cron list --all 2>/dev/null | python3 -c 'import sys
for line in sys.stdin:
    if "Heartbeat" in line:
        print(" ".join(line.split()))
        break')"

if [[ -n "$heartbeat_line" ]]; then
  printf 'heartbeat cron %s\n' "$heartbeat_line"
else
  printf 'heartbeat cron missing\n'
fi
