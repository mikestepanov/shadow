# Axon

`axon` is the local OpenCode workspace and support repo.

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

- systemd user units: `watcher.timer`, `manual-terminal-*`, `agent-terminal-*`, `prci-terminal-*`, `opencode-auto-nixelo.timer`
- `manual-terminal-*`, `agent-terminal-*`, and `prci-terminal-*` are the live terminal automation control plane
- OpenCode cron jobs still exist in local state, but nixelo PR-CI is currently driven by systemd timers, not the old OpenCode `pr-ci-*` cron jobs

Conversation terminology:

- Treat both systemd timer automation and OpenCode cron jobs as "cron" in user-facing conversation.
- If precision matters, say `manual timer`, `agent timer`, `PR-CI timer`, or `auto-cycle timer` for the systemd path.
- Do not claim which mode nixelo is in from memory or docs. Check live timer state first with `systemctl --user status manual-terminal-nixelo.timer prci-terminal-nixelo.timer opencode-auto-nixelo.timer`.

Operational rule:

- Keep the local OpenCode workspace, policy, and supporting scripts in `axon`
- Keep runtime state files local and ignored by git
- Do not duplicate Heartbeat logic outside `HEARTBEAT.md`

Useful commands:

- `axh` — run the health check
- `axr` — show the latest watcher + heartbeat snapshot

## Current Status

Nixelo currently uses a systemd-first automation loop:

- `manual-terminal-nixelo.timer` = manual TODO work mode
- `prci-terminal-nixelo.timer` = PR review / fix mode
- `opencode-auto-nixelo.timer` = done-done watcher and branch-cycle automation

Expected nixelo lifecycle:

- manual mode works the TODO branch
- when work transitions to PR review, PR-CI timer takes over
- `opencode-auto-nixelo.timer` checks done-done every minute
- when done-done passes, auto-cycle disables PR-CI, merges, checks out `dev`, creates a new date branch, and re-enables manual mode

Important:

- the live mode can change over time; always verify it from systemd before stating it
- `manual-terminal-nixelo.timer` and `prci-terminal-nixelo.timer` are mutually exclusive in the intended steady state
- `opencode-auto-nixelo.timer` can remain active while either manual or PR-CI mode is active
- `bash ~/Desktop/shadow/scripts/healthcheck.sh` — run health check directly
- `bash ~/Desktop/shadow/scripts/recent.sh` — print the current watcher summary
- `nix-shell -p python313Packages.textual --run '~/Desktop/shadow/scripts/automationctl'` — open the automation control TUI
- `systemctl --user status opencode.service` — inspect the live OpenCode server
- `systemctl --user start watcher.service` — force a fresh watcher snapshot
- `scripts/opencodectl cron list --all` — inspect Heartbeat and PR-CI cron status

Normal healthy state:

- `watcher.timer` is active and enabled
- `watcher-state.json` is fresh
- `crons.heartbeat` is `ok`
- repo `alerts` are `none`
- `manual_enabled` / `agent_enabled` reflect intentional disabled or masked states, not `unknown`
