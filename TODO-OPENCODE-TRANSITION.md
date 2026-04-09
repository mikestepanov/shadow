# TODO-OPENCODE-TRANSITION.md

Remaining TODO only.

## 0. Manual/Agent Cron - ENABLED ✓

Manual and agent cron is now working:

- Both `manual-terminal-nixelo.timer` and `manual-terminal-starthub.timer` are active and running
- Session lookup now uses direct `/session/{id}` API to find stored sessions (not limited by `all` param)
- `ensureManualSession` correctly finds existing sessions and avoids recreation
- `dispatchAttachedPrompt` properly sends prompts to existing sessions

Key fixes applied:
1. Added `getSessionById` function that fetches `/session/{id}` directly instead of filtering `/session`
2. Added `all=true` to listSessions calls to include sessions from other projects
3. Fixed session title matching to use prefix matching (`startsWith`) for "nixelo-test" matching "nixelo"

Problems:

- `promptSessionAsync` fires and returns immediately (non-blocking), does not wait for completion
- OpenCode `/session/status` endpoint incorrectly reports sessions as "busy" when idle - cannot trust it
- Detached spawn for attached prompts doesn't work - session never receives the work
- Every minute dispatches a new prompt while previous is still running (or stuck)
- Session state detection uses buggy status endpoint instead of message inspection

What needs to be fixed for re-enable:

1. **Blocking dispatch**: Must wait for completion before returning. Either:
   - Use a synchronous/blocking prompt call that waits for response
   - Or track running state and skip dispatch if already busy until it completes

2. **Session state detection**: Stop using `/session/status`. Instead:
   - Check latest message - if last assistant message has no step-finish/stop, it's busy
   - Or check for running tool calls in latest message parts

3. **No duplicate dispatch**: If session is already processing, skip this cycle - don't queue multiple prompts

4. **Test properly**: Before re-enabling, verify dispatch actually reaches session and gets a response

## 1. Canonical Repo Session Reliability

Remaining issue:

- manual/agent automation can keep targeting a stale historical OpenCode session after `opencode.service` restart or visible tab loss
- when that happens, cron/timers stay ON but useful work stops

Tasks:

1. Stop treating historical message availability as proof that a repo automation session is still live enough for dispatch.
2. Make manual/agent dispatch use a real attached OpenCode execution path on each run.
3. Recreate the canonical repo session automatically when the stored session is stale after restart.
4. Keep one canonical automation session per repo (`nixelo`, `starthub`) without blocking extra manual user sessions.
5. Prove recovery by restarting `opencode.service` and verifying the next timer-driven dispatch still works without a visible tab.

Acceptance criteria:

1. If the visible tab dies, the next scheduled manual/agent dispatch still performs useful work.
2. If `opencode.service` restarts, automation recreates or reuses the canonical repo session correctly.
3. Nixelo/starthub no longer sit in a false-success state where cron/timers are ON but nothing is executing.

## 2. Timer/Cron Terminology Cleanup

Remaining issue:

- operator docs and conversation shorthand were inconsistent about whether systemd timer automation counts as "cron"

Tasks:

1. Keep docs and operator language aligned: both systemd timer automation and OpenCode cron jobs count as cron in conversation.
2. Use precise labels only when needed: `manual cron` / `timer cron` vs `PR-CI cron` / `OpenCode cron`.
3. Remove wording that implies only `pr-ci-*` jobs count as cron-enabled automation.

Acceptance criteria:

1. Repo docs and operator conversation use one consistent meaning of "cron".
2. Nixelo manual timer being ON is clearly understood as cron ON.

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
