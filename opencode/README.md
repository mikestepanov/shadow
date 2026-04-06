# OpenCode Controller

This folder is for the OpenCode-based controller and related automation.

Planned scope:
- machine-readable busy/idle detection
- safe prompt/command submission when idle
- optional scheduler and channel integrations

Current goal:
- replace tmux-first automation with OpenCode-native control where possible
- keep the control contract small and explicit

Status:
- minimal status/send/wait controller implemented

Current commands:
- `node ./src/index.js status`
- `node ./src/index.js send 'your prompt here'`
- `node ./src/index.js safe-send 'your prompt here'`
- `node ./src/index.js safe-command review`
- `node ./src/index.js wait`
- `node ./src/index.js lanes`
- `node ./src/index.js lane-run manual starthub --title 'Greeting quick check-in'`
- `node ./src/index.js enqueue-lane manual starthub --title 'Greeting quick check-in'`
- `node ./src/index.js run-queue`
- `node ./src/index.js auto-cycle nixelo`

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
- `enqueue-lane` and `run-queue` provide a tiny file-backed retry queue for deferred runs
- `auto-cycle nixelo` reads the existing auto-mode gate and queues the next OpenCode lane instead of touching OpenClaw cron
