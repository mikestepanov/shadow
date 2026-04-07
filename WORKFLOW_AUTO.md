# WORKFLOW_AUTO.md

## Purpose
Restore operational rules after compaction/restart so automation behavior stays consistent.

## Execution Gate (MANDATORY)
- For any state-changing action, assistant must send `PLAN TO EXECUTE:` first.
- Control words:
  - `APPROVE` = execute
  - `DENY` = do nothing
- If no approval: no-op.
- Every plan must include explicit final state per item: `ON` or `OFF`.

## Scheduler Model
- Terminal automation is split across:
  - systemd user timers for watcher/manual/agent scheduling
  - OpenCode cron for Heartbeat and PR-CI automation
- Current terminal systemd units:
  - `manual-terminal-nixelo.timer`
  - `manual-terminal-starthub.timer`
  - `agent-terminal-nixelo.timer`
  - `agent-terminal-starthub.timer`

Manual timer semantics:
- `manual-terminal-*` timers are still systemd units
- but their services now dispatch OpenCode manual sessions via `scripts/opencodectl manual-ping <repo>`
- they are no longer tmux-input nudgers

## Runtime Policy
- Preferred OFF behavior: **delete/uninstall runtime unit**, keep repo files.
- Plain rule: **delete live cron/timer, preserve file template**.

## Manual Text (canonical)
If IDLE and clean:
- `Read ~/Desktop/StartHub/todos/e2e-testing.md and continue working. Use Playwright. Commit frequently.`

If IDLE and dirty:
- `Commit all current changes now with a focused message, then continue working on e2e-testing.md. Use Playwright. Commit frequently.`

Note:
- This short prompt style is the canonical **manual** format.
- Do not replace manual text with role-cycle or MANDATORY ORDER agent payloads.

## Agent Text
- Agent text is separate from manual text.
- Do not reuse long role-order payload for manual nudges.

## Cron Listing Output Format
When user asks to list crons, output exactly two tables in this order:
1) `OpenCode Crons`
2) `systemd Timers`

Table columns must be:
- `Name | Runs (human time) | Purpose | Status`

Status values only:
- `ON` = installed
- `OFF` = not installed

Do not include IDs, raw cron syntax, or timezone jargon unless asked.
