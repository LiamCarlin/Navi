#!/bin/zsh
# Builds `build/axprobe`: a CLI that snapshots a running app's accessibility
# table exactly as the Jev-first driver sees it (AXSnapshotter + browser-chrome
# tidying + the app/web playbook) and asks Jev what it would do for each goal —
# read-only, nothing is clicked. The fastest way to check a site or app before
# trusting a voice command on it.
#
#   scripts/axprobe/build.sh
#   TYPESAFE_API_KEY=… build/axprobe com.apple.Safari "click the File menu" "type hello in the document"
#   build/axprobe com.google.Chrome            # no goals: just print the element table
#
# Stubs.swift stands in for app-only types (Keychain → env vars, settings, logging).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O -o build/axprobe scripts/axprobe/Stubs.swift scripts/axprobe/main.swift \
  Navi/Agent/AXSnapshot.swift Navi/Agent/AgentTarget.swift Navi/Agent/JevDriver.swift Navi/Agent/JevGate.swift \
  Navi/Providers/JevClient.swift Navi/Agent/AppSkills.swift Navi/Agent/AppSkillLibrary.swift Navi/Agent/TextCandidates.swift
echo "build/axprobe"
