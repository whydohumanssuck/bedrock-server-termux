#!/usr/bin/env bash
# update.sh -- download a newer official BDS build and swap it in, preserving
# worlds, server.properties, whitelist/permissions and packs.
#
# Usage:
#   BDS_BUILD=1.21.130.02 ./update.sh     # update to a specific build
#   ./update.sh                            # use the pinned version from lib/version.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/version.sh"

if should_use_distro; then bounce_into_distro "$@"; fi

[ -d "${SERVER_DIR}" ] || die "Server is not installed. Run ./install.sh first."
is_running && die "Stop the server first (./stop.sh) before updating."

BDS_BUILD="$(bds_target_build)"
BDS_GAME="$(bds_target_game)"
ZIP_PATH="${DL_DIR}/bedrock-server-${BDS_BUILD}.zip"
TMP="${SERVER_DIR}.update"

# Safety: preserve the current install.
info "Saving a safety copy of the current server..."
SAFE="${BACKUP_DIR}/pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "${BACKUP_DIR}"
tar -czf "${SAFE}" -C "$(dirname "${SERVER_DIR}")" "$(basename "${SERVER_DIR}")" || \
  warn "Could not create the pre-update safety copy."

if [ ! -f "${ZIP_PATH}" ]; then
  info "Fetching ${BDS_BUILD}..."
  download_server_archive "${ZIP_PATH}" || { rm -f "${ZIP_PATH}"; die "Download failed. See README."; }
else
  info "Using existing archive: ${ZIP_PATH}"
fi
verify_archive_layout "${ZIP_PATH}" || {
  rm -f "${ZIP_PATH}";
  die "SAFETY CHECK FAILED: '${ZIP_PATH}' does not have the expected Bedrock
server layout for ${BDS_BUILD}. Delete it and re-run, or place the correct
official zip in data/."
}

rm -rf "${TMP}"
mkdir -p "${TMP}"
unzip -q -o "${ZIP_PATH}" -d "${TMP}" || die "Extraction failed."

if ! strings_has_version "${TMP}/bedrock_server" "${BDS_GAME}"; then
  warn "Version string ${BDS_GAME} not found in the new binary. Double-check
that '${BDS_BUILD}' is the build you want before trusting it."
fi

# Migrate user data into the new install.
for d in worlds behavior_packs resource_packs; do
  if [ -d "${SERVER_DIR}/${d}" ]; then
    cp -rn "${SERVER_DIR}/${d}/." "${TMP}/${d}/" 2>/dev/null || true
  fi
done
for f in server.properties allowlist.json permissions.json; do
  [ -f "${SERVER_DIR}/${f}" ] && cp -n "${SERVER_DIR}/${f}" "${TMP}/${f}" 2>/dev/null || true
done

# Swap.
mv "${SERVER_DIR}" "${SERVER_DIR}.old"
mv "${TMP}" "${SERVER_DIR}"
rm -rf "${SERVER_DIR}.old"
touch "${SERVER_DIR}/.bds-version-${BDS_BUILD}"
chmod +x "${SERVER_DIR}/bedrock_server"

ok "Updated to ${BDS_BUILD}. Worlds and config were preserved."
echo "Start it with: ./start.sh"
exit 0
