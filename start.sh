#!/usr/bin/env bash
# start.sh -- start the Bedrock server, keep it alive across crashes, and log
# everything. Safe to run from any directory or from proot/termux.
#
# The server reads console commands from a named pipe (logs/control.fifo):
#   ./stop.sh          graceful stop ("stop" command, then SIGTERM fallback)
#   ./console.sh       interactive console (type commands, Ctrl+D to leave)
#   ./status.sh        running? + health

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

# On Termux/ARM64, run inside the Debian container.
if should_use_distro; then bounce_into_distro "$@"; fi

[ -x "${BDS_BIN}" ] || die "Server binary not found (${BDS_BIN}). Run ./install.sh first."

server_pid() { cat "${PIDFILE}" 2>/dev/null || true; }

if is_running; then
  ok "Server is already running (pid $(server_pid))."
  echo "Console: ./console.sh   Stop: ./stop.sh"
  exit 0
fi

# ---------------- control FIFO ----------------------------------------------
# Commands typed into ./console.sh and ./stop.sh are written here; the server
# reads them from stdin. FIFOs survive proot session isolation (tmux sockets
# do not), so this works from any later Termux/proot login.
CTRL_FIFO="${LOGS_DIR}/control.fifo"
rm -f "${CTRL_FIFO}"
mkfifo -m 600 "${CTRL_FIFO}" 2>/dev/null || die "Could not create ${CTRL_FIFO}"
# Keep the read end open in this process so writers never block, even across
# server restarts.
exec 9<>"${CTRL_FIFO}"

# ---------------- memory / CPU tuning ---------------------------------------
cpus="$(nproc 2>/dev/null || echo 4)"
[ "${cpus}" -gt 8 ] && cpus=8
[ "${cpus}" -lt 1 ] && cpus=1
info "Detected ${cpus} CPU core(s)."

ensure_runtime_dirs
rm -f "${STOP_REQUESTED}"

# ---------------- launch + supervise ----------------------------------------
launch_server() {
  local launch
  launch="$(server_launch_cmd)"
  info "Launching: cd ${SERVER_DIR} && ${launch} (stdin <- control.fifo)"
  (
    cd "${SERVER_DIR}" || exit 1
    # Feed the FIFO (fd 9) to stdin, tee output to the rotating log.
    exec 0<&9
    exec ${launch} 2>&1 | tee -a "${SERVER_LOGFILE}"
  ) &
  SERVER_PID=$!
  printf '%s\n' "${SERVER_PID}" > "${PIDFILE}"
}

log_cycle() {
  ( flock 9 || true
    if [ -f "${SERVER_LOGFILE}" ] && [ "$(du -k "${SERVER_LOGFILE}" 2>/dev/null | cut -f1)" -gt 10240 ]; then
      mv "${SERVER_LOGFILE}" "${SERVER_LOGFILE}.1" 2>/dev/null || true
      mv "${SERVER_LOGFILE}.1" "${SERVER_LOGFILE}.2" 2>/dev/null || true
    fi ) 9>"${LOGS_DIR}/.loglock"
}

RESTART_COUNT=0
BACKOFF=2
MAX_RESTART_BACKOFF=60

launch_server

while :; do
  # Supervise: wait while the server process is alive.
  while kill -0 "${SERVER_PID}" 2>/dev/null; do
    sleep 5
  done
  wait "${SERVER_PID}" 2>/dev/null
  rm -f "${PIDFILE}"
  RESTART_COUNT=$((RESTART_COUNT + 1))
  log_cycle

  if [ -f "${STOP_REQUESTED}" ]; then
    ok "Stop requested; exiting."
    rm -f "${STOP_REQUESTED}"
    exit 0
  fi

  if [ "${RESTART_COUNT}" -ge 8 ]; then
    warn "Server has exited ${RESTART_COUNT} times in a row. Waiting ${MAX_RESTART_BACKOFF}s."
    warn "Check ${SERVER_LOGFILE} and fix the issue before restarting."
    sleep "${MAX_RESTART_BACKOFF}"
    RESTART_COUNT=0
    BACKOFF=2
  else
    warn "Server exited (attempt ${RESTART_COUNT}). Restarting in ${BACKOFF}s..."
    sleep "${BACKOFF}"
    [ "${BACKOFF}" -lt "${MAX_RESTART_BACKOFF}" ] && BACKOFF=$((BACKOFF * 2))
  fi

  launch_server
done
