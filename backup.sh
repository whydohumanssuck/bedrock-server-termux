#!/usr/bin/env bash
# backup.sh -- create a timestamped archive of the world(s), config, and packs.
#
# If the server is running the script first asks BDS to hold world saves
# ("save hold" / "save resume") so the world files are consistent.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

KEEP=${KEEP:-7}

if [ ! -d "${SERVER_DIR}/worlds" ]; then
  die "No worlds directory found. Install the server first (./install.sh)."
fi

stamp="$(date +%Y%m%d-%H%M%S)"
out="${BACKUP_DIR}/mc-backup-${stamp}.tar.gz"

# Ask a running server to hold world saves so the backup is consistent.
HOLD=""
if is_running && command -v tmux >/dev/null 2>&1 && tmux has-session -t bds 2>/dev/null; then
  info "Server is running; holding world saves while backing up."
  tmux send-keys -t bds "save hold" Enter
  sleep 2
  HOLD=1
fi

mkdir -p "${BACKUP_DIR}"
info "Backing up worlds + config -> ${out}"
tar -czf "${out}" \
  --exclude='*/db/LOCK' --exclude='session.lock' \
  -C "${SERVER_DIR}" \
  worlds server.properties allowlist.json permissions.json \
  behavior_packs resource_packs 2>/dev/null || {
    tar -czf "${out}" --exclude='session.lock' -C "${SERVER_DIR}" worlds server.properties 2>/dev/null \
      || die "Backup failed."
  }

if [ -n "${HOLD}" ]; then
  tmux send-keys -t bds "save resume" Enter 2>/dev/null || true
fi

size="$(du -h "${out}" 2>/dev/null | cut -f1)"
ok "Backup created: ${out} (${size})"

# Rotate: keep the ${KEEP} newest backups.
count="$(ls -1 "${BACKUP_DIR}"/mc-backup-*.tar.gz 2>/dev/null | wc -l)"
if [ "${count}" -gt "${KEEP}" ]; then
  ls -1t "${BACKUP_DIR}"/mc-backup-*.tar.gz 2>/dev/null | tail -n "$((count - KEEP))" | \
    while read -r old; do rm -f "${old}"; done
  info "Removed old backups; keeping the newest ${KEEP}."
fi
exit 0
