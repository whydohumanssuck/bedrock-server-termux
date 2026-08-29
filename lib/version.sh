#!/usr/bin/env bash
# version.sh -- central place for the target Bedrock server version.
#
# This is the ONLY place that declares which version the project targets.
# Every script reads from here so the "pin" stays consistent.

# Target Minecraft Bedrock game version (what players see in-game).
BDS_GAME_VERSION="1.21.130"

# Full BDS build identifier used in the official download filename:
#   bedrock-server-<GAME_VERSION>.<BUILD>.zip
# For 1.21.130 the published stable BDS builds are .3 and .4; the project
# pins the newest (.4). Override with:
#   BDS_BUILD="1.21.130.3" ./install.sh
BDS_BUILD="${BDS_BUILD:-1.21.130.4}"
BDS_FILENAME="bedrock-server-${BDS_BUILD}.zip"

# Official download page (used as the last download fallback).
BDS_PAGE_URL="https://www.minecraft.net/en-us/download/server/bedrock"

# Directory (relative to the project root) where the server is unpacked.
SERVER_DIR="bedrock_server"

# Where downloaded archives are kept between installs.
DL_DIR="data"

# Literal build string we pin to (1.21.130.P).
bds_target_build() { printf '%s' "${BDS_BUILD}"; }

# Game version (1.21.130).
bds_target_game() { printf '%s' "${BDS_GAME_VERSION}"; }
