#!/usr/bin/env bash
# start.sh -- start the Bedrock server, keep it alive across crashes, and log
# everything. Safe to run from any directory or from proot/termux.
#
# The server runs in a tmux session named "bds". Detach with Ctrl+B then D,
# re-attach with ./tmux-console.sh, and stop with ./stop.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

# On Termux/ARM64, run inside the Debian container.
if should_use_distro; then bounce_into_distro "$@"; fi

if [ "$(id -u)" -ne 0 ] && ! is_termux; then
  warn "Not running as root; the server may not bind privileged ports (not needed for 19132)."
fi

# ---------------- guards -----------------------------------------------------
[ -x "${BDS_BIN}" ] || die "Server binary not found (${BDS_BIN}).
Run ./install.sh first."

if command -v tmux >/dev/null 2>&1; then
  if tmux -S "${TMUX_SOCKET}" has-session -t bds 2>/dev/null; then
    if is_running; then
      ok "Server is already running (pid $(cat "${PIDFILE}"))."
      echo "Attach:  ./tmux-console.sh   Stop:  ./stop.sh"
      exit 0
    fi
    warn "Found stale tmux session; killing it."
    tmux -S "${TMUX_SOCKET}" kill-session -t bds 2>/dev/null || true
  fi
else
  warn "tmux is not installed. Starting in the foreground instead; Ctrl+C to stop."
  run_foreground
  exit $?
fi

# ---------------- memory / CPU tuning ----------------------------------------
# These are harmless no-ops on most systems but help constrained Android phones.
export USE_XDG=1
# Ask the kernel to reclaim clean pages under memory pressure earlier.
if [ -w /proc/sys/vm/swappiness ]; then
  echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
fi

# Compute a bounded thread count for phones (32-bit or 64-bit).
cpus="$(nproc 2>/dev/null || echo 4)"
[ "${cpus}" -gt 8 ] && cpus=8
[ "${cpus}" -lt 1 ] && cpus=1
info "Detected ${cpus} CPU core(s)."

# ---------------- ensure dirs & config ----------------------------------------
ensure_runtime_dirs

rm -f "${STOP_REQUESTED}"

# ---------------- supervisord-like restart loop -------------------------------
SESSION="bds"
RESTART_COUNT=0
MAX_RESTART_BACKOFF=60
BACKOFF=2

start_instance() {
  local launch
  launch="$(server_launch_cmd)"
  rm -f "${TMUX_SOCKET}"  # stale socket from a previous, dead session
  info "Launching: cd ${SERVER_DIR} && ${launch} (in tmux session '${SESSION}')"
  tmux -S "${TMUX_SOCKET}" new-session -d -s "${SESSION}" "cd '${SERVER_DIR}' && exec ${launch} 2>&1 | tee -a '${SERVER_LOGFILE}'"
  # Record a pidfile for stop.sh. The tmux pane PID is a stable proxy for
  # "something is running"; stop.sh uses it to wait for a clean exit.
  local pid
  pid="$(tmux -S "${TMUX_SOCKET}" list-panes -t "${SESSION}" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [ -n "${pid}" ] && printf '%s\n' "${pid}" > "${PIDFILE}" || rm -f "${PIDFILE}"
}

log_cycle() {
  ( flock 9 || true
    if [ -f "${SERVER_LOGFILE}" ] && [ "$(du -k "${SERVER_LOGFILE}" 2>/dev/null | cut -f1)" -gt 10240 ]; then
      mv "${SERVER_LOGFILE}" "${SERVER_LOGFILE}.1" 2>/dev/null || true
      mv "${SERVER_LOGFILE}.1" "${SERVER_LOGFILE}.2" 2>/dev/null || true
    fi ) 9>"${LOGS_DIR}/.loglock"
}

while :; do
  start_instance

  # Inner supervision: wait while the tmux session (and thus the server) is
  # alive. If the BDS process dies, tmux ends the session and we restart.
  while tmux -S "${TMUX_SOCKET}" has-session -t "${SESSION}" 2>/dev/null; do
    sleep 5
  done
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
done
