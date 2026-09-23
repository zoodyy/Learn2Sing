#!/bin/zsh
# Builds the bench into Tools/PitchBench/.build/pitchbench, together with the app's own
# PitchAnalyzer.swift and PitchSettler.swift so the numbers are always the shipped code's.
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O -o .build/pitchbench "$PWD"/Sources/*.swift "$PWD/../../Learn2Sing/Sources/Audio/PitchAnalyzer.swift" "$PWD/../../Learn2Sing/Sources/Audio/PitchSettler.swift"
echo "built .build/pitchbench"
