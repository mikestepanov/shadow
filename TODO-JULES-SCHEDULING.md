# TODO: Jules Task Scheduling

## ⚠️ CRITICAL - READ THIS FIRST

**Jules runs its own scheduled tasks. NOT OpenClaw.**

- OpenClaw cron jobs = for PR review automation ONLY (5 jobs exist, done)
- Jules scheduled tasks = the 100 daily agent tasks (TODO - create in Jules UI)

**DO NOT create OpenClaw cron jobs to automate Jules task creation. That was wrong.**

---

## What OpenClaw Does (DONE ✅)

5 cron jobs for PR review automation:
1. Jules PR Review (00-06)
2. Jules PR Review (06-12)
3. Jules PR Review (12-18)
4. Jules PR Review (18-24)
5. Nightly Sub-Agent Report

**This is ALL OpenClaw should do. Nothing else.**

---

## What Jules Does (TODO 🔴)

100 scheduled tasks/day running INSIDE JULES using Jules' built-in scheduling.

### Schedule Reference
**READ:** `~/.openclaw/workspace/JULES-SCHEDULING-GUIDE.md`

Contains:
- Exact times for all 90 Nixelo tasks
- Exact times for all 10 StartHub tasks
- Agent allocations (Bolt 14, Sentinel 14, etc.)

### Prompts Location
```
~/.openclaw/workspace/jules-agents/
├── auditor.txt    (🔎 Auditor)
├── bolt.txt       (⚡ Bolt)
├── inspector.txt  (🔍 Inspector)
├── librarian.txt  (📦 Librarian)
├── palette.txt    (🎨 Palette)
├── refactor.txt   (🧬 Refactor)
├── schema.txt     (📐 Schema)
├── scribe.txt     (📚 Scribe)
├── sentinel.txt   (🛡️ Sentinel)
└── spectra.txt    (🧪 Spectra)
```

### Target Branches
- **Nixelo** → `main`
- **StartHub** → `dev`

### Jules Account
- URL: https://jules.google.com
- Account: mikhail.stepanov.customer@gmail.com
- Tier: Pro (100 tasks/day)

---

## Action Required

1. Open Jules UI in browser
2. Go to each repo (Nixelo, StartHub)
3. Create scheduled tasks using Jules' scheduling feature
4. Use exact times from `JULES-SCHEDULING-GUIDE.md`
5. Use exact prompts from `jules-agents/*.txt`
6. Set correct branch (main/dev)

---

## Status (Updated 2026-02-13 17:45 CST)

- [x] OpenClaw cron jobs cleaned up (only 5 remain)
- [x] OpenClaw cron jobs RE-ENABLED (2026-02-12 22:57 CST)
- [x] StartHub: 10/10 tasks COMPLETE ✅
- [x] **Nixelo Bolt: 14/14 tasks COMPLETE ✅**
- [ ] Nixelo: 19/90 tasks created (14 Bolt + 5 other agents)
  - Need to create ~71 more tasks for other agents

## ⚠️ CRITICAL BUG - Jules Session Page

**The Jules session page ignores the URL `repo=` parameter!**

The dropdown always shows whatever repo was last selected in that browser session, NOT what the URL says. This caused tasks intended for Nixelo to be created in StartHub.

### Workaround
1. **ALWAYS** check the dropdown shows correct repo before EVERY submission
2. Manually click dropdown and select the right repo each time
3. Do NOT trust the URL to set the repo

---

## Next Steps

1. Verify exact task counts in both repos
2. Continue creating Nixelo tasks (need ~77 more)
3. Use "New" button from repo Overview page instead of session URL
