#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Desktop/shadow"
USERD="$HOME/.config/systemd/user"

ok() { echo "OK   $*"; }
warn() { echo "WARN $*"; }
fail() { echo "FAIL $*"; exit 1; }

expect_file_contains() {
  local file="$1" needle="$2"
  grep -Fq "$needle" "$file" || fail "$file missing: $needle"
  ok "$file contains: $needle"
}

# 1) Canonical repo files must exist
for f in \
  systemd/manual-terminal-nixelo.service \
  systemd/manual-terminal-nixelo.timer \
  systemd/manual-terminal-starthub.service \
  systemd/manual-terminal-starthub.timer \
  systemd/agent-terminal-nixelo.service \
  systemd/agent-terminal-nixelo.timer \
  systemd/agent-terminal-starthub.service \
  systemd/agent-terminal-starthub.timer \
  systemd/prci-terminal-nixelo.service \
  systemd/prci-terminal-nixelo.timer \
  systemd/prci-terminal-starthub.service \
  systemd/prci-terminal-starthub.timer
  do
  [[ -f "$REPO/$f" ]] || fail "missing repo file: $f"
  ok "repo file present: $f"
done

# 2) Legacy combined and legacy nightly files must be absent in repo
for f in \
  systemd/tmux-agent-work-ping.timer \
  systemd/tmux-agent-work-ping.service \
  systemd/agents-nightly-terminal-nixelo.timer \
  systemd/agents-nightly-terminal-nixelo.service \
  systemd/agents-nightly-terminal-starthub.timer \
  systemd/agents-nightly-terminal-starthub.service
  do
  [[ ! -e "$REPO/$f" ]] || fail "legacy file still exists in repo: $f"
  ok "legacy repo file absent: $f"
done

# 3) Schedule integrity for canonical timers (1m)
expect_file_contains "$REPO/systemd/manual-terminal-nixelo.timer" "OnCalendar=*-*-* *:*:00"
expect_file_contains "$REPO/systemd/manual-terminal-starthub.timer" "OnCalendar=*-*-* *:*:00"
expect_file_contains "$REPO/systemd/agent-terminal-nixelo.timer" "OnCalendar=*-*-* *:*:00"
expect_file_contains "$REPO/systemd/agent-terminal-starthub.timer" "OnCalendar=*-*-* *:*:00"
expect_file_contains "$REPO/systemd/prci-terminal-nixelo.timer" "OnCalendar=*-*-* *:*:00"
expect_file_contains "$REPO/systemd/prci-terminal-starthub.timer" "OnCalendar=*-*-* *:*:00"

# 4) Ping script reliability signatures still present
AGENT_PING_SCRIPT="$REPO/scripts/agent-terminal-ping"
PRCI_PING_SCRIPT="$REPO/scripts/prci-terminal-ping"
expect_file_contains "$REPO/systemd/manual-terminal-nixelo.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl manual-ping nixelo'
expect_file_contains "$REPO/systemd/manual-terminal-starthub.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl manual-ping starthub'
expect_file_contains "$REPO/systemd/manual-terminal@.service.template" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl manual-ping %i'
expect_file_contains "$REPO/systemd/agent-terminal-nixelo.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl agent-ping nixelo'
expect_file_contains "$REPO/systemd/agent-terminal-starthub.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl agent-ping starthub'
expect_file_contains "$REPO/systemd/agent-terminal@.service.template" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl agent-ping %i'
expect_file_contains "$REPO/systemd/prci-terminal-nixelo.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl prci-ping nixelo'
expect_file_contains "$REPO/systemd/prci-terminal-starthub.service" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl prci-ping starthub'
expect_file_contains "$REPO/systemd/prci-terminal@.service.template" 'ExecStart=/home/mikhail/Desktop/shadow/scripts/opencodectl prci-ping %i'
expect_file_contains "$AGENT_PING_SCRIPT" 'send_tmux_text_enter "$target" "$msg"'
expect_file_contains "$AGENT_PING_SCRIPT" 'terminal_send_preflight "$session" "$workdir"'

if ! grep -Fq 'source "$SCRIPT_DIR/terminal_mode_guard.sh"' "$AGENT_PING_SCRIPT" 2>/dev/null; then
  warn "agent-terminal-ping missing: source \$SCRIPT_DIR/terminal_mode_guard.sh (non-critical, using TERMINAL_MODE_GUARD env)"
fi
if ! grep -Fq 'source "$SCRIPT_DIR/terminal_mode_guard.sh"' "$PRCI_PING_SCRIPT" 2>/dev/null; then
  warn "prci-terminal-ping missing: source \$SCRIPT_DIR/scripts/terminal_mode_guard.sh (non-critical, using TERMINAL_MODE_GUARD env)"
fi
expect_file_contains "$PRCI_PING_SCRIPT" 'echo "PR-CI: $output"'

# 5) OFF-policy awareness note (do not force-enable timers)
warn "timer runtime state is policy-driven; this verifier does not auto-require enabled/active"
echo "=== TIMER STATE CHECK ==="
for t in \
  manual-terminal-nixelo.timer \
  manual-terminal-starthub.timer \
  agent-terminal-nixelo.timer \
  agent-terminal-starthub.timer \
  prci-terminal-nixelo.timer \
  prci-terminal-starthub.timer
  do
  active="$(systemctl --user is-active "$t" 2>/dev/null || true)"
  enabled="$(systemctl --user is-enabled "$t" 2>/dev/null || true)"
  on="OFF"
  if systemctl --user is-enabled "$t" &>/dev/null && systemctl --user is-active "$t" &>/dev/null; then
    on="ON"
  fi
  echo "STATE $t active=$active enabled=$enabled on=$on"
done

# 6) Repo quality snapshot
cd "$REPO"
status="$(git status --porcelain)"
if [[ -n "$status" ]]; then
  warn "repo has uncommitted changes"
  git status -sb
else
  ok "repo working tree clean"
fi
ok "last commit: $(git log -1 --oneline)"

echo "VERIFY_OPENCLAW_OPS_OK"
