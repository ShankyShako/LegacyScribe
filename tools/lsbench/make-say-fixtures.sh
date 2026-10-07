#!/bin/zsh
# Generate synthetic 16 kHz fixtures with macOS `say` for latency + sanity-WER runs.
# References are written as a person would type them (10:30, Xcode 26) so WER counts mis-hearing, not formatting.
# Real accuracy numbers need your own voice: see record-voice-fixtures.sh.
set -euo pipefail

out="${1:-$HOME/Library/Application Support/LegacyScribe/fixtures/say}"
mkdir -p "$out"

typeset -A clips
clips[01-short]="Open the pull request and merge it."
clips[02-mid]="Can you move the standup to Thursday at 10:30? I need the extra day to finish the SwiftUI settings screen and test the keychain migration."
clips[03-tech]="Run the MLX benchmark on the M5, then compare Parakeet against Cohere Transcribe and paste the word error rate into the README."
clips[04-long]="Here's the plan for this week. First, we fork Hex and get it building on Xcode 26. Second, we wire up the right option key as push to talk, with a double tap to toggle recording. Third, we measure latency from the moment the key is released until the text is pasted. If Cohere is fast enough on the 4-bit checkpoint, it becomes the default engine. Otherwise we stay on Parakeet and revisit next month."

for name text in "${(@kv)clips}"; do
  say -o "$out/$name.wav" --data-format=LEI16@16000 "$text"
  print -r -- "$text" > "$out/$name.txt"
done
ls -1 "$out"
