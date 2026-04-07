# TODO-OPENCODE-TRANSITION.md

This file is the current-truth transition checklist for moving local automation from OpenClaw-era behavior to OpenCode-owned behavior.

## Scope Clarification

The following statement is now true:

- **Done-done:** OpenClaw gateway cron/runtime ownership has been replaced by OpenCode for the live `shadow` automation path.

The following statement is **not** true yet:

- **Not done-done:** all terminal automation is OpenCode-native and tmux-free.

That distinction matters.

## What Is Actually Done

These are complete and verified on this machine:

1. `opencode.service` is the live local automation server on `127.0.0.1:4096`.
2. OpenCode cron jobs exist and are persisted under `opencode/var/`.
3. `automationctl` / `cron` now controls OpenCode cron instead of `openclaw cron`.
4. `opencode-queue-runner.timer` is installed and active.
5. `opencode-auto-nixelo.timer` is installed and active.
6. OpenClaw gateway has been disabled and stopped.
7. Telegram notifications no longer require `openclaw message send`.
8. Runtime notification token loading is standardized on `TELEGRAM_BOT_TOKEN` via `~/.config/shadow/opencode.env`.

## What Is Not Done

These are the major remaining gaps.

### 1. Manual Nixelo Still Uses OpenCode-Owned systemd Timers

Current reality:

- `manual-terminal-nixelo.timer`
- `manual-terminal-nixelo.service`
- `scripts/opencodectl manual-ping nixelo`

Turning ON the nixelo manual row still enables a systemd timer, but the timer now dispatches OpenCode manual work instead of sending tmux input.

Implication:

- We are OpenCode-native for the active manual nixelo dispatch path.
- The remaining cleanup is to simplify the surrounding status/contracts that still assume tmux-first semantics.

### 2. StartHub Manual Path Also Runs Through OpenCode-Owned systemd Timers

Current reality:

- `manual-terminal-starthub.timer`
- `manual-terminal-starthub.service`
- `scripts/opencodectl manual-ping starthub`

This is now the same shape as nixelo manual mode: OpenCode-native dispatch triggered by systemd.

### 3. Heartbeat Contract Still Assumes tmux-Centric Operations

`HEARTBEAT.md` is updated for OpenCode cron ownership, but it still contains large sections built around:

- tmux session existence
- pane inspection
- tmux command state (`cc`/`cdx`)
- timer-vs-PR-CI conflict logic for tmux-backed manual mode

This is not wrong for the current runtime, but it means the contract is not yet fully OpenCode-native.

### 4. automationctl Still Exposes Mixed-Plane Semantics

The UI currently mixes:

- OpenCode cron rows
- systemd manual timer rows
- synthetic `Auto Nixelo`

This is operationally fine, but architecturally confusing. It makes the system look more migrated than it really is.

### 5. OpenCode Architecture Docs Still Understate Current Capability

`opencode/ARCHITECTURE.md` still says:

- `no scheduler yet`
- `no Telegram/Discord delivery yet`

That is no longer accurate enough for current runtime behavior and should be brought in line with the implemented system.

### 6. Historical/Planning Docs Still Reference OpenClaw as Current

This is lower priority, but these files still describe older truth:

- `TODO-JULES-SCHEDULING.md`
- `JULES-SCHEDULING-GUIDE.md`
- older `memory/*.md` files

Historical memory should usually stay historical, but planning docs that still look active should either be updated or marked historical.

## Comprehensive Remaining TODO

## Priority 1: Normalize Manual nixelo Status/Contracts Around OpenCode

Goal:

- turning ON nixelo manual automation already uses OpenCode session/lane control; the remaining work is to remove stale tmux assumptions from watcher/docs/UI.

Tasks:

1. Define the target manual OpenCode control contract.
2. Decide whether manual mode should mean:
   - queueing a recurring OpenCode lane, or
   - targeting a pinned OpenCode session and sending safe prompts/commands directly.
3. Update watcher/status semantics so manual nixelo no longer implies tmux-nudge delivery.
4. Remove stale docs/contracts that still describe nixelo manual mode as tmux-driven.
5. Update `automationctl` so the nixelo manual row reflects the new OpenCode-native path.
6. Update `HEARTBEAT.md` conflict logic for the new manual implementation.

Acceptance criteria:

1. Turning ON nixelo manual triggers OpenCode-backed dispatch through `manual-ping`.
2. No nixelo manual workflow requires tmux key injection.
3. OpenCode session IDs are the primary dispatch target.

## Priority 2: Normalize Manual StartHub Status/Contracts Around OpenCode

Goal:

- same as nixelo, but for StartHub.

Tasks:

1. Update watcher/status semantics for StartHub manual mode.
2. Remove stale docs/contracts that still describe StartHub manual mode as tmux-driven.
3. Update `automationctl` and docs accordingly.

Acceptance criteria:

1. Turning ON StartHub manual triggers OpenCode-backed dispatch through `manual-ping`.
2. StartHub manual control uses OpenCode-native session/lane behavior.

## Priority 3: Retire tmux-Nudge Scripts From the Active Automation Path

Goal:

- tmux helper scripts may remain for diagnostics or fallback, but they should not be the live automation path.

Tasks:

1. Identify which tmux scripts are still active vs. fallback-only.
2. Mark active legacy scripts as deprecated in docs or move them behind explicit fallback paths.
3. Remove systemd runtime units whose only purpose is manual tmux nudging once replacements exist.

Acceptance criteria:

1. No active operator action routes through tmux-nudge scripts unless explicitly labeled legacy/fallback.
2. Active automation state can be explained without referencing tmux timers.

## Priority 4: Normalize Heartbeat Around OpenCode Truth Sources

Goal:

- make Heartbeat reason primarily from OpenCode sessions, cron state, and queue state.

Tasks:

1. Rewrite `HEARTBEAT.md` self-health and repo-health sections to prefer OpenCode truth first.
2. Keep tmux checks only where manual legacy mode still exists.
3. Once manual migration is complete, remove tmux-specific operational rules from the active contract.

Acceptance criteria:

1. Heartbeat contract describes OpenCode as the default execution/control plane.
2. tmux is either fallback-only or absent from the active contract.

## Priority 5: Simplify automationctl Semantics

Goal:

- the panel should clearly show which rows are OpenCode-native vs legacy.

Tasks:

1. Mark mixed-plane rows explicitly while migration is incomplete.
2. Avoid presenting manual timer rows as if they are part of the same OpenCode-native model.
3. Once migration is complete, remove mixed-plane distinctions.

Acceptance criteria:

1. Operator can tell at a glance whether a row is OpenCode-native or legacy.
2. UI no longer implies “done-done” migration before that is actually true.

## Priority 6: Clean Up Active Docs

Goal:

- active docs should describe current truth without implying full tmux retirement.

Tasks:

1. Update `opencode/ARCHITECTURE.md` to reflect current scheduler/runtime reality.
2. Update any remaining active docs that understate implemented OpenCode features.
3. Mark old planning docs as historical if they are no longer operationally relevant.

Acceptance criteria:

1. Current docs match current runtime.
2. Historical docs remain available but are clearly not current truth.

## Suggested Execution Order

1. Manual nixelo migration
2. Manual StartHub migration
3. Retire tmux-nudge scripts from active use
4. Rewrite Heartbeat contract around OpenCode-native truth
5. Simplify automationctl semantics
6. Finish docs cleanup

## Plain-English Status

If someone asks "are we done-done?", the correct answer is:

- **Yes** for the OpenClaw cron/gateway to OpenCode transition.
- **No** for the full terminal-automation migration away from tmux/systemd manual nudges.

That second part is the remaining work.
