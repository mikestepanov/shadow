# OpenCode Controller

This folder is for the OpenCode-based controller and related automation.

Planned scope:
- machine-readable busy/idle detection
- safe prompt/command submission when idle
- scheduler-backed lane dispatch and cron control

Current goal:
- replace tmux-first automation with OpenCode-native control where possible
- keep the control contract small and explicit

Status:
- status/send/wait controller implemented
- OpenCode cron registry and queue-backed scheduler are live
- `opencode.service` owns the local HTTP runtime on `127.0.0.1:4096`
- Telegram notifications use `TELEGRAM_BOT_TOKEN`

Current commands:
- `node ./src/index.js status`
- `node ./src/index.js send 'your prompt here'`
- `node ./src/index.js safe-send 'your prompt here'`
- `node ./src/index.js safe-command review`
- `node ./src/index.js wait`
- `node ./src/index.js lanes`
- `node ./src/index.js lane-field manual starthub prompt`
- `node ./src/index.js lane-run manual starthub --title 'Greeting quick check-in'`
- `node ./src/index.js enqueue-lane manual starthub --title 'Greeting quick check-in'`
- `node ./src/index.js run-queue`
- `node ./src/index.js auto-cycle nixelo`
- `node ./src/index.js agent-ping starthub`
- `node ./src/index.js prci-ping starthub`
- `node ./src/index.js cron list --all --json`
- `node ./src/index.js cron enable c1ac22ab-b891-4b8f-bbdb-ea9fe9d0825c`
- `node ./src/index.js cron run 0347a94f-872c-4d3a-a583-81fb6758461d`

Targeting options:
- `--session <session-id>`
- `--title <title substring>`

Examples:
- `node ./src/index.js status --title 'Greeting quick check-in'`
- `node ./src/index.js safe-send --session ses_123 'continue'`

Behavior:
- talks to OpenCode over HTTP at `http://127.0.0.1:4096` by default
- override with `OPENCODE_BASE_URL`
- `safe-send` waits through `busy`, stops on `waiting_user`, and sends only when safe
- `safe-command` preflights the OpenCode command list before execution
- `lane-run` applies small policy presets for `manual`, `agent`, and `prci` lanes
- `enqueue-lane` and `run-queue` provide a file-backed retry queue for deferred runs
- `run-queue` also executes due OpenCode cron jobs before draining the lane queue
- `auto-cycle nixelo` reads the existing auto-mode gate and queues the next OpenCode lane
