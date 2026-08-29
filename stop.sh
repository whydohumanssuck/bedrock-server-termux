#!/usr/bin/env bash
# stop.sh -- stop the Bedrock server gracefully (sends the "stop" command,
# waits, then force-kills if needed).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

if ! is_running && ! { command -v tmux >/dev/null 2>&1 && tmux has-session -t bds 2>/dev/null; }; then
  info "Server is not running."
  exit 0
fi

# Tell the supervisor in start.sh that this stop is intentional so it does
# not auto-restart.
touch "${STOP_REQUESTED}"

stopped=0
if command -v tmux >/dev/null 2>&1 && tmux has-session -t bds 2>/dev/null; then
  info "Sending the 'stop' command to the server console..."
  tmux send-keys -t bds "stop" Enter
  # Wait up to 45 seconds for a clean shutdown.
  for _ in $(seq 1 45); do
    tmux has-session -t bds 2>/dev/null || { stopped=1; break; }
    sleep 1
  done
fi

if [ "${stopped}" -eq 0 ]; then
  pid="$(cat "${PIDFILE}" 2>/dev/null)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    warn "Server did not stop cleanly; sending SIGTERM to pid ${pid}."
    kill "${pid}" 2>/dev/null || true
    sleep 5
  fi
  # Last resort: kill any remaining BDS processes.
  pkill -f 'bedrock_server' 2>/dev/null && sleep 2 || true
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t bds 2>/dev/null || true
  fi
fi

rm -f "${PIDFILE}" "${STOP_REQUESTED}"
ok "Server stopped."
exit 0
