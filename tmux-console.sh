#!/usr/bin/env bash
# tmux-console.sh -- attach to the running server console.
# Detach again with Ctrl+B then D (i.e. hold Ctrl, press B, release, press D).

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
if should_use_distro; then bounce_into_distro "$@"; fi

if ! command -v tmux >/dev/null 2>&1 || ! tmux -S "${TMUX_SOCKET}" has-session -t bds 2>/dev/null; then
  die "No running server session. Start it with ./start.sh first."
fi
exec tmux -S "${TMUX_SOCKET}" attach -t bds
