# Jules Bot Scheduling Guide

## Overview
- **Daily limit:** 100 tasks (Pro tier)
- **Nixelo:** 90 bots (10 types)
- **StartHub:** 10 bots (1 of each type)
- **Buffer:** 0 (full allocation)

## Agent Types (10 total)

| Agent | Emoji | Focus | Nixelo | StartHub |
|-------|-------|-------|---------|----------|
| Bolt | ⚡ | Performance | 14 | 1 |
| Sentinel | 🛡️ | Security | 14 | 1 |
| Spectra | 🧪 | Test coverage | 14 | 1 |
| Auditor | 🔎 | Consistency | 10 | 1 |
| Palette | 🎨 | UX/accessibility | 9 | 1 |
| Inspector | 🔍 | Error handling | 9 | 1 |
| Refactor | 🧬 | Code structure | 8 | 1 |
| Schema | 📐 | API consistency | 6 | 1 |
| Scribe | 📚 | Documentation | 5 | 1 |
| Librarian | 📦 | Dependencies | 1 | 1 |
| **Total** | | | **90** | **10** |

## Naming Convention

**Bot names:** `[Agent]-[Repo]-[Number]`

Examples:
- `Bolt-Nixelo-01` through `Bolt-Nixelo-14`
- `Sentinel-StartHub-01`
- `Auditor-Nixelo-01` through `Auditor-Nixelo-10`

## Branch Prefixes

| Agent | Branch Prefix |
|-------|---------------|
| Bolt | `bolt/` |
| Sentinel | `sentinel/` |
| Spectra | `spectra/` |
| Auditor | `auditor/` |
| Palette | `palette/` |
| Inspector | `inspector/` |
| Refactor | `refactor/` |
| Schema | `schema/` |
| Scribe | `scribe/` |
| Librarian | `librarian/` |

## Nixelo Bot Schedule (90 bots)

Interleaved throughout 24h to avoid merge conflicts:

### High Priority (14 each)
**Bolt ⚡ (14):** 00:00, 01:45, 03:30, 05:15, 07:00, 08:45, 10:30, 12:15, 14:00, 15:45, 17:30, 19:15, 21:00, 22:45
**Sentinel 🛡️ (14):** 00:30, 02:15, 04:00, 05:45, 07:30, 09:15, 11:00, 12:45, 14:30, 16:15, 18:00, 19:45, 21:30, 23:15
**Spectra 🧪 (14):** 01:00, 02:45, 04:30, 06:15, 08:00, 09:45, 11:30, 13:15, 15:00, 16:45, 18:30, 20:15, 22:00, 23:45

### Medium Priority
**Auditor 🔎 (10):** 01:15, 03:45, 06:00, 08:30, 10:45, 13:00, 15:30, 17:45, 20:00, 22:30
**Palette 🎨 (9):** 00:15, 02:45, 05:30, 08:15, 11:00, 13:45, 16:30, 19:15, 22:00
**Inspector 🔍 (9):** 00:45, 03:30, 06:15, 09:00, 11:45, 14:30, 17:15, 20:00, 22:45

### Lower Priority
**Refactor 🧬 (8):** 01:30, 04:30, 07:30, 10:30, 13:30, 16:30, 19:30, 22:30
**Schema 📐 (6):** 02:00, 06:00, 10:00, 14:00, 18:00, 22:00
**Scribe 📚 (5):** 03:00, 07:00, 12:00, 17:00, 21:00
**Librarian 📦 (1):** 12:00 (midday, dependencies rarely change)

## StartHub Bot Schedule (10 bots)

One of each type, spread throughout the day:

| Time | Agent |
|------|-------|
| 00:00 | Bolt ⚡ |
| 02:30 | Sentinel 🛡️ |
| 05:00 | Spectra 🧪 |
| 07:30 | Auditor 🔎 |
| 10:00 | Palette 🎨 |
| 12:30 | Inspector 🔍 |
| 15:00 | Refactor 🧬 |
| 17:30 | Schema 📐 |
| 20:00 | Scribe 📚 |
| 22:30 | Librarian 📦 |

## Prompt Files

Location: `~/.openclaw/workspace/jules-agents/`

```
auditor.txt
bolt.txt
inspector.txt
librarian.txt
palette.txt
refactor.txt
schema.txt
scribe.txt
sentinel.txt
spectra.txt
```

## Rules

1. **Stay Small:** Aim for < 500 lines per PR
2. **Log Big:** If work can't be done in one task, create `/todos/jules-[agent]-[date]-[issue].md`
3. **Journals:** Each agent keeps learnings in `.jules/[agent].md` (lowercase!)
4. **One task per bot per day:** Each bot instance runs once daily

## PR Review Automation

OpenClaw cron jobs review Jules PRs every 30 minutes:
- **00-06 CST:** Gemini Pro High
- **06-12 CST:** Gemini Flash
- **12-18 CST:** Gemini Pro High
- **18-24 CST:** Gemini Flash

PRs are auto-reviewed, fixed if needed, and squash-merged.
