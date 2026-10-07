#!/bin/zsh
# Resumable Hugging Face download for slow, flaky links.
# Each curl attempt resumes from the file's current size (curl's own --retry reuses the
# first attempt's offset and corrupts the file), and LFS files are SHA-256 checked at the end.
#
# Usage: tools/fetch-hf.sh <repo-id> <dest-dir> [file ...]   (no files = whole repo)
# e.g.   tools/fetch-hf.sh beshkenadze/cohere-transcribe-03-2026-mlx-4bit \
#          "$HOME/Library/Application Support/LegacyScribe/Models/mlx/beshkenadze/cohere-transcribe-03-2026-mlx-4bit"
set -euo pipefail

repo="$1"; dest="$2"; shift 2
mkdir -p "$dest"

# path<TAB>size<TAB>sha256-or-empty for every file in the repo
listing=$(curl -fsS "https://huggingface.co/api/models/$repo/tree/main" | python3 -c '
import json, sys
for f in json.load(sys.stdin):
    if f["type"] == "file":
        print(f["path"], f["size"], (f.get("lfs") or {}).get("oid", ""), sep="\t")')

wanted=("$@")
print -r -- "$listing" | while IFS=$'\t' read -r file size sha; do
  [[ ${#wanted} -gt 0 && ${wanted[(Ie)$file]} -eq 0 ]] && continue
  out="$dest/$file"
  attempts=0
  until [[ -f "$out" && $(stat -f %z "$out") -ge $size ]]; do
    (( ++attempts > 100 )) && { echo "$file: giving up after 100 attempts" >&2; exit 1; }
    have=$([[ -f "$out" ]] && stat -f %z "$out" || echo 0)
    echo "$file: $((have / 1048576)) / $((size / 1048576)) MB"
    curl -fsSL -C - -o "$out" "https://huggingface.co/$repo/resolve/main/$file" || sleep 5
  done
  if [[ -n "$sha" ]]; then
    actual=$(shasum -a 256 "$out" | cut -d' ' -f1)
    if [[ "$actual" != "$sha" ]]; then
      echo "$file: checksum mismatch, deleting (re-run to fetch again)" >&2
      rm -f "$out"; exit 1
    fi
  fi
  echo "$file: ok"
done
