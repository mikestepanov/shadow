#!/usr/bin/env bash
set -euo pipefail

send_tmux_text_enter() {
  local target="$1"
  shift
  local txt="$*"

  tmux send-keys -t "$target" -l -- "$txt"
  sleep 1
  tmux send-keys -t "$target" Enter
  sleep 0.12
}
