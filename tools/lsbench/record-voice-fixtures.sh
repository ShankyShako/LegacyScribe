#!/bin/zsh
# Record your own voice fixtures for lsbench: one 16 kHz mono WAV + reference .txt per line of
# voice-prompts.txt. Press Enter to start a clip, Enter again to stop. Existing clips are skipped,
# so you can quit with Ctrl-C and resume later. Delete a clip's .wav to re-record it.
#
# Usage: tools/lsbench/record-voice-fixtures.sh [prompts-file]
#        MIC="MacBook Pro Microphone" tools/lsbench/record-voice-fixtures.sh   (pick an input; default = system default)
#        List inputs: ffmpeg -f avfoundation -list_devices true -i ""
set -euo pipefail

prompts="${1:-${0:A:h}/voice-prompts.txt}"
out="$HOME/Library/Application Support/LegacyScribe/fixtures/me"
mic="${MIC:-default}"
mkdir -p "$out"

n=0
while IFS= read -r line <&3; do
  [[ -z "$line" ]] && continue
  n=$((n + 1))
  name=$(printf "%02d" $n)
  [[ -f "$out/$name.wav" ]] && continue
  print -r -- "$line" > "$out/$name.txt"
  print "\n[$name] Read this aloud:\n\n    $line\n"
  read -r "?Enter to start recording… "
  ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$mic" -ac 1 -ar 16000 -y "$out/$name.wav" &
  ffmpeg_pid=$!
  read -r "?Recording. Enter to stop… "
  kill -INT $ffmpeg_pid; wait $ffmpeg_pid || true
done 3< "$prompts"
print "\nDone. Fixtures in: $out"
