# MEMORY.md

This file is the compressed current-truth memory for the local OpenCode workspace.

Use this for:
- stable operating facts
- hard rules that still matter now
- where to find detailed history

Do not use this file as a full incident archive. Historical details live in `memory/*.md`.

## Current Truth
- Canonical workspace: `~/Desktop/shadow`
- OpenClaw workspace link: `~/.openclaw/workspace -> ~/Desktop/shadow`
- OpenClaw version: `2026.4.2 (d74a122)`
- Gateway health: `OK`, Telegram health `ok`
- Watcher timer: `active`, `enabled`
- Current agent defaults in `~/.openclaw/openclaw.json`:
  - primary model: `openai-codex/gpt-5.4-high`
  - heartbeat model: `openai-codex/gpt-5.4-high`
  - subagents model: `openai-codex/gpt-5.4-high`
- Current cron jobs:
  - `Heartbeat`: enabled, runs every 10m, payload model still pinned to `openai-codex/gpt-5.3-codex`
  - `pr-ci-nixelo`: disabled
  - `pr-ci-starthub`: disabled
  - `Morning Sub-Agent Report`: disabled
  - `Nightly Sub-Agent Report`: disabled

## Terminal Automation Facts
- Tmux working repos:
  - `nixelo` session -> `~/Desktop/nixelo`
  - `starthub` session -> `~/Desktop/StartHub`
- `-agent` repos are not for tmux work.
- Terminal busy detection must be runtime/process-first, not prompt-text-first.
- Queue-aware / working-state checks matter more than prompt shape.
- Current terminal timer states last verified in this session:
  - `manual-terminal-nixelo.timer`: `failed`, `enabled`
  - `manual-terminal-starthub.timer`: `inactive`, `disabled`
  - `agent-terminal-nixelo.timer`: `inactive`, `disabled`
  - `agent-terminal-starthub.timer`: `inactive`, `masked`

## Hard Rules
- Never touch git remotes/origin unless Mikhail explicitly asks.
- For operational claims, verify first with fresh command output.
- If state is ambiguous, say so directly instead of inferring.
- Never perform state-changing automation without explicit approval in the current conversation.
- Never use tmux text injection like `clear` / `exit` into `cc` or `cdx` panes.
- Treat terminal automation as dual-plane:
  - systemd timers/services
  - OpenCode cron jobs
- `OFF` means fully off across both planes and no active worker behavior.

## Working Preferences
- Evidence-first wording: check first, then state facts.
- Answer direct questions directly in line 1.
- Use exact command tokens when Mikhail specifies them.
- Prefer deterministic scripts/checks over ad-hoc operator reasoning.

## Key Files
- `HEARTBEAT.md`: active heartbeat contract
- `README.md`: current workspace overview
- `scripts/watcher.sh`: deterministic watcher
- `scripts/terminal-automation`: terminal automation plan/execute flow
- `scripts/automationctl`: Textual control panel
- `systemd/`: canonical user-unit templates

## Historical Index
- `memory/2026-03-30.md`: watcher split, busy-detection fixes, approval failures
- `memory/2026-03-24.md`: auto-mode disaster and approval/tmux lessons
- `memory/2026-03-05.md`: timer lifecycle, OFF semantics, approval handshake
- `memory/2026-02-27.md`: old `openclaw` path/repo confusion
- `memory/jules-workflow.md`: Jules-specific workflow notes
- `memory/repo-rules.md`: older repo-target rules, may be stale

## Known Stale Areas
- Some historical notes still mention `~/Desktop/axon` or `~/Desktop/openclaw`.
- Treat `MEMORY.md` as the source for current path truth; treat dated files as historical context only.
