#!/bin/zsh
# Builds `build/axprobe`: a CLI that snapshots a running app's accessibility
# tree and prints the numbered item list exactly as the native driver builds it
# (CUPerception: controls + static text, dates, rows, regions) and asks Jev what
# it would do for each goal (CUDecide, one request) —
# read-only, nothing is clicked. The fastest way to check a site or app before
# trusting a voice command on it.
#
#   scripts/axprobe/build.sh
#   TYPESAFE_API_KEY=… build/axprobe com.apple.Safari "click the File menu" "type hello in the document"
#   build/axprobe com.google.Chrome            # no goals: just print the element table
#   AXPROBE_CONTEXT='[{"name":"Mikey Ku","type":"person","talks_with_them_in":["Messages (55)"]}]' \
#     build/axprobe com.apple.MobileSMS "open my conversation with mikey"   # UserKnowledge A/B
#
# Stubs.swift stands in for app-only types (Keychain → env vars, settings, logging).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O -o build/axprobe scripts/axprobe/Stubs.swift scripts/axprobe/main.swift \
  Navi/Agent/AXSnapshot.swift Navi/Agent/AgentTarget.swift Navi/Agent/AgentAction.swift Navi/Agent/JevGate.swift \
  Navi/Agent/TypesafeCU/CUModels.swift Navi/Agent/TypesafeCU/CUFacts.swift Navi/Agent/TypesafeCU/CUPerception.swift \
  Navi/Agent/TypesafeCU/CUDecide.swift \
  Navi/Providers/JevClient.swift Navi/Agent/AppSkills.swift Navi/Agent/AppSkillLibrary.swift Navi/Agent/TextCandidates.swift
echo "build/axprobe"
