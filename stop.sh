#!/usr/bin/env bash
# stop.sh -- stop the Bedrock server gracefully (sends 'stop' via the control
# FIFO, waits, then SIGTERM/SIGKILL as fallbacks).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

CTRL_FIFO="${LOGS_DIR}/control.fifo"

if ! is_running; then
  info "Server is not running."
  exit 0
fi

# Tell the supervisor in start.sh that this stop is intentional so it does
# not auto-restart.
touch "${STOP_REQUESTED}"

pid="$(cat "${PIDFILE}" 2>/dev/null)"
stopped=0

if [ -p "${CTRL_FIFO}" ]; then
  info "Sending the 'stop' command to the server console..."
  printf 'stop\n' > "${CTRL_FIFO}" 2>/dev/null || true
  # Wait up to 45s for a clean shutdown.
  for _ in $(seq 1 45); do
    kill -0 "${pid}" 2>/dev/null || { stopped=1; break; }
    sleep 1
  done
fi

if [ "${stopped}" -eq 0 ]; then
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    warn "Server did not stop cleanly; sending SIGTERM to pid ${pid}."
    kill "${pid}" 2>/dev/null || true
    sleep 5
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    warn "Sending SIGKILL to pid ${pid}."
    kill -9 "${pid}" 2>/dev/null || true
  fi
  # Last resort sweep for any leftover BDS processes.
  pkill -f 'bedrock_server' 2>/dev/null && sleep 2 || true
fi

# Leave STOP_REQUESTED in place: the supervisor consumes (and removes) it,
# so it knows this exit was intentional and will not auto-restart.
rm -f "${PIDFILE}"
ok "Server stopped."
exit 0
