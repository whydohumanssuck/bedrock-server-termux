#!/usr/bin/env bash
# install.sh -- one-shot installer for a Minecraft Bedrock server (1.21.130)
# on Android/Termux (ARM64) or desktop Linux (x86_64/ARM64).
#
# What it does:
#   1. Detects the environment (Termux, Android, CPU architecture).
#   2. Installs dependencies needed to download and run the server.
#   3. On ARM64 Android/Termux it sets up a proot-distro Debian container and
#      the box64 compatibility layer needed to run the official x86_64 server.
#   4. Downloads and verifies the official server archive for the pinned
#      version, failing safely when the download is missing/corrupt/wrong.
#   5. Creates the directory layout, imports worlds/packs, and writes
#      sensible server.properties defaults.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/version.sh"

BDS_BUILD="$(bds_target_build)"
BDS_GAME="$(bds_target_game)"

USAGE="Usage: ./install.sh [options]
Options:
  --no-download   Use a zip already present in data/ (skip network download)
  --force         Re-download and re-extract even if already installed
  --skip-proot    (Termux/ARM64) set up the server directly in Termux instead
                  of inside a proot-distro Debian container
  -h, --help      Show this help"

# Keep the original CLI args; the parsing loop below consumes them via
# shift, but the proot bounce further down still needs them.
ORIG_ARGS="$*"

NO_DOWNLOAD=0
FORCE=0
SKIP_PROOT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-download) NO_DOWNLOAD=1 ;;
    --force) FORCE=1 ;;
    --skip-proot) SKIP_PROOT=1 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# configure_server: write server.properties only if missing.
# ---------------------------------------------------------------------------
configure_server() {
  local props="${SERVER_DIR}/server.properties"
  if [ ! -f "${props}" ]; then
    if [ -f "${CONFIG_DIR}/server.properties.template" ]; then
      cp "${CONFIG_DIR}/server.properties.template" "${props}"
      ok "Wrote ${props} (from template)"
    else
      warn "config/server.properties.template missing; writing built-in defaults."
      cat > "${props}" <<'PROPS'
server-name=Dedicated Server
gamemode=survival
difficulty=normal
allow-cheats=false
max-players=5
online-mode=true
white-list=false
server-port=19132
server-portv6=19133
view-distance=6
tick-distance=4
player-idle-timeout=30
max-threads=0
level-name=Bedrock level
level-seed=
default-player-permission-level=member
texturepack-required=false
content-log-file-enabled=true
compression-threshold=1
server-authoritative-movement=server-auth
player-movement-score-threshold=20
player-movement-distance-threshold=0.3
player-movement-duration-threshold-in-ms=500
correct-player-movement=false
emit-server-telemetry=false
PROPS
      ok "Wrote ${props} (built-in defaults)"
    fi
  else
    info "Keeping existing ${props}"
  fi

  local allow="${SERVER_DIR}/allowlist.json"
  local perm="${SERVER_DIR}/permissions.json"
  [ -f "${allow}" ] || { printf '[]' > "${allow}"; ok "Wrote ${allow}"; }
  [ -f "${perm}" ]  || { printf '[]' > "${perm}";  ok "Wrote ${perm}"; }
}

# ---------------------------------------------------------------------------
# print_next_steps
# ---------------------------------------------------------------------------
print_next_steps() {
  cat <<EOF

${C_GRN}Next steps:${C_RST}
  1. Edit ${SERVER_DIR}/server.properties if you want to change the
     server name, gamemode, whitelist or port.
  2. Start the server:   ./start.sh
  3. Attach to console:  ./tmux-console.sh   (detach with Ctrl+B then D)
  4. Stop the server:    ./stop.sh
  5. Back up worlds:     ./backup.sh
EOF
}

# ---------------------------------------------------------------------------
# Report environment
# ---------------------------------------------------------------------------
ARCH="$(machine_arch)"
info "Project root : ${PROJECT_ROOT}"
info "Architecture : ${ARCH}"
if is_termux;    then info "Environment  : Termux (Android)"
elif is_android; then info "Environment  : Android (non-Termux shell)"
else                   info "Environment  : GNU/Linux"; fi

if [ "${ARCH}" = "armv7" ] || [ "${ARCH}" = "i686" ] || [ "${ARCH}" = "unknown" ]; then
  die "CPU architecture '${ARCH}' is not supported. The official Linux Bedrock
server is x86_64 only, and box64 (the compatibility layer) requires 64-bit ARM
(arm64-v8a). A 64-bit phone or an x86_64 Linux machine is required."
fi

# ---------------------------------------------------------------------------
# Termux bootstrap: bounce into a proot-distro Debian container on ARM64.
# The official server is x86_64 and only runs there (via box64).
# ---------------------------------------------------------------------------
if should_use_distro && [ "${SKIP_PROOT}" -eq 0 ]; then
  if ! command -v proot-distro >/dev/null 2>&1; then
    info "Installing proot-distro and download tools inside Termux..."
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y proot-distro curl unzip jq tmux || \
      die "Could not install proot-distro. Run: pkg install proot-distro curl unzip jq tmux"
  fi
  if ! distro_exists; then
    info "Installing the Debian container (downloads ~1GB of packages; please wait)..."
    # proot-distro refuses to install a container whose rootfs already exists
    # (e.g. after an interrupted earlier run). That is not an error: verify
    # afterwards that it either exists or the install really succeeded.
    if ! proot-distro install "${DISTRO}" >/dev/null 2>&1 && ! distro_exists; then
      die "proot-distro install failed. If the Debian container was partially
installed, run: proot-distro reset debian, then ./install.sh again."
    fi
  fi

  # Stage the whole project so the container gets every script, config,
  # worlds/ and packs/ folder.
  STAGE="$(mktemp -d "${TMPDIR:-${HOME}}/mc-stage.XXXXXX" 2>/dev/null || mktemp -d)"
  cp -r "${PROJECT_ROOT}/lib" "${PROJECT_ROOT}/config" "${STAGE}/" 2>/dev/null || true
  cp -r "${PROJECT_ROOT}/worlds" "${PROJECT_ROOT}/behavior_packs" "${PROJECT_ROOT}/resource_packs" "${STAGE}/" 2>/dev/null || true
  cp -r "${PROJECT_ROOT}/LICENSE" "${PROJECT_ROOT}/README.md" "${STAGE}/" 2>/dev/null || true
  for f in install.sh start.sh stop.sh backup.sh update.sh tmux-console.sh status.sh; do
    [ -f "${PROJECT_ROOT}/${f}" ] && cp "${PROJECT_ROOT}/${f}" "${STAGE}/" 2>/dev/null || true
  done
  proot-distro login "${DISTRO}" --bind "${STAGE}:/project" -- bash -lc \
    'mkdir -p /root/mc-bedrock-server && cp -r /project/. /root/mc-bedrock-server/ && chmod +x /root/mc-bedrock-server/*.sh' || {
      rm -rf "${STAGE}"; die "Could not stage the project into the Debian container."
    }
  rm -rf "${STAGE}"

  info "Re-running the installer inside the Debian container..."
  # shellcheck disable=SC2086  # options carry no spaces; splitting is safe
  exec proot-distro login "${DISTRO}" -- bash -lc \
    'cd /root/mc-bedrock-server && BDS_INSIDE_DISTRO=1 ./install.sh '"${ORIG_ARGS}" 
fi

# From here on we are either in the Debian container, direct on Termux
# (--skip-proot), or on a GNU/Linux host.

if [ "$(id -u)" -ne 0 ] && ! is_termux; then
  warn "Not running as root. Some features (box64 install) may need sudo."
fi

# ---------------------------------------------------------------------------
# Install system packages (container / Linux host)
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1 && ! is_termux; then
  info "Installing system packages (curl, unzip, jq, tmux, ca-certificates)..."
  apt-get update -y >/dev/null 2>&1 || warn "apt update failed; continuing"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl unzip jq tmux -S "${TMUX_SOCKET}" ca-certificates wget libcurl4 libssl3 libstdc++6 \
    >/dev/null 2>&1 || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl unzip jq tmux -S "${TMUX_SOCKET}" ca-certificates wget libcurl4 libstdc++6 \
    >/dev/null 2>&1 || warn "Some packages could not be installed; the server may need them."
fi

# ---------------------------------------------------------------------------
# box64 compatibility layer (only needed on ARM64 without native x86_64)
# ---------------------------------------------------------------------------
if ! have_native_x86_64 && ! have_box64; then
  info "No x86_64 CPU here and box64 is not installed; installing box64..."
  if command -v apt-get >/dev/null 2>&1; then
    # box64 is packaged in modern Debian (trixie+). Try the enabled repos first.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends box64 \
      >/dev/null 2>&1 || warn "box64 not available in this distro's default repos."
    if ! have_box64 && [ -f /etc/os-release ] && grep -q 'bookworm' /etc/os-release; then
      info "box64 is not in Debian bookworm; adding the trixie repo for box64 only..."
      printf '%s\n' 'deb http://deb.debian.org/debian trixie main' \
        > /etc/apt/sources.list.d/trixie.list 2>/dev/null || true
      apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -t trixie box64 >/dev/null 2>&1 || \
        warn "Could not install box64 from trixie."
      rm -f /etc/apt/sources.list.d/trixie.list 2>/dev/null || true
    fi
    apt-get install -f -y >/dev/null 2>&1 || true
  else
    warn "No apt-get available here; please install box64 manually (see README)."
  fi
  have_box64 || warn "box64 is still not installed. See README 'Installing box64'."
fi

bds_can_run || die "The x86_64 Bedrock server cannot run on this device yet.
Required pieces:
  - a 64-bit ARM device with box64 installed (this installer sets it up), or
  - a native x86_64 Linux environment.
See the README before continuing."

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
ensure_dirs

# ---------------------------------------------------------------------------
# Download / verify / extract the official server archive
# ---------------------------------------------------------------------------
ZIP_PATH="${DL_DIR}/${BDS_FILENAME}"
INSTALLED_MARKER="${SERVER_DIR}/.bds-version-${BDS_BUILD}"

if [ "${FORCE}" -eq 0 ] && [ -f "${INSTALLED_MARKER}" ] && [ -x "${BDS_BIN}" ]; then
  ok "Server ${BDS_BUILD} is already installed."
  ensure_runtime_dirs
  configure_server
  print_next_steps
  exit 0
fi
# --force implies a full fresh install (fresh template too).
[ "${FORCE}" -eq 1 ] && [ -f "${CONFIG_DIR}/server.properties.template" ] && {
  cp "${CONFIG_DIR}/server.properties.template" "${SERVER_DIR}/server.properties"
  info "Applied phone-tuned server.properties (--force)."
}

if [ ! -f "${ZIP_PATH}" ]; then
  if [ "${NO_DOWNLOAD}" -eq 0 ]; then
    info "Downloading official Bedrock server ${BDS_BUILD} ..."
    download_server_archive "${ZIP_PATH}" || die "Official download failed.
See README 'Troubleshooting - Downloads fail'."
  else
    die "--no-download was requested but ${ZIP_PATH} does not exist.
Place the official '${BDS_FILENAME}' zip in data/ and run ./install.sh"
  fi
else
  info "Using archive: ${ZIP_PATH}"
fi

info "Verifying archive: ${ZIP_PATH}"
verify_archive_layout "${ZIP_PATH}" || die "SAFETY CHECK FAILED: '${ZIP_PATH}' does not have
the expected Bedrock server layout for ${BDS_FILENAME}. The file may be corrupt,
incomplete, or the wrong version. Delete it and re-run: ./install.sh --force"

info "Extracting to ${SERVER_DIR} ..."
rm -rf "${SERVER_DIR:?}/" 2>/dev/null || true
mkdir -p "${SERVER_DIR}"
if ! unzip -q -o "${ZIP_PATH}" -d "${SERVER_DIR}"; then
  die "Could not extract ${ZIP_PATH}. Delete it and re-run ./install.sh --force"
fi
[ -x "${BDS_BIN}" ] || die "bedrock_server binary is missing after extraction."

# Version fingerprint check (without executing x86_64 code on ARM64).
if strings_has_version "${BDS_BIN}" "${BDS_GAME}"; then
  ok "Version check passed: binary contains ${BDS_GAME}."
else
  warn "Could not confirm the string '${BDS_GAME}' inside the server binary.
If this archive was fetched from the official source for ${BDS_BUILD}, this is
fine. Otherwise do NOT trust it: delete '${ZIP_PATH}' and re-run --force."
fi

touch "${INSTALLED_MARKER}"
ok "Installed ${BDS_BUILD} (game ${BDS_GAME})."

# The official zip ships stock server.properties; on a fresh install the
# project's phone-tuned template wins (existing config survives later runs).
if [ -f "${CONFIG_DIR}/server.properties.template" ]; then
  cp "${CONFIG_DIR}/server.properties.template" "${SERVER_DIR}/server.properties"
  ok "Applied phone-tuned ${SERVER_DIR}/server.properties"
fi

# ---------------------------------------------------------------------------
# Config / imports
# ---------------------------------------------------------------------------
ensure_runtime_dirs
configure_server
print_next_steps
exit 0
