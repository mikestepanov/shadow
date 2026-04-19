# OpenCode Controller Architecture

## Objective
- determine whether an OpenCode session is busy
- submit a message or command only when the session is safe to accept it
- expose a small control surface that other local automation can call

## Initial control contract
- `status`
  - returns one of: `busy`, `idle`, `waiting_user`, `unknown`
- `send`
  - sends a prompt or command to a chosen OpenCode session
- `wait`
  - blocks until session reaches `idle` or timeout

## Preferred truth sources
1. OpenCode session/status APIs or event stream
2. OpenCode server-side session metadata
3. terminal/tmux fallback only if native state is unavailable

## Current implemented control surface
- `status` / `send` / `safe-send` / `safe-command` for session-aware control
- `lane-run` / `enqueue-lane` / `run-queue` for queue-backed lane dispatch
- `cron list|enable|disable|edit|run` for OpenCode-owned cron jobs
- `ensure-session` / `manual-ping` / `agent-ping` / `prci-ping` for repo-scoped session bootstrap and dispatch

## Runtime reality
- `opencode.service` owns the local HTTP server on `127.0.0.1:4096`
- OpenCode cron state lives under `opencode/var/`
- systemd manual/agent/PR-CI timers dispatch through `scripts/opencodectl *-ping <repo>` and retain tmux-safe terminal gating underneath
- Telegram delivery for automation scripts is provided via `TELEGRAM_BOT_TOKEN`

## Still not goals
- no broad multi-agent orchestration yet
- no heavy UI beyond `automationctl`

## Minimal layout
- `src/client.ts` - OpenCode API wrapper
- `src/status.ts` - state resolution
- `src/send.ts` - prompt/command submission
- `src/wait.ts` - wait-until-idle helper
- `src/index.ts` - thin entrypoint
