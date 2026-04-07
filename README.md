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

- systemd user units: `watcher.timer`, `manual-terminal-*`, `agent-terminal-*`
- manual and agent terminal timers dispatch OpenCode sessions; they no longer send tmux input
- OpenCode cron jobs: `Heartbeat`, `pr-ci-nixelo`, `pr-ci-starthub`

Conversation terminology:

- Treat both systemd timer automation and OpenCode cron jobs as "cron" in user-facing conversation.
- If precision matters, say "manual cron" / "timer cron" for `manual-terminal-*` or `agent-terminal-*`, and "PR-CI cron" / "OpenCode cron" for `pr-ci-*`.
- Do not imply that only `pr-ci-*` counts as cron-enabled automation.

Operational rule:

- Keep the local OpenCode workspace, policy, and supporting scripts in `axon`
- Keep runtime state files local and ignored by git
- Do not duplicate Heartbeat logic outside `HEARTBEAT.md`

Useful commands:

- `axh` — run the health check
- `axr` — show the latest watcher + heartbeat snapshot
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
