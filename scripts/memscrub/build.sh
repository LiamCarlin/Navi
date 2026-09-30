#!/bin/zsh
# Builds `build/memscrub`: a one-off cleanup that redacts personal identifiers
# (dates of birth, addresses, phones, card/SSN/ID numbers) already stored in
# screen memory — frames, sessions, the Obsidian vault — with the same rules the
# capture guard and the digester now apply (Navi/Memory/PersonalData.swift).
#
#   scripts/memscrub/build.sh
#   build/memscrub              # dry run: kinds and counts only, never values
#   build/memscrub --apply      # quit Navi first
#
# Stubs.swift stands in for app-only types (logging, the digest result, Jev).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O -o build/memscrub scripts/memscrub/Stubs.swift scripts/memscrub/main.swift \
  Navi/Memory/PersonalData.swift Navi/Memory/PersonalDataCleanup.swift Navi/Memory/MemoryStore.swift \
  Navi/Memory/VaultWriter.swift Navi/Memory/FrameTriage.swift
echo "build/memscrub"
