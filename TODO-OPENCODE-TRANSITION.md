# TODO-OPENCODE-TRANSITION.md

Remaining TODO only.

## 1. Inbound Telegram Bridge

Missing capability:

- Telegram outbound works
- Telegram inbound does not
- OpenCode does not yet auto-receive Telegram messages and reply back

Tasks:

1. Add a persisted Telegram update offset/state file under `opencode/var/`.
2. Add a small poller or webhook bridge that reads inbound Telegram messages.
3. Route inbound messages into a stable OpenCode session.
4. Send the assistant reply back to Telegram automatically.
5. Add systemd runtime wiring for the bridge.

Acceptance criteria:

1. A Telegram message sent to the bot is ingested automatically.
2. OpenCode generates a reply without manual intervention.
3. The reply is sent back to Telegram automatically.

## 2. Heartbeat Contract Cleanup

Remaining issue:

- `HEARTBEAT.md` still contains tmux-centric operational reasoning in several sections.

Tasks:

1. Rewrite repo-health sections to prefer OpenCode session truth first.
2. Remove or demote tmux-only assumptions where they are no longer part of the active path.
3. Keep only the tmux checks that still have operational value as passive observation.

Acceptance criteria:

1. Heartbeat contract describes the active runtime as OpenCode-first.
2. tmux appears only as observational/fallback context, not as the active control path.

## 3. automationctl Semantics Cleanup

Remaining issue:

- `automationctl` still presents a mixed model of OpenCode cron rows, manual systemd timers, and synthetic auto-mode rows.

Tasks:

1. Make row labeling clearer so operators can tell what is OpenCode cron vs systemd timer.
2. Revisit whether `Auto Nixelo` should remain synthetic or become a more explicit control surface.
3. Remove wording that implies legacy OpenClaw-era semantics.

Acceptance criteria:

1. The panel clearly communicates each row’s control plane.
2. Operators do not need repo memory to understand what ON/OFF actually means.

## 4. Historical/Planning Doc Triage

Remaining issue:

- Some old planning docs still read like current truth even though they are historical.

Candidates:

- `TODO-JULES-SCHEDULING.md`
- `JULES-SCHEDULING-GUIDE.md`
- selected `memory/*.md` references

Tasks:

1. Mark outdated planning docs as historical where appropriate.
2. Leave memory files as historical record unless there is a concrete reason to rewrite them.

Acceptance criteria:

1. Active docs look current.
2. Historical docs are clearly distinguishable from current runtime docs.
