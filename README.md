# Axon

`axon` is the local OpenClaw workspace and support repo.

Canonical local checkout:

- `~/Desktop/shadow`
- `~/.openclaw/workspace` is a symlink to `~/Desktop/shadow`

What lives here:

- `HEARTBEAT.md` — canonical Heartbeat behavior contract
- `scripts/watcher.sh` — deterministic watcher that writes local state
- `systemd/` — canonical user-unit templates for watcher and terminal automation
- `scripts/healthcheck.sh` and `scripts/recent.sh` — operator-facing health probes
- `watcher-state.json`, `health-summary.json`, `heartbeat-dispatch-state.json` — local state files ignored by git
- `memory/` and top-level docs — operational notes, rules, and workflow state

Observed control planes:

- systemd user units: `watcher.timer`, `manual-terminal-*`, `agent-terminal-*`
- OpenClaw cron jobs: `Heartbeat`, `pr-ci-nixelo`, `pr-ci-starthub`

Operational rule:

- Keep the local OpenClaw workspace, policy, and supporting scripts in `axon`
- Keep runtime state files local and ignored by git
- Do not duplicate Heartbeat logic outside `HEARTBEAT.md`

Useful commands:

- `axh` — run the health check
- `axr` — show the latest watcher + heartbeat snapshot
- `bash ~/Desktop/shadow/scripts/healthcheck.sh` — run health check directly
- `bash ~/Desktop/shadow/scripts/recent.sh` — print the current watcher summary
- `nix-shell -p python313Packages.textual --run '~/Desktop/shadow/scripts/automationctl'` — open the automation control TUI
- `systemctl --user start watcher.service` — force a fresh watcher snapshot
- `openclaw cron list --all` — inspect Heartbeat and PR-CI cron status

Normal healthy state:

- `watcher.timer` is active and enabled
- `watcher-state.json` is fresh
- `crons.heartbeat` is `ok`
- repo `alerts` are `none`
- `manual_enabled` / `agent_enabled` reflect intentional disabled or masked states, not `unknown`
