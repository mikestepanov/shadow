# Repository Rules

## CRITICAL: Use ONLY agent copy repos

| Project | ❌ NEVER TOUCH | ✅ USE THIS |
|---------|---------------|-------------|
| StartHub | `~/Desktop/StartHub` | `~/Desktop/starthub-agent` |
| Nixelo | `~/Desktop/nixelo` | `~/Desktop/nixelo-agent` |

Other repos on Desktop: `axon`, `hehehe`, `omega`, `orion`, `chronos`, `artichoke`, `nixos-config` — avoid unless explicitly asked.

### 2026-02-14 Incident
- Accidentally cherry-picked #1377 to `~/Desktop/StartHub` dev branch
- Pushed to origin/dev
- Should have used `~/Desktop/starthub-agent` instead
