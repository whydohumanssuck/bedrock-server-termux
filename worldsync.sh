#!/usr/bin/env bash
# worldsync.sh -- share ONE Minecraft Bedrock world between two phones.
#
# No dedicated server required. Both people install Termux, the phones join
# the same Wi-Fi, and this script syncs the world folder between them.
# Also exports/imports .mcworld files for when the phones are apart.
#
#   ./worldsync.sh check    - verify this phone is ready
#   ./worldsync.sh list     - show worlds found on this phone
#   ./worldsync.sh export   - package the newest world as a .mcworld file
#   ./worldsync.sh import   - open a .mcworld file so Minecraft imports it
#   ./worldsync.sh push     - send MY world to the other phone (LAN, rsync)
#   ./worldsync.sh pull     - get the other phone's world (LAN, rsync)
#
# Put your settings in config/worldsync.conf (see the .example file).

set -u

if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  PROJECT_ROOT="$(pwd)"
fi
CONF="${PROJECT_ROOT}/config/worldsync.conf"
SYNC_DIR="${PROJECT_ROOT}/sync"
BACKUP_DIR="${PROJECT_ROOT}/backups"
STATE_FILE="${SYNC_DIR}/.worldsync-state"

# Overridable from config/worldsync.conf
PEER_USER=""
PEER_HOST=""
PEER_PORT="8022"
WORLD_FOLDER=""
MOJANG_ROOT="/storage/emulated/0/Android/data/com.mojang.minecraftpe/files/games/com.mojang"
KEEP_BACKUPS=7

if [ -f "${CONF}" ]; then
  # shellcheck disable=SC1090
  . "${CONF}"
fi

WORLDS_DIR="${MOJANG_ROOT}/minecraftWorlds"

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi
info()  { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

need()  { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. Install it: pkg install $1"; }

# display_name <world-folder>: read levelname.txt if present
display_name() {
  local f="${WORLDS_DIR}/$1/levelname.txt"
  if [ -f "${f}" ]; then tr -d '\r\n' < "${f}"; else echo "$1"; fi
}

# world_mtime <folder>: last-modified time of the world's level.dat
world_mtime() {
  stat -c %Y "${WORLDS_DIR}/$1/level.dat" 2>/dev/null || echo 0
}

list_worlds() {
  local n=0
  if [ ! -d "${WORLDS_DIR}" ]; then return 0; fi
  while IFS= read -r d; do
    n=$((n+1))
    printf '  [%d] %s  (%s)\n' "$n" "$(display_name "$(basename "$d")")" "$(basename "$d")"
  done < <(find "${WORLDS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if [ "${n}" -eq 0 ]; then
    warn "No worlds found in ${WORLDS_DIR}"
  fi
  return 0
}

pick_world_folder() {
  local choice
  if [ -n "${WORLD_FOLDER}" ] && [ -d "${WORLDS_DIR}/${WORLD_FOLDER}" ]; then
    printf '%s' "${WORLD_FOLDER}"
    return 0
  fi
  # Menu goes to stderr so the folder name is the ONLY thing printed to
  # stdout (callers capture it with $(...)).
  info "Worlds on this phone:" >&2
  list_worlds >&2
  printf 'Type the [number] of the world to use: ' >&2
  read -r choice || exit 1
  local folder
  folder="$(find "${WORLDS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | sed -n "$((choice))p")"
  [ -n "${folder}" ] || die "Invalid choice: ${choice}"
  printf '%s' "$(basename "${folder}")"
}

cmd_check() {
  info "Checking this phone..."
  need ssh; need rsync; need python3
  ok "ssh / rsync / python3 present"

  if [ -d "${WORLDS_DIR}" ]; then
    ok "Worlds folder found: ${WORLDS_DIR}"
    list_worlds
  else
    warn "Worlds folder not found: ${WORLDS_DIR}"
    info "On Android 11+, Termux needs permission to read Android/data.
  - Run  termux-setup-storage  (grant storage)
  - Settings > Apps > Termux > Permissions > Files and media > Allow all files
    (or on older Android: Files > grant)
  - Re-run this check afterwards."
  fi

  if [ -n "${PEER_USER}" ] && [ -n "${PEER_HOST}" ]; then
    ok "Peer configured: ${PEER_USER}@${PEER_HOST}:${PEER_PORT}"
    ssh -p "${PEER_PORT}" -o StrictHostKeyChecking=no \
        -o ConnectTimeout=8 "${PEER_USER}@${PEER_HOST}" \
        'command -v rsync >/dev/null 2>&1 && echo "  peer has rsync" || echo "  MISSING rsync on peer"' 2>/dev/null \
      || warn "Cannot reach peer. Are both phones on the same Wi-Fi and is sshd running on the peer?"
  else
    warn "No peer configured yet. Copy config/worldsync.conf.example to config/worldsync.conf and fill it in."
  fi
}

cmd_list() {
  [ -d "${WORLDS_DIR}" ] || die "Worlds folder not found: ${WORLDS_DIR}"
  info "Worlds in ${WORLDS_DIR}:"
  list_worlds
}

cmd_export() {
  need python3
  [ -d "${WORLDS_DIR}" ] || die "Worlds folder not found: ${WORLDS_DIR}"
  mkdir -p "${SYNC_DIR}"
  local folder
  folder="$(pick_world_folder)"
  local name
  name="$(display_name "${folder}" | tr ' /' '__')"
  local stamp out
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${SYNC_DIR}/${name}-${stamp}.mcworld"
  [ -e "${out}" ] && die "Already exists: ${out}"
  info "Packaging '${name}' (${folder}) -> ${out}"
  # level.dat must sit at the ZIP root for Minecraft to import the world.
  PYTHONPATH="${PROJECT_ROOT}" python3 - "${WORLDS_DIR}/${folder}" "${out}" << 'PYEOF'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            # Arc name relative to the world folder root (level.dat at top)
            z.write(full, os.path.relpath(full, src))
print("done")
PYEOF
  [ -f "${out}" ] || die "Export failed."
  ok "Exported: ${out}"
  info "Send this file to the other phone, then on that phone run:"
  info "  ./worldsync.sh import ${out}"
  if command -v termux-open >/dev/null 2>&1; then
    cp "${out}" /sdcard/Download/ 2>/dev/null || true
    info "Also copied to /sdcard/Download/ so it can be opened from the Files app."
  fi
  return 0
}

cmd_import() {
  [ -n "${1:-}" ] || die "Usage: ./worldsync.sh import <file.mcworld>"
  local file="$1"
  [ -f "${file}" ] || die "File not found: ${file}"
  info "Opening ${file} ..."
  if command -v termux-open >/dev/null 2>&1; then
    info "Choose 'Minecraft' when the picker appears. The world imports automatically."
    termux-open "${file}"
  else
    info "Termux-open not found. Copy the file to /sdcard/Download/ and tap it,
choose Minecraft, and it will import the world."
  fi
}

# newest_wins_check <local-mtime> <remote-mtime> <direction>
newest_wins_check() {
  local lm="$1" rm="$2" dir="$3"
  if [ "${rm}" -gt "${lm}" ]; then
    warn "The OTHER phone has a NEWER version of this world. Running ${dir} anyway overwrites their newer changes."
  elif [ "${lm}" -gt "${rm}" ]; then
    warn "THIS phone has a NEWER version of the world. Consider running the opposite command."
  else
    ok "Both sides have the same world version."
  fi
}

remote_world_mtime() {
  ssh -p "${PEER_PORT}" -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "${PEER_USER}@${PEER_HOST}" \
      "stat -c %Y '${PEER_WORLDS_DIR:-${WORLDS_DIR}}/${WORLD_FOLDER}/level.dat' 2>/dev/null || echo 0" 2>/dev/null
}

cmd_push() {
  [ -n "${PEER_USER}" ] && [ -n "${PEER_HOST}" ] || die "Peer not configured (config/worldsync.conf)"
  need ssh; need rsync
  [ -d "${WORLDS_DIR}" ] || die "Worlds folder not found: ${WORLDS_DIR}"
  WORLD_FOLDER="$(pick_world_folder)"
  local peer_worlds="${PEER_WORLDS_DIR:-${WORLDS_DIR}}"
  # rsync can have trouble with a full quoted remote path; this one is safe.
  local peer_uri="${PEER_USER}@${PEER_HOST}:${peer_worlds}/${WORLD_FOLDER}/"
  info "PEER: ${peer_uri}"
  echo "⚠  Close Minecraft (the app) on BOTH phones before syncing!"
  read -r -p "Press Enter to continue or Ctrl+C to abort..." _ || exit 1

  local lm rm
  lm="$(world_mtime "${WORLD_FOLDER}")"
  rm="$(remote_world_mtime)"
  newest_wins_check "${lm}" "${rm}" "push"

  ssh -p "${PEER_PORT}" -o StrictHostKeyChecking=no "${PEER_USER}@${PEER_HOST}" \
      "mkdir -p '${peer_worlds}/${WORLD_FOLDER}'" || die "Cannot create folder on peer"
  info "Pushing world to peer..."
  rsync -az --delete -e "ssh -p ${PEER_PORT} -o StrictHostKeyChecking=no" \
      "${WORLDS_DIR}/${WORLD_FOLDER}/" "${peer_uri}" || die "rsync failed"
  printf '%s %s\n' "${WORLD_FOLDER}" "${lm}" > "${STATE_FILE}"
  ok "World synced to peer."
  info "On the other phone open Minecraft: the world will appear in the world list."
}

cmd_pull() {
  [ -n "${PEER_USER}" ] && [ -n "${PEER_HOST}" ] || die "Peer not configured (config/worldsync.conf)"
  need ssh; need rsync
  [ -d "${WORLDS_DIR}" ] || die "Worlds folder not found: ${WORLDS_DIR}"
  WORLD_FOLDER="$(pick_world_folder)"
  local peer_worlds="${PEER_WORLDS_DIR:-${WORLDS_DIR}}"
  local peer_uri="${PEER_USER}@${PEER_HOST}:${peer_worlds}/${WORLD_FOLDER}/"
  info "PEER: ${peer_uri}"
  echo "⚠  Close Minecraft (the app) on BOTH phones before syncing!"
  read -r -p "Press Enter to continue or Ctrl+C to abort..." _ || exit 1

  local lm rm
  lm="$(world_mtime "${WORLD_FOLDER}")"
  rm="$(remote_world_mtime)"
  newest_wins_check "${lm}" "${rm}" "pull"

  # Back up the local copy before overwriting it.
  mkdir -p "${BACKUP_DIR}/${WORLD_FOLDER}"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  rsync -a "${WORLDS_DIR}/${WORLD_FOLDER}/" "${BACKUP_DIR}/${WORLD_FOLDER}/${stamp}/" 2>/dev/null \
    || warn "Could not make a local backup (continuing anyway)"
  find "${BACKUP_DIR}/${WORLD_FOLDER}" -mindepth 1 -maxdepth 1 -type d \
       -exec sh -c 'test "$(ls -1 "$1" 2>/dev/null | wc -l)" -gt '"${KEEP_BACKUPS}"' || true' _ {} \;

  info "Pulling world from peer..."
  rsync -az --delete -e "ssh -p ${PEER_PORT} -o StrictHostKeyChecking=no" \
      "${peer_uri}" "${WORLDS_DIR}/${WORLD_FOLDER}/" || die "rsync failed"
  printf '%s %s\n' "${WORLD_FOLDER}" "${lm}" > "${STATE_FILE}"
  ok "World synced from peer."
  info "Open Minecraft: the world should match the other phone now."
}

usage() {
  sed -n '2,11p' "${PROJECT_ROOT}/worldsync.sh" 2>/dev/null
  echo
  echo "Commands:"
  sed -n 's/^#   \(\.\/worldsync.sh [a-z]*\).*$/\1/p' "${PROJECT_ROOT}/worldsync.sh" 2>/dev/null
}

CMD="${1:-help}"
case "${CMD}" in
  check) cmd_check ;;
  list)  cmd_list ;;
  export) cmd_export ;;
  import) cmd_import "${2:-}" ;;
  push)  cmd_push ;;
  pull)  cmd_pull ;;
  help|-h|--help) usage ;;
  *) die "Unknown command: ${CMD} (try ./worldsync.sh help)" ;;
esac
