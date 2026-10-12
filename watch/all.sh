#!/usr/bin/env bash
# Opens all four watchers in a 2x2 tmux session (or prints the commands if tmux is missing).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
S=edge-watch
if ! command -v tmux >/dev/null; then
  warn "tmux not installed; run these in four terminals:"
  for w in raw edge cloud link; do echo "  watch/$w.sh"; done
  exit 0
fi
tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -c "$REPO_ROOT" "watch/edge.sh"
tmux split-window -t "$S" -h -c "$REPO_ROOT" "watch/cloud.sh"
tmux split-window -t "$S:0.0" -v -c "$REPO_ROOT" "watch/raw.sh"
tmux split-window -t "$S:0.2" -v -c "$REPO_ROOT" "watch/link.sh"
tmux select-layout -t "$S" tiled >/dev/null
if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$S"; else tmux attach -t "$S"; fi
