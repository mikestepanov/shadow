# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Terminal Automation Quick Labels

- `NUKE_TMUX_RUNTIME` → remove live tmux-related runtime timers, keep repo files.
- `OFF` means not installed in runtime.
- `ON` means installed in runtime.

Current canonical systemd terminal units:
- `manual-terminal-nixelo.timer`
- `manual-terminal-starthub.timer`
- `agent-terminal-nixelo.timer`
- `agent-terminal-starthub.timer`

OpenCode terminal automation jobs (tmux/PR-CI):
- `pr-ci-nixelo`
- `pr-ci-starthub`

Messaging/heartbeat terminology lock:
- "AI-powered Essential Automation" = heartbeat/report/restart jobs
- "AI-powered Terminal Automation" = `pr-ci-*`
- "Non-AI System Terminal Automation" = `manual-terminal-*`, `agent-terminal-*`
- User-facing default wording: "Terminal Automation" (combined umbrella term).
- Only split into internals when the user explicitly asks.
- For cron listings, report all three groups in this order: Essential, AI-powered Terminal, Non-AI System Terminal.
- Never use ambiguous shorthand.

## automationctl (Textual TUI)

NixOS-first launch (no pip):

```bash
nix-shell -p python313Packages.textual --run '~/Desktop/shadow/scripts/automationctl'
```

Direct launch (works when Python already has `textual`):

```bash
~/Desktop/shadow/scripts/automationctl
```

If `textual` is missing, the launcher prints the exact `nix shell ...` fallback command.

## Terminal mode detection (cdx vs cc)

`pane_current_command` alone is not enough (`cdx` and `cc` both often show `node`).

Use this when mode matters:

```bash
pane=$(tmux list-panes -t <session> -F '#{pane_id}' | head -n1)
pid=$(tmux display-message -p -t "$pane" '#{pane_pid}')
sid=$(ps -o sid= -p "$pid" | tr -d ' ')
ps -o pid,ppid,command --forest -g "$sid"
```

Interpretation:
- if process tree shows `.../bin/codex ...` → `cdx`
- if process tree shows Claude CLI process chain → `cc`

## Terminal enable checklist (mandatory)

Before enabling any terminal cron/timer:
1. Verify the OpenCode server is healthy: `scripts/opencodectl status`.
2. Verify the target repo session is bootstrappable:
   - `scripts/opencodectl ensure-session nixelo`
   - `scripts/opencodectl ensure-session starthub`
3. Only then enable/start the cron/timer.
4. HARD STOP: if the required OpenCode session cannot be created or resumed, do not enable anything; report and wait.
5. Scope lock: when executing a user-approved change, touch ONLY approved fields. Do not piggyback unrelated edits.
6. Post-change output must list exact requested field deltas and confirm no extra edits.
7. Handshake lock: no state-changing command may run until a PLAN is sent and an explicit APPROVE token is received.
8. If a request asks to change one field (e.g., timeout), do not touch schedule/payload/model or any other field.
11. Ambiguity hard-stop: if anything is unclear (even slightly), STOP and ask one clarifying question before any command.
12. Fidelity lock: do exactly what was asked; do not add “helpful” extra changes.
13. Request mapping lock: before any command, explicitly map requested items/fields and execute only those.
14. Delta report lock: after execution, report exact before→after deltas for requested items and explicitly list any extra changes if they occurred.
15. Copy lock: when user says "copy", do literal carbon copy (1:1 structure/logic), not close copy.
16. Command-token lock: if user gives exact command token (e.g., `cc`), use exactly that token; do not swap to another token (e.g., `claude`) unless user explicitly asks.

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
