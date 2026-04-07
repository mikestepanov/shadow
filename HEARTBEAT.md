# HEARTBEAT.md

> YO — DO NOT MODIFY THIS FILE UNLESS EXPLICITLY REQUESTED BY THE USER.

> Canonical source note: `HEARTBEAT.md` is the sole source of Heartbeat behavior. Do not maintain parallel executable heartbeat logic elsewhere unless the user explicitly asks for it.

## Smart Heartbeat Protocol (v2, added 2026-03-04)

Goal: detect real progress, auto-recover stuck tmux sessions, and escalate only when needed.

### Canonical naming/state note (2026-03-05)
- Terminal automation naming was migrated.
- Canonical systemd units are now:
  - `manual-terminal-nixelo.timer`
  - `manual-terminal-starthub.timer`
  - `agent-terminal-nixelo.timer`
  - `agent-terminal-starthub.timer`
- Legacy `tmux-agent-work-ping*` names are historical in intervention logs below.

### Config (edit here, no hardcoding in logic)

```yaml
repos:
  nixelo:
    path: ~/Desktop/nixelo
    baseline: 499a9077
    tmux: nixelo
    task_file: todos/README.md
    stale_minutes: 120
  starthub:
    path: ~/Desktop/StartHub
    baseline: c393224a6
    tmux: starthub
    task_file: todos/backend/payments-stripe-mba-comprehensive.md
    stale_minutes: 120

commit_quality:
  ignore_subject_prefixes:
    - "wip(starthub): heartbeat checkpoint"
    - "wip: heartbeat checkpoint"

recovery:
  max_attempts_before_escalate: 2
  max_identical_dispatches: 3
```

---

## ⚠️ WATCHER-FIRST PROTOCOL (v3, added 2026-03-30)

**The watcher script (`~/Desktop/shadow/scripts/watcher.sh`) runs every 2 min via systemd timer and writes structured JSON to `~/Desktop/shadow/watcher-state.json`.**

### Heartbeat AI MUST:
1. **Read the watcher state file FIRST** — `cat ~/Desktop/shadow/watcher-state.json`
2. **Report what the watcher found** — alerts, repo status, cron health
3. **If alerts exist** → report to Mikhail via Telegram, do NOT fix directly
4. **If no alerts** → HEARTBEAT_OK

### Heartbeat AI MUST NOT (HARD RULES):
- ❌ **NEVER** run `tmux send-keys` during heartbeat
- ❌ **NEVER** create, close, or merge PRs
- ❌ **NEVER** run `systemctl` start/stop/enable/disable directly
- ❌ **NEVER** run `gh pr create/close/merge`
- ❌ **NEVER** run nudge scripts manually (`tmux-manual-work-ping`)
- ❌ **NEVER** send `Escape`, `/stop`, `C-c`, or any input to tmux panes
- ❌ **NEVER** run `scripts/opencodectl cron enable/disable` directly
- ❌ **NEVER** enable/disable/start/stop nixelo manual timer — Mikhail handles the auto-nixelo lifecycle manually. If nixelo timer is off, it's off on purpose. Do NOT re-enable it.

### Heartbeat AI MAY:
- ✅ Read watcher state file
- ✅ Run `scripts/opencodectl cron list --all --json` to check cron health
- ✅ Run `scripts/opencodectl cron edit <id> --model <model>` to fix cron model routing
- ✅ Run `scripts/opencodectl cron run <id>` to force-run a broken cron
- ✅ Run `bash ~/Desktop/shadow/scripts/auto_nixelo_cycle.sh` (read-only check)
- ✅ Send alerts via `message` tool to Telegram
- ✅ Use `terminal-automation plan/execute` flow (with user APPROVE)
- ✅ Run read-only git commands (`git log`, `git status`, `git branch`)

### What watcher checks (so heartbeat doesn't need to):
- Timer/service health (stuck in `activating` state)
- Nudge delivery patterns (SENT vs NOOP, last SENT age)
- Process tree (phantom background terminals)
- Commit freshness per repo
- Conflict detection (manual vs PR-CI overlap)
- Tmux session existence + pane state
- Unit file existence

### Alert escalation:
When watcher reports alerts, heartbeat MUST attempt to fix them using allowed actions first:
- Cron model failures → switch model via `scripts/opencodectl cron edit`
- Stuck services → `kill` the hung PID, `systemctl --user reset-failed`
- Nixelo manual timer not re-enabled after auto-cycle → re-enable via `terminal-automation plan/execute`
- IDLE_NO_NUDGE on idle terminal → diagnose guard bug, fix if possible

Only alert via Telegram when ALL of these are true:
1. The same alert persists for **3+ consecutive watcher cycles** (6+ minutes)
2. A verification subagent has confirmed the issue is real (not transient)
3. The fix is outside allowed actions (tmux input, PR creation, etc.)

**Verification before alerting (MANDATORY):**
- Spawn a subagent to independently verify: check process tree, check if content is actually changing, check if the terminal is between tasks
- If subagent says "transient / not confirmed" → do NOT alert, wait for next cycle
- If subagent says "confirmed stuck" → alert with verification evidence
- NEVER forward a watcher alert directly to Telegram without independent verification

**Exception:** Cron model failures (`consecutiveErrors >= 3`) may be auto-fixed by switching the model (this is safe and doesn't touch terminals).

---

## Self-health check (MANDATORY, runs before everything else)

Every heartbeat pass — whether triggered by cron or interactive session — MUST verify the heartbeat cron job itself is healthy:

```bash
scripts/opencodectl cron list --all --json   # check heartbeat job status + consecutiveErrors
```

**Hard rules:**
1. If heartbeat cron (or ANY other cron) shows `status: error` with `consecutiveErrors >= 3`, diagnose and fix in-cycle:
   - Check the error message (rate limit, model not allowed, timeout, etc.)
   - If rate-limited: switch model to an available provider (`scripts/opencodectl cron edit <id> --model <fallback>`)
   - If model routing is wrong: update the OpenCode cron job model or OpenCode provider defaults
   - Force-run after fix to verify: `scripts/opencodectl cron run <id>`
   - Confirm `status: ok` before proceeding with the rest of the heartbeat
2. If heartbeat cron is `disabled` unexpectedly, re-enable it.
3. If the cron hasn't run in >10 minutes (check `Last` column), force-run it.
4. **The interactive session (you talking to the user) is the backup heartbeat.** If the cron can't run, YOU do the work. Don't treat the cron as someone else's problem.
5. Current runtime: OpenCode cron + `opencode.service` on `127.0.0.1:4096`.

### Conflict detection (MANDATORY, runs after self-health check)

Before any repo-level checks, verify no repo has BOTH manual/agent AND PR-CI automation enabled simultaneously:

```bash
# Check all automation layers
systemctl --user is-active manual-terminal-nixelo.timer manual-terminal-starthub.timer 2>&1
scripts/opencodectl cron list --all 2>&1  # look for pr-ci-* enabled status
```

**Hard rules:**
1. If any repo has both manual/agent timer ACTIVE and PR-CI cron ENABLED → **immediate conflict**. Disable the manual timer for that repo in-cycle (PR-CI takes priority when TODO is done). Alert via Telegram if unclear which should win.
2. If a repo's TODO file no longer exists but its manual cron is still ON → disable manual cron immediately (work is done, nothing to nudge).
3. This check must run EVERY cycle regardless of terminal busy state. "Terminal busy" is not a reason to skip conflict detection.
4. **Missing canonical unit self-heal (added 2026-03-30):** if any canonical terminal unit (`manual-terminal-*`, `agent-terminal-*`) is `Loaded: not-found`, heartbeat MUST repair it in-cycle:
   - restore from `~/Desktop/shadow/systemd/<unit>` into `~/.config/systemd/user/<unit>`
   - run `systemctl --user daemon-reload`
   - run `systemctl --user reset-failed <unit>`
   - run `systemctl --user disable <unit>` (ensure clean OFF state — prevents stale enable symlinks from auto-starting the timer)
   - verify `Loaded: loaded` AND `Active: inactive` AND `enabled: disabled` before continuing
5. If the source unit file is missing in `~/Desktop/shadow/systemd/`, fail closed: emit alert (not `HEARTBEAT_OK`) with exact missing path.

---

## Per-heartbeat procedure

### 1) Collect signals

For each repo:

```bash
cd <repo.path> && git log --oneline <repo.baseline>..HEAD | head -10
cd <repo.path> && git log -1 --format="%h|%s|%ct"
tmux capture-pane -t <repo.tmux> -p | tail -20
```

### 2) Activity score (smart classification)

### Intent-aware state model (dynamic, added 2026-03-06)
Heartbeat must be dynamic, not static. Do not assume OFF or ON from historical logs.

### Terminology + reporting lock (added 2026-03-06)
Treat all tmux-related automation as Terminal Automation, split into two explicit groups:
1. **Non-AI System Terminal Automation**: `manual-terminal-*`, `agent-terminal-*`
2. **AI-powered Terminal Automation**: `pr-ci-*`

Every heartbeat must report both groups explicitly, plus tmux readiness:
- Non-AI System Terminal Automation state by unit
- AI-powered Terminal Automation state by job
- tmux readiness (`pane_current_command`) for `nixelo` and `starthub`

Determine expected intent in this order:
1. Explicit user instruction in current chat (highest priority).
2. Live runtime reality + recent outcomes (timers/sessions state, tmux output quality, commit freshness).
3. Historical intervention notes (advisory only, lowest priority).

Classify runtime mode each cycle:
- `MODE_ACTIVE`: scheduler/workers ON and producing meaningful work.
- `MODE_PAUSED`: scheduler/workers OFF with no active worker output.
- `MODE_MIXED`: partial ON/OFF or contradictory signals; requires attention only if behavior is harmful/unintended.

### Heartbeat execution mode (v4, updated 2026-03-07)
- Heartbeat is **AUTO-TRANSITION ENABLED** for terminal automation handoff.
- Scope: it may switch between manual/agent terminal automation and PR-CI automation when handoff gates are satisfied.
- Heartbeat must still avoid destructive actions (no destructive git commands).
- **Nudge-vs-control hard gate (added 2026-03-09):** heartbeat/cron may send task nudges, but must not send control/mutation commands (`C-c`, mode switch, `cd`, stop/handoff directives, or PR slash-command dispatch) unless BOTH are verified in-cycle: (1) workflow is independently done, and (2) terminal process is truly idle.
- **Global terminal-busy wait rule (added 2026-03-10):** for any terminal-touching cron/heartbeat path, if target tmux pane is actively working (not true paused/idle), return `NOOP:terminal-busy` and perform zero mutations/dispatch in that cycle. No exceptions for PR-CI mode switching.
- **15-minute handoff timer is stateful (hard rule), not in-memory:**
  - State file: `~/Desktop/shadow/heartbeat-handoff-state.json` (same as `~/.openclaw/workspace/heartbeat-handoff-state.json`).
  - Per repo fields: `handoff_started_at` (epoch ms or null), `cut_sent` (bool).
  - On first dirty-handoff detection, set `handoff_started_at=now`, `cut_sent=false`, send commit-and-stop instruction.
  - On subsequent runs, compute elapsed from `handoff_started_at`.
  - If elapsed >= 15 minutes and still running, send `C-c`, set `cut_sent=true`, and continue transition.
  - Clear repo state (`handoff_started_at=null`, `cut_sent=false`) once transition completes or condition clears.
- Do not escalate solely because a terminal did not stop immediately; allow long-running work during the 15-minute grace window.
- **Desync auto-fix (hard rule):** when expected terminal mode and actual tmux process mode differ (`cdx` vs `cc`), heartbeat must auto-correct in-cycle:
  1) send `C-c`,
  2) launch expected command token (`cdx` for manual, `cc` for PR-CI),
  3) verify mode via pane PID + process tree (not `pane_current_command` alone),
  4) only then continue command dispatch (`/pr`, `/fix-pr-comments`, etc.).
- **Cron-gated mode-mutation rule (added 2026-03-08):** heartbeat may switch tmux mode only when the corresponding automation is ON for that repo: PR-CI ON => `cc`, manual/agent ON => `cdx`; if both OFF => report-only (no mode mutation); if both ON => conflict (`BLOCKED_HUMAN`) and no mutation.
- **Human-controlled hands-off rule (added 2026-03-08):** if both PR-CI and manual/agent automation are OFF for a repo, treat that repo as human-controlled and do not interfere: no handoff-gate evaluation, no dirty-handoff timer actions, and no tmux input injection for that repo.
- **Repo-path auto-fix (hard rule, added 2026-03-08):** before any PR/terminal dispatch, heartbeat must verify pane working directory matches expected repo (`nixelo` -> `~/Desktop/nixelo`, `starthub` -> `~/Desktop/StartHub`). If mismatched, auto-correct in-cycle: `C-c` -> `cd <expected repo>` -> launch expected token (`cc`/`cdx`) -> verify both path + mode, then and only then dispatch commands.
- **Tmux persistence hard rule (added 2026-03-08):** do not close tmux sessions during heartbeat/cron handling. Keep sessions alive at all times; recover via in-pane controls only (`C-c`, `cd`, relaunch token). Do not use `tmux kill-session`, `tmux kill-server`, or pane-respawn flows that drop the session.
- **Done-done stop hard rule (added 2026-03-08):** once a target workflow is independently verified complete, heartbeat/cron must disable all related cron jobs immediately (global rule, not PR-CI-only), stop further automation dispatch, and keep tmux sessions alive.
- **Independent completion verification (hard rule):** terminal self-report is never sufficient to mark PR work complete. The assistant must verify resolution itself via both: (a) workflow/skill-side review state, and (b) direct `gh` review/thread checks, including required 👍 reaction evidence when applicable.
- **Fail-closed PR existence rule (added 2026-03-08):** if PR lookup/readiness check is ambiguous or errors, dispatch no commands (`NOOP`/`BLOCKED_HUMAN`). Do not send `/pr` unless no-open-PR is directly and unambiguously verified via `gh` in the same run.
- **Scripted dispatch rule (added 2026-03-08):** for StartHub PR-CI, use deterministic script dispatcher `scripts/pr_ci_starthub_dispatch.sh` as sole command path; do not emit freeform tmux commands from prompt logic.
- **Independent completion verification (hard rule):** terminal self-report is never sufficient to mark PR work complete. The assistant must verify resolution itself via both: (a) workflow/skill-side review state, and (b) direct `gh` review/thread checks, including required 👍 reaction evidence when applicable.
- **Merge-readiness hard gate (added 2026-03-08):** never mark a repo/session "ready" or return global `HEARTBEAT_OK` when any target PR has red required checks.
- **Unpushed-commit hard gate (added 2026-03-08):** never mark a repo/session "ready" when local branch is ahead of upstream (`ahead > 0`) for the active PR branch.
- **Sufficiency hard gate (added 2026-03-08):** `unresolved review threads == 0` is necessary but not sufficient; readiness requires all three: (1) required checks passing, (2) ahead=0, (3) unresolved threads=0.
- **Playwright gate (updated 2026-03-30):** for ALL repos (nixelo AND StartHub), done-done/cron-stop requires Playwright E2E signal to be clean: zero failed and zero flaky Playwright E2E tests. This is now agnostic — same gate for every repo.

Minimum verification commands:
```bash
systemctl --user is-active manual-terminal-nixelo.timer manual-terminal-starthub.timer agent-terminal-nixelo.timer agent-terminal-starthub.timer
systemctl --user is-enabled manual-terminal-nixelo.timer manual-terminal-starthub.timer agent-terminal-nixelo.timer agent-terminal-starthub.timer
tmux has-session -t nixelo && tmux capture-pane -t nixelo -p | tail -5
tmux has-session -t starthub && tmux capture-pane -t starthub -p | tail -5
```

Terminal enable preflight (mandatory before turning terminal timers/crons ON):
```bash
# 1) tmux session must exist
tmux has-session -t nixelo
tmux has-session -t starthub

# 2) Codex must be active/ready in pane; verify via current process (not stale banner text)
pane=$(tmux list-panes -t nixelo -F '#{pane_id}' | head -n1)
tmux display-message -p -t "$pane" '#{pane_current_command}'
# READY only when active Codex process is running (typically `node`), not `bash`
# if Codex not present/ready:
tmux send-keys -t nixelo "cdx"
tmux send-keys -t nixelo Enter

# 3) verify Codex is ready again via pane_current_command, then enable timer/cron
```
Hard stop: if tmux is missing or Codex is not ready, do not enable anything. Report failure and wait for explicit user direction.

### 2.5) Nudge delivery cross-check (MANDATORY when manual timer is ON)

If `manual-terminal-<repo>.timer` is active, heartbeat MUST verify nudges are actually being delivered:

```bash
journalctl --user -u manual-terminal-<repo>.service --since "-30min" --no-pager | grep -E "SENT|NOOP|SKIP|BLOCKED"
```

**Hard rules:**
1. If terminal appears idle (at `›` prompt) but last 30min of journal shows only `NOOP:terminal-busy` → **BUG in busy detection**. Alert immediately and investigate `busy_reason` output.
2. If terminal is idle and last SENT is >30min ago → something is wrong. Run the nudge script manually to test: `~/Desktop/shadow/scripts/tmux-manual-work-ping <session>`
3. Never report "all systems operational" or `HEARTBEAT_OK` when the timer is ON but zero nudges are being delivered to an idle terminal. This is a **hard gate** — any active timer with 0 SENT in last 10 minutes on an idle terminal MUST be flagged, never ignored.
4. **Agnostic busy-detection law (added 2026-03-30):** busy detection must work uniformly across ALL terminal lanes/sessions and CLI UIs (cdx/cc/other). Queue markers, pending outbound messages, and background-terminal waits are BUSY regardless of prompt shape or provider-specific UI text. Never rely on one model’s exact wording.

Score each repo from these signals:

- +2: recent non-ignored commit within `stale_minutes`
- +1: tmux shows `Working`
- -2: tmux sits at bare prompt (`›`) with no meaningful output AND nudges not being delivered
- -2: heavy token burn / repeated output without commit
- -3: explicit error/prompt loop requiring input
- -3: **done-loop detected** — terminal pane shows 3+ "done"/"complete"/"nothing left" messages (act immediately, don't wait)
- -3: **churn detected** — commit count vs net files changed ratio is absurd (e.g. >5 commits per net changed file since baseline). Check with `git rev-list --count <baseline>..HEAD` vs `git diff --stat <baseline>..HEAD | tail -1`. If churn, investigate whether features are actually landing or just cycling through merge-commit noise.

Classify:
- **Healthy**: score >= 2
- **At risk**: score 0..1
- **Stalled**: score < 0

### 3) Transition gate: manual/agent → PR-CI

Heartbeat may transition a repo from terminal work (manual/agent) to PR-CI when this gate is met:

1. TODO completion condition:
   - TODO is 100% complete, **OR**
   - TODO is effectively plateaued at >=90% for the last 10+ commits with mostly enhancements/additions and no material TODO movement.
2. If repo is dirty at handoff point:
   - start/continue persisted handoff timer in `heartbeat-handoff-state.json`,
   - send instruction to commit all current changes with `--no-verify` and stop,
   - after elapsed >=15 minutes from `handoff_started_at`, if still not stopped, send `C-c` and continue handoff.

After gate passes:
- Disable terminal automation for that repo (manual/agent as applicable).
- Enable PR-CI automation for that repo.
- Keep PR-CI running until merge-readiness is verified (all required checks green, ahead=0, unresolved threads=0) and bot comments are fully reviewed.
- Only stop PR-CI loop when done-done gate passes (see 3.1 below).

### 3.1) PR-CI done-done auto-disable (added 2026-03-17)

**Problem this solves:** The PR-CI cron lane does not own the done-done shutdown decision. Heartbeat owns done-done detection and OpenCode cron shutdown.

**Runs every heartbeat cycle** for each repo where `pr-ci-*` cron is enabled:

```bash
# 1. Get PR number
cd <repo_dir>
pr_number=$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number')

# 2. Check CI status
gh pr checks $pr_number  # all must pass

# 3. Check unpushed commits
git rev-list --count origin/<branch>..<branch>  # must be 0

# 4. Check human review comments after last commit (ignore bots)
last_date=$(git log -1 --format=%cI)
gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
  --jq "[.[] | select(.created_at > \"$last_date\") | select(.user.type == \"User\")] | length"

# 5. Check unresolved review threads (ignore RESOLVED)
gh pr view $pr_number --json reviewThreads --jq '.reviewThreads[] | select(.isResolved == false) | .comments[0].body'
```

**Gate logic:**
- IF (CI == pass) AND (unpushed == 0) AND (new_human_comments == 0) AND (unresolved_threads == 0):
  - Mark PR done-done.
  - Run `bash ~/Desktop/shadow/scripts/auto_nixelo_cycle.sh` which handles: disable PR-CI → merge PR → checkout main → new date branch → enable manual cron → Telegram notification.

### 3.2) Auto-Nixelo Mode (added 2026-03-23)

**GATE CHECK (added 2026-03-30):** Before ANY auto-nixelo action (TODO exhaustion transition, PR-CI enable, auto_nixelo_cycle.sh), heartbeat MUST read `~/Desktop/shadow/auto-nixelo-enabled.json`. If `{"enabled": false}`, skip ALL auto-nixelo logic for this cycle. No exceptions. This file is the kill switch controlled by automationctl.

**Full lifecycle — runs automatically, no human intervention needed:**

1. `manual-terminal-nixelo.timer` triggers OpenCode manual dispatch for nixelo TODO work
2. TODO exhaustion detection (heartbeat OR manual-ping path):
   - Each heartbeat cycle, if `manual-terminal-nixelo.timer` is active, check `grep -c '^\- \[ \]' <task_file>` in the repo.
   - If 0 open items, check diff size to decide next mode:
     ```bash
     code_changes=$(git diff main --name-only | grep -cv '\.md$' || echo 0)
     ```
     - `code_changes > 0` (meaningful code shipped) → disable manual timer → enable **PR-CI** cron → send Telegram notification.
     - `code_changes == 0` (only .md or nothing) → disable manual timer → enable **agent** timer → send Telegram notification.
    - The OpenCode manual-ping path also detects TODO exhaustion independently (existing behavior, belt-and-suspenders).
3. PR-CI cron handles review/fix cycles (existing behavior)
4. Heartbeat detects done-done → calls `scripts/auto_nixelo_cycle.sh` which:
   - Disables PR-CI cron
   - Merges PR via `gh pr merge --squash --delete-branch`
   - Checks out `main`, pulls
   - Creates new branch `YYYY-MM-DD-HH-MM`
   - Enables `manual-terminal-nixelo.timer`
   - Sends Telegram notification
5. Loop back to step 1

**Heartbeat integration:** Each heartbeat cycle, if `pr-ci-nixelo` is enabled, run the auto-nixelo script. It handles all gate checks internally and outputs a status line.

**Assumptions:**
- `pnpm dev` is always running (managed by user)
- OpenCode session bootstrap for `nixelo` is available via `scripts/opencodectl ensure-session nixelo`
- Branch naming: `YYYY-MM-DD-HH-MM` (e.g. `2026-03-23-19-14`)

---

## Cron Reports (Morning/Nightly)

**CRITICAL:** Cron jobs for reports run in the **main** session (`sessionTarget: "main"`) triggered by a `systemEvent`. Do NOT use `isolated` session with `agentTurn`, as the isolated agent cannot self-send messages reliably.

**Trigger prompts:**
- Morning: `[Cron Trigger] Generate Morning Report`
- Nightly: `[Cron Trigger] Generate Nightly Report`

When you see these system events in the main session:
1. Generate the report immediately using available tools.
2. Send it via `message` tool to `telegram`.
3. Do NOT reply to the system event itself (use `NO_REPLY` if needed to close turn).

---

### 4) Recovery action

If **Stalled** or **At risk**:
1. Check `last_action` in tmux
2. **Targeted nudge**: next incomplete item + "run checks + commit"
3. If still stalled, send `C-c`, then re-send targeted instruction

**IMPORTANT:** send text and Enter as TWO separate `tmux send-keys` calls.

After each attempt:
- Re-capture pane output and confirm `Working` appears.
- Re-check latest commit age/subject.

### 5) Escalation rule

Alert Mikhail only when:
- recovery attempts exceed `max_attempts_before_escalate`, or
- session re-stalls immediately after recovery, or
- explicit blocking error persists, or
- runtime mode/behavior is harmful (prompt/error loops, no-op churn, token burn without progress, clearly unintended mixed state), or
- PR-CI cannot reach green due to a verified human-only blocker.

Do **not** alert merely because a terminal has not stopped yet during the 15-minute handoff grace window.

Do **not** alert on ON/OFF state alone if current behavior is healthy and aligned with current intent.

If no attention needed in any mode, reply exactly: `HEARTBEAT_OK`

### 6) Quick status commands

```bash
tmux capture-pane -t nixelo -p | tail -5
tmux capture-pane -t starthub -p | tail -5
```

---

## Intervention Log

### 2026-03-18 09:30 CDT — Cron Delivery Repair
- Morning/Nightly reports were failing to deliver because `isolated` session agents lack the `message` tool.
- Fix: Switched both crons to `sessionTarget: "main"` + `systemEvent` trigger.
- Now, when the cron fires, it injects a system message into the main session, prompting the main assistant (me) to generate and send the report directly.
- **Action:** Manual intervention complete. No further action needed.

### 2026-03-18 09:30 CDT — Cron Delivery Repair
- Morning/Nightly reports were failing to deliver because `isolated` session agents lack the `message` tool.
- Fix: Switched both crons to `sessionTarget: "main"` + `systemEvent` trigger.
- Now, when the cron fires, it injects a system message into the main session, prompting the main assistant (me) to generate and send the report directly.
- **Action:** Manual intervention complete. No further action needed.
