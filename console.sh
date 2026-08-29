#!/usr/bin/env bash
# console.sh -- interactive server console.
#
# Sends commands to the running server through the control FIFO and shows the
# server log. Leave with Ctrl+C (or Ctrl+D). Note: this is a command/ log
# console, not a raw PTY, which is what works reliably inside proot.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

CTRL_FIFO="${LOGS_DIR}/control.fifo"

if ! is_running; then
  die "Server is not running. Start it with ./start.sh first."
fi
if [ ! -p "${CTRL_FIFO}" ]; then
  die "Control FIFO missing (${CTRL_FIFO}). Restart the server with ./start.sh."
fi

info "Console attached. Type commands (e.g. list, help), press Ctrl+C to leave."

# Show recent + live log output while reading commands.
tail -n 30 -f "${SERVER_LOGFILE}" 2>/dev/null &
TAIL_PID=$!
trap 'kill ${TAIL_PID} 2>/dev/null; exit 0' INT TERM EXIT

while IFS= read -r -p '> ' cmd; do
  [ -n "${cmd}" ] && printf '%s\n' "${cmd}" > "${CTRL_FIFO}"
done
echo
exit 0
