# GUARDRAILS.md

## Protected files policy

**Rule:** Do not modify protected files unless the user explicitly requests that exact file/scope.

Protected files:
- `HEARTBEAT.md`
- `~/Desktop/shadow/scripts/terminal-automation`
- `~/Desktop/shadow/scripts/pr_done_merge.sh`
- `~/Desktop/shadow/scripts/pr_ci_nixelo_dispatch.sh`
- `~/Desktop/shadow/scripts/pr_ci_starthub_dispatch.sh`

## Approval requirement

Before editing any protected file, confirm:
1. File is explicitly named or unambiguously included by the user.
2. Requested scope is mapped before execution.
3. No unrelated edits are included.

## Commit safeguard token

If a commit includes protected files, commit message must include:

`ALLOW_PROTECTED_EDIT`
