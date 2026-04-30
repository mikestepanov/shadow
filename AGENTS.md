# AGENTS.md - Universal AI Context

## 🚨 MANDATORY: Project Rules & Conventions

**You must read and strictly follow [RULES.md](./RULES.md).**
This file contains the single source of truth for:
- Coding standards & patterns
- Security & Safety protocols
- Testing requirements
- Deployment procedures

## 🤖 Context & Role

**StartHub** is an educational platform for entrepreneurs (starthub.academy). You are working in a large TypeScript monorepo (2000+ files) that values:
- **Type safety** above convenience (ZERO TOLERANCE for `any`)
- **Explicit** over implicit patterns
- **Clean architecture** with domain boundaries
- **Progressive enhancement** over breaking changes

## 📚 Documentation Map

- **Rules**: `[RULES.md](./RULES.md)` (The Law - Read this first)
- **Features**: `[/docs/features/feature-index.md](./docs/features/feature-index.md)`
- **Docs**: `[/docs/README.md](./docs/README.md)` (Architecture & Guides)
- **Internal**: `[/hidden/INDEX.md](./hidden/INDEX.md)` (Internal context & TODOs)

## 🚨 Critical Safety Protocols

### Multi-Instance Safety
**⚠️ WARNING: Multiple AI instances may be working simultaneously.**
- ❌ **NEVER** use `git reset --hard` (Destroys others' work)
- ❌ **NEVER** use `git stash` (Conflicts with others)
- ❌ **NEVER** use `git revert <commit>` (May revert others' commits)
- ❌ **NEVER** use `git commit --amend` (Rewrites history)
- ✅ **ALWAYS** fix mistakes with NEW commits
- ✅ **ALWAYS** check `git log` before changes

### TypeScript - ZERO TOLERANCE
- ❌ `any`, `as unknown as`, `@ts-ignore`, `@ts-expect-error`
- ❌ Non-null assertion `!` to bypass checks
- ✅ Fix types properly or don't write the code

### File Operations - CRITICAL
- **Deletion**: Mandatory 3-step verification:
  1. `grep -r "EntityName" src/` (Check references)
  2. Check domain dependencies
  3. `pnpm typecheck` (Runtime check)
- **Creation**: Ask permission before creating new files (especially .md)
- **Scripts**: Never write bulk modification scripts without permission

### GitOps - GIT IS SOURCE OF TRUTH
- ❌ **NEVER** configure tools to update Kubernetes/ArgoCD directly without git
- ❌ **NEVER** use in-memory overrides that bypass git
- ✅ **ALWAYS** use git write-back when setting up automation (ArgoCD Image Updater, etc.)
- ✅ **ALWAYS** ensure changes are committed to git, not just applied to cluster
- **Why**: Direct cluster updates get overwritten on next git sync. Git must be the single source of truth for all deployments.

### Deployment Workflow
- ✅ **ALWAYS** Create release tags on the `dev` branch first.
- ✅ **THEN** Merge `dev` (with tag) into `main`.
- **Reason**: Ensures the tag exists in `dev` history without needing a backward merge.

## 🚀 Workflow & Protocols

### First 5 Minutes
1. **Context**: Read `/hidden/INDEX.md` (if exists) and `RULES.md`.
2. **Status**: Check `git status` and `git log` to understand recent activity.
3. **Plan**: Validate understanding before writing code.

### Shell Shortcut Verification
- For shell helpers like `nixelo`, `starthub`, and `axon`, treat `~/Desktop/shadow/nixos/common.nix` as the repo source of truth.
- Verify the live generated config in `/etc/bashrc` before claiming the NixOS config is wrong or missing.
- Run `type nixelo` and inspect `~/.bashrc` for masking aliases/functions before concluding the problem is in `shadow`.

### Shell Command Compatibility
- Do not use `rg` in ad-hoc bash commands unless you verified `rg` is available in that shell first.
- For filtering command output in shell pipelines, prefer `grep` because it is present on the base system here.

### Code Validation (Run after completing a significant chunk of work)
1. **Run `pnpm fixme`** after finishing a feature, multi-file refactor, or major bug fix. This auto-fixes lint/format, rebuilds shared packages, and typechecks. Do NOT run after every small edit — only when a logical unit of work is done.
2. **Verify**: Check imports if modifying exports.
3. **Per-file validation**: `pnpm validate-changes` or `pnpm biome check --write path/to/file.ts` for quick single-file checks.

### Essential Commands
```bash
# Development
pnpm dev:with-web    # Backend + Client
pnpm dev:backend-only   # Backend only
pnpm fixme              # Auto-fix lint + rebuild packages + typecheck (after big changes)
pnpm validate-changes   # Quick per-file validation

# Testing
pnpm test              # All tests
pnpm playwright        # E2E tests
```

### Operational Truth Protocol (MANDATORY)
For any operational/system state claim (timers, services, processes, automation state), you must:
1. Execute the requested action.
2. Run a separate verification command immediately after.
3. Report only verified facts from command output.

Hard rules:
- Never claim "done", "stopped", "running", or similar without fresh verification output.
- If output is missing/ambiguous, explicitly say verification is incomplete.
- Prefer exact state terms from system output (`active`, `inactive`, `failed`, `enabled`, `disabled`, `masked`).
- If verification cannot be performed, say so directly and do not infer state.
- For `manual-terminal-*` timers, `active` + `enabled` is not enough. Also verify the related `manual-terminal-*.service` journal shows a fresh working outcome (`SENT ...` or another explicitly acceptable dispatch result), not just `NOOP:terminal-stuck`, `BLOCKED_HUMAN`, or silence.

## 🔐 Infrastructure Access

AI agents have full access to:
- **kubectl** - Kubernetes cluster management (all namespaces: dev, staging, production)
- **AWS CLI** - AWS services (via configured credentials)
- **GitHub CLI (gh)** - Repository management, PRs, issues, packages
- **Docker/GHCR** - Container registry access

### Database Seeding (Production)

Production uses AWS DocumentDB in a private VPC. To seed production:

1. **Cannot run locally** - DocumentDB is not reachable from local machine
2. **Must run inside K8s cluster** - Use a Job or exec into a pod with the seeding scripts

**Seeding via K8s Job:**
```bash
# The backend image doesn't include seeding scripts (only compiled main.js)
# Need to create a seed job that mounts the source or use a dev image
kubectl apply -f infrastructure/k8s/jobs/seed-prod.yaml
```

**Alternative - Use GraphQL mutations** to seed data through the running backend API.

## 📝 Communication Style
- **BE DIRECT**: No "likely", "probably", "maybe", "should". Check first, then state facts.
- **BE CONCRETE**: "42 errors found" not "some errors".
- **BE PROACTIVE**: Suggest improvements (e.g., "Want me to apply this pattern elsewhere?").
- **SELF-CORRECT**: If you make a mistake, admit it and fix it with a new commit.
- **CHECK BEFORE SPEAKING**: Don't guess. Run the command, read the file, verify the state. Then report what you found.

## Multi-Account Setup

**NEVER ask about API keys.** Use OAuth login or plugins only.

```bash
opencode-multi-auth add <alias>
opencode-multi-auth list
opencode-multi-auth status
```

Plugin: `@a3fckx/opencode-multi-auth`

Commands:
- `opencode-multi-auth add <alias>`
- `opencode-multi-auth list`
- `opencode-multi-auth status`
- `opencode-multi-auth remove <alias>`
