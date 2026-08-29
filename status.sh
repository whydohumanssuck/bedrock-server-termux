#!/usr/bin/env bash
# status.sh -- show whether the server is running, plus quick health info.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

if is_running; then
  ok "Server is RUNNING (pid $(cat "${PIDFILE}" 2>/dev/null))."
else
  warn "Server is NOT running."
fi
echo "Architecture : $(machine_arch)"
echo "box64        : $(have_box64 && echo yes || echo no)"
[ -d "${SERVER_DIR}" ] && echo "Server dir   : ${SERVER_DIR}"
[ -f "${SERVER_LOGFILE}" ] && echo "Last log line: $(tail -1 "${SERVER_LOGFILE}" 2>/dev/null)"
exit 0
