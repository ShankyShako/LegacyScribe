#!/bin/zsh
# SwiftPM always clones full git history; FluidAudio (~290 MB) and TCA (~190 MB) take hours on
# a slow link. This fetches only the pinned commit of each large dependency into a local repo,
# tags it with the version SwiftPM expects, and writes mirrors.json for the app and lsbench.
# The generated mirrors.json files contain machine-local paths and are gitignored.
#
# mlx-swift checks out ml-explore/mlx and mlx-c as git submodules, which mirrors.json can't
# redirect. Build lsbench with the env from `tools/spm-shallow-mirrors.sh --git-env` so git
# rewrites those submodule URLs to the local mirrors too.
#
# Usage: tools/spm-shallow-mirrors.sh          (re-run after bumping a pin below)
#        tools/spm-shallow-mirrors.sh --remove (delete mirrors.json; go back to GitHub)
#        eval "$(tools/spm-shallow-mirrors.sh --git-env)" (export the submodule redirect)
set -euo pipefail

repo_root="${0:A:h:h}"
mirror_root="$HOME/Library/Caches/LegacyScribe/spm-mirrors"
app_config="$repo_root/Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"
bench_config="$repo_root/tools/lsbench/.swiftpm/configuration"

if [[ "${1:-}" == "--git-env" ]]; then
  # Git refuses file:// submodules by default (CVE-2022-39253); allow it only in this env.
  print -r -- "export GIT_CONFIG_COUNT=3"
  print -r -- "export GIT_CONFIG_KEY_0=url.file://$mirror_root/mlx.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ml-explore/mlx"
  print -r -- "export GIT_CONFIG_KEY_1=url.file://$mirror_root/mlx-c.insteadOf GIT_CONFIG_VALUE_1=https://github.com/ml-explore/mlx-c"
  print -r -- "export GIT_CONFIG_KEY_2=protocol.file.allow GIT_CONFIG_VALUE_2=always"
  exit 0
fi

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$app_config/mirrors.json" "$bench_config/mirrors.json"
  echo "Removed mirrors.json; SwiftPM will fetch from GitHub again."
  exit 0
fi

# name | upstream URL (no .git) | commit | tag to create ("" for revision pins)
pins=(
  "swift-composable-architecture|https://github.com/pointfreeco/swift-composable-architecture|e2fa1df6cd9eec6fa6314aa20513e47da576f24e|1.26.0"
  "FluidAudio|https://github.com/FluidInference/FluidAudio|0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7|v0.17.5"
  "mlx-audio-swift|https://github.com/Blaizzy/mlx-audio-swift|dbe5eaac964e8257785f9d015c81f819a38016a8|"
  # Versions below follow mlx-audio-swift's own Package.resolved at the commit above.
  "mlx-swift|https://github.com/ml-explore/mlx-swift|19601207e9a0de51e03ee6ec0c3c5f3784275075|0.32.3"
  "mlx-swift-lm|https://github.com/ml-explore/mlx-swift-lm|3b339ad6e3b3f44c8121ecff5131c7fd55e075e6|3.32.3"
  # Submodules of mlx-swift (redirected by --git-env, not mirrors.json).
  "mlx|https://github.com/ml-explore/mlx|1f8e74e3f12f31365464a6867c6579f0e9b29d85|"
  "mlx-c|https://github.com/ml-explore/mlx-c|ebc88f10caa1b625e6b581437a8dea6df8a70085|"
)

entries=()
for pin in "${pins[@]}"; do
  IFS='|' read -r name url commit tag <<< "$pin"
  dir="$mirror_root/$name"
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "Fetching $name @ ${commit:0:12}…"
    rm -rf "$dir" && mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
  fi
  [[ -n "$tag" ]] && git -C "$dir" tag -f "$tag" "$commit" >/dev/null
  # SwiftPM matches the original URL literally, so cover both spellings.
  entries+=("{\"original\": \"$url\", \"mirror\": \"file://$dir\"}")
  entries+=("{\"original\": \"$url.git\", \"mirror\": \"file://$dir\"}")
done

json="{\"version\": 1, \"object\": [${(j:, :)entries}]}"
for config in "$app_config" "$bench_config"; do
  mkdir -p "$config"
  print -r -- "$json" | python3 -m json.tool > "$config/mirrors.json"
done
echo "Wrote mirrors.json for the app and lsbench (mirrors in $mirror_root)."
