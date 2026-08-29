#!/usr/bin/env bash
# common.sh -- shared helpers used by every script in this project.
# This file must be *sourced*, not executed directly.

# ---------------------------------------------------------------------------
# Project layout
# ---------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the version pin so downstream scripts can rely on it.
if [ -f "${PROJECT_ROOT}/lib/version.sh" ]; then
  # shellcheck disable=SC1091
  . "${PROJECT_ROOT}/lib/version.sh"
fi

# Server binary lives in <root>/bedrock_server
SERVER_DIR="${PROJECT_ROOT}/bedrock_server"
BDS_BIN="${SERVER_DIR}/bedrock_server"

# Runtime directories
LOGS_DIR="${PROJECT_ROOT}/logs"
DL_DIR="${PROJECT_ROOT}/data"
BACKUP_DIR="${PROJECT_ROOT}/backups"
WORLD_DIR="${PROJECT_ROOT}/worlds"
CONFIG_DIR="${PROJECT_ROOT}/config"
BEHAVIOR_PACK_BASE="${PROJECT_ROOT}/behavior_packs"
RESOURCE_PACK_BASE="${PROJECT_ROOT}/resource_packs"

SERVER_LOGFILE="${LOGS_DIR}/server.log"
PIDFILE="${LOGS_DIR}/server.pid"
STOP_REQUESTED="${LOGS_DIR}/.stop-requested"

# proot container name (Termux/ARM64 compatibility layer)
DISTRO="debian"

# Colors (only when attached to a TTY)
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

info()  { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------

# is_termux: 0 = running inside Termux, 1 = not.
is_termux() {
  # Inside the Debian container the host Termux paths are still visible, but
  # that environment must be treated as plain GNU/Linux.
  in_distro && return 1
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  [ -d /data/data/com.termux/files/usr ] && return 0
  return 1
}

# is_android: 0 = running on Android (any shell), 1 = not.
is_android() {
  [ -n "${ANDROID_ROOT:-}" ] && return 0
  [ -f /system/build.prop ] && return 0
  return 1
}

# machine_arch: CPU architecture of the *current* userspace.
machine_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7|arm) echo "armv7" ;;
    x86_64|amd64) echo "x86_64" ;;
    i686|x86) echo "i686" ;;
    *) echo "unknown" ;;
  esac
}

# have_native_x86_64: 0 if this userspace is x86_64, 1 otherwise.
have_native_x86_64() {
  [ "$(machine_arch)" = "x86_64" ]
}

# have_box64: 0 if box64 is installed and runnable, 1 otherwise.
have_box64() {
  command -v box64 >/dev/null 2>&1
}

# bds_can_run: 0 if the official (x86_64) BDS binary can probably run here.
bds_can_run() {
  have_native_x86_64 && return 0
  if [ "$(machine_arch)" = "aarch64" ] && have_box64; then return 0; fi
  return 1
}

# distro_exists: 0 if the proot-distro Debian container is installed.
# Checks both proot-distro's status list AND the rootfs directory, because
# the list query can be stale after an interrupted install.
distro_exists() {
  # 1) Ask proot-distro itself. Recent versions dropped '--installed' and
  #    print bare names with '-q'; older versions accept '--installed' (and
  #    may ignore '-q', printing a bullet list -- the regex tolerates that).
  local names
  names="$(proot-distro list -q 2>/dev/null \
           || proot-distro list --installed 2>/dev/null)"
  if printf '%s\n' "${names}" | grep -qE "(^|[^[:alnum:]_-])${DISTRO}([^[:alnum:]_-]|$)"; then
    return 0
  fi

  # 2) Fall back to the on-disk layouts proot-distro uses:
  #    new -> $PREFIX/var/lib/proot-distro/containers/<name>/rootfs
  #    old -> $PREFIX/var/lib/proot-distro/installed-rootfs/<name>
  local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
  [ -d "${prefix}/var/lib/proot-distro/containers/${DISTRO}/rootfs" ] && return 0
  [ -d "${prefix}/var/lib/proot-distro/installed-rootfs/${DISTRO}" ] && return 0
  return 1
}

# in_distro: 0 if this shell is already running inside the proot container
# (the rest of the project is executed there on ARM64 devices).
in_distro() {
  [ -n "${BDS_INSIDE_DISTRO:-}" ] && return 0 || return 1
}

# should_use_distro: 0 if we are on Termux/ARM64 and should bounce into the
# Debian container, 1 otherwise.
should_use_distro() {
  if is_termux && [ "$(machine_arch)" = "aarch64" ] && ! in_distro; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

# ensure_dirs: create the whole required BDS directory tree.
ensure_dirs() {
  mkdir -p "${SERVER_DIR}" "${LOGS_DIR}" "${DL_DIR}" "${BACKUP_DIR}" \
           "${WORLD_DIR}" "${CONFIG_DIR}" \
           "${BEHAVIOR_PACK_BASE}" "${RESOURCE_PACK_BASE}"
}

# ensure_runtime_dirs: create the directories BDS itself expects, import any
# worlds/packs the user dropped into the top-level folders, and (re)write
# server.properties / allowlist / permissions when missing.
ensure_runtime_dirs() {
  mkdir -p "${SERVER_DIR}/worlds" "${SERVER_DIR}/behavior_packs" \
           "${SERVER_DIR}/resource_packs" "${LOGS_DIR}"

  # Import worlds placed in <root>/worlds
  if [ -d "${WORLD_DIR}" ] && [ -n "$(ls -A "${WORLD_DIR}" 2>/dev/null)" ]; then
    cp -rn "${WORLD_DIR}/." "${SERVER_DIR}/worlds/" 2>/dev/null || \
      warn "Could not import worlds/ (permissions?)"
  fi
  # Sync behavior packs from <root>/behavior_packs
  if [ -d "${BEHAVIOR_PACK_BASE}" ] && [ -n "$(ls -A "${BEHAVIOR_PACK_BASE}" 2>/dev/null)" ]; then
    cp -rn "${BEHAVIOR_PACK_BASE}/." "${SERVER_DIR}/behavior_packs/" 2>/dev/null || \
      warn "Could not import behavior_packs/ (permissions?)"
  fi
  # Sync resource packs from <root>/resource_packs
  if [ -d "${RESOURCE_PACK_BASE}" ] && [ -n "$(ls -A "${RESOURCE_PACK_BASE}" 2>/dev/null)" ]; then
    cp -rn "${RESOURCE_PACK_BASE}/." "${SERVER_DIR}/resource_packs/" 2>/dev/null || \
      warn "Could not import resource_packs/ (permissions?)"
  fi

  # Auto-create level config when a single world was imported.
  imported="$(find "${SERVER_DIR}/worlds" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  if [ -f "${SERVER_DIR}/server.properties" ] && [ "${imported}" -eq 1 ]; then
    world_name="$(basename "$(find "${SERVER_DIR}/worlds" -mindepth 1 -maxdepth 1 -type d | head -1)")"
    sed -i "s/^level-name=.*/level-name=${world_name}/" "${SERVER_DIR}/server.properties"
  fi
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

# Official download page (used only to resolve the current build string).
mc_download_page() { printf '%s' "${BDS_PAGE_URL:-https://www.minecraft.net/en-us/download/server/bedrock}"; }

# plausible_zip <file>: reject HTML/error pages and tiny partial downloads.
# A real BDS archive is on the order of 100 MB. Accept only files that start
# with zip magic (PK) and are at least 40 MB; anything smaller is bogus.
plausible_zip() {
  local f="$1"
  [ -f "${f}" ] || return 1
  if ! od -An -c -N2 "${f}" | grep -q 'P   K'; then
    return 1
  fi
  local size
  size="$(wc -c < "${f}" 2>/dev/null | tr -d ' ')"
  [ "${size:-0}" -ge 40000000 ] 2>/dev/null
}

# download_server_archive <dest.zip>
# Tries the pinned "azureedge" CDN URL first, then the current official page.
# Returns 0 on success.
download_server_archive() {
  local dest="$1"
  local ua="Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36"
  local candidates=()
  # Current official CDN host + path. The old minecraft.azureedge.net host is
  # retired, so it is not tried (avoids a long dead-DNS timeout on phones).
  candidates+=("https://www.minecraft.net/bedrockdedicatedserver/bin-linux/${BDS_FILENAME}")
  candidates+=("https://minecraft.net/bedrockdedicatedserver/bin-linux/${BDS_FILENAME}")

  local url=""
  for url in "${candidates[@]}"; do
    info "Trying ${url}"
    if curl -fL --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 900 \
         -A "${ua}" -e "https://www.minecraft.net/bedrockdedicatedserver" \
         -o "${dest}.part" "${url}" 2>/dev/null && plausible_zip "${dest}.part"; then
      mv "${dest}.part" "${dest}" && ok "Downloaded ${dest}" && return 0
    fi
    rm -f "${dest}.part"
  done

  # Last resort: the download page itself is JS-driven, so resolve the
  # newest *stable* build of the pinned game version from the community wiki
  # (which mirrors the official archive listing), then let the caller's
  # version check reject anything wrong.
  info "Direct links failed; resolving the latest stable build for $(bds_target_game) ..."
  local page link
  page="$(curl -fsSL --connect-timeout 20 --max-time 60 -A "${ua}" \
            'https://minecraft.wiki/w/Bedrock_Dedicated_Server' 2>/dev/null || true)"
  link="$(printf '%s' "${page}" \
          | grep -oE "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-$(bds_target_game)\.[0-9]+\.zip" \
          | sort -u | tail -1)"
  if [ -n "${link}" ]; then
    info "Resolved: ${link}"
    if curl -fL --retry 2 --connect-timeout 20 --max-time 900 -A "${ua}" \
         -o "${dest}.part" "${link}" 2>/dev/null && plausible_zip "${dest}.part"; then
      mv "${dest}.part" "${dest}" && ok "Downloaded ${dest}" && return 0
    fi
    rm -f "${dest}.part"
  else
    warn "Could not resolve an official download link. You can manually download
${BDS_FILENAME} from the official page into data/ and run with --no-download."
  fi
  return 1
}

# strings_has_version <binary> <version>: true if the version string occurs
# inside the binary (works without executing x86_64 code on ARM64).
strings_has_version() {
  local bin="$1" ver="$2" i
  [ -f "${bin}" ] || return 1
  for i in 1 2 3; do
    if grep -aq "${ver}" "${bin}" 2>/dev/null; then return 0; fi
    # version may be stored as \0M\0A\0J\0O\0R...
    if grep -aq "$(printf '%s' "${ver}" | sed 's/./\0\\x00/g')" "${bin}" 2>/dev/null; then return 0; fi
  done
  return 1
}

# verify_archive_layout <zip>: sanity check that the archive really is a BDS
# zip for the pinned version.
verify_archive_layout() {
  local zip="$1" tmp list has_bin=0 has_marker=0
  [ -f "${zip}" ] || return 1
  tmp="$(mktemp -d)"
  if ! unzip -l "${zip}" > "${tmp}/list.txt" 2>/dev/null; then rm -rf "${tmp}"; return 1; fi
  grep -q 'bedrock_server$' "${tmp}/list.txt" && has_bin=1
  grep -qi 'server\.properties' "${tmp}/list.txt" && has_marker=1
  rm -rf "${tmp}"
  [ "${has_bin}" -eq 1 ] && [ "${has_marker}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Launch helpers
# ---------------------------------------------------------------------------

# server_launch_cmd: prints argv for launching the server in this environment.
# Uses box64 when we are on ARM64; returns the actual (already emulated) cmd.
server_launch_cmd() {
  # Scripts (used by tests/tools) run directly; real server binaries get box64.
  if ! have_native_x86_64 && [ "$(head -c 2 "${BDS_BIN}" 2>/dev/null)" = "#!" ]; then
    printf '%s' "${BDS_BIN}"
  elif ! have_native_x86_64; then
    printf 'box64 %s' "${BDS_BIN}"
  else
    printf '%s' "${BDS_BIN}"
  fi
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

# is_running: 0 if a live BDS process is present, 1 otherwise.
is_running() {
  local pid
  [ -f "${PIDFILE}" ] || return 1
  pid="$(cat "${PIDFILE}" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && return 0
  rm -f "${PIDFILE}"
  return 1
}

# ---------------------------------------------------------------------------
# proot bounce (Termux -> Debian container)
# ---------------------------------------------------------------------------

# bounce_into_distro: re-executes the current script inside the Debian
# container. Called at the top of every user-facing script.
# Path the installer uses for the project inside the container.
DISTRO_PROJECT_PATH="/root/mc-bedrock-server"

bounce_into_distro() {
  if should_use_distro; then
    if ! command -v proot-distro >/dev/null 2>&1; then
      die "proot-distro is missing. Run: pkg install proot-distro"
    fi
    if ! distro_exists; then
      die "The ${DISTRO} container is not installed. Run ./install.sh first."
    fi
    info "Bouncing into the ${DISTRO} container..."
    exec proot-distro login "${DISTRO}" -- bash -lc \
      'cd "'"${DISTRO_PROJECT_PATH}"'" && BDS_INSIDE_DISTRO=1 ./'"$(basename "$0")"' '"$*"
  fi
}

# run_foreground: run the server in the foreground (used when tmux is missing).
run_foreground() {
  local launch
  launch="$(server_launch_cmd)"
  info "Launching: cd ${SERVER_DIR} && ${launch}"
  cd "${SERVER_DIR}" || die "Cannot cd to ${SERVER_DIR}"
  # shellcheck disable=SC2086
  exec ${launch} 2>&1 | tee -a "${SERVER_LOGFILE}"
}
