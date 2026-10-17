#!/bin/bash
# Installs the latest LegacyScribe release into /Applications (or ~/Applications) and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/ShankyShako/LegacyScribe/main/install.sh | bash
#
# The app isn't signed with a Developer ID yet, so a copy downloaded with a browser is blocked by
# Gatekeeper. curl doesn't mark its downloads as quarantined, so this copy opens like any other app.
# Since nothing then checks the download for us, this script checks it itself: the app must carry a
# valid signature from the LegacyScribe team below, or nothing is installed.
#
# Options (environment): LEGACYSCRIBE_VERSION=0.8.5 installs that release instead of the latest.
# For testing: LEGACYSCRIBE_ZIP_URL (e.g. file:///…/LegacyScribe-0.8.5.zip), LEGACYSCRIBE_DEST (a folder).
set -euo pipefail

repo="ShankyShako/LegacyScribe"
team="N2D73V734A"          # the Team ID LegacyScribe releases are signed with
app_name="LegacyScribe.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'LegacyScribe install: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "LegacyScribe is a Mac app."
[[ "$(uname -m)" == arm64 ]] || fail "LegacyScribe needs an Apple Silicon Mac (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 26 )) || fail "LegacyScribe needs macOS 26 or later; this Mac has $(sw_vers -productVersion)."

if [[ -n "${LEGACYSCRIBE_ZIP_URL:-}" ]]; then   # testing: install this zip instead
	url="$LEGACYSCRIBE_ZIP_URL"
else
	if [[ -n "${LEGACYSCRIBE_VERSION:-}" ]]; then
		api="https://api.github.com/repos/$repo/releases/tags/v$LEGACYSCRIBE_VERSION"
	else
		api="https://api.github.com/repos/$repo/releases/latest"
	fi
	json=$(curl -fsSL "$api") || fail "couldn't find the release on GitHub ($api)."
	url=$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*LegacyScribe-[^"]*\.zip"' | sed -n '1s/.*"\(https[^"]*\)"/\1/p' || true)
	[[ -n "$url" ]] || fail "no LegacyScribe zip in that release."
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Downloading $(basename "$url")…"
curl -fL --progress-bar -o "$tmp/LegacyScribe.zip" "$url" || fail "download failed."
ditto -x -k "$tmp/LegacyScribe.zip" "$tmp/unzipped" || fail "couldn't unzip the download."
new="$tmp/unzipped/$app_name"
[[ -d "$new" ]] || fail "the download doesn't contain $app_name."

say "Checking the signature…"
codesign --verify --deep --strict "$new" 2>/dev/null || fail "the app's signature is broken; not installing."
got=$(codesign -dv "$new" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$got" == "$team" ]] || fail "the app is signed by team '$got', not LegacyScribe's ($team); not installing."

dest_dir="${LEGACYSCRIBE_DEST:-/Applications}"   # LEGACYSCRIBE_DEST: testing
[[ -w "$dest_dir" ]] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
dest="$dest_dir/$app_name"

if pgrep -xq LegacyScribe; then
	say "Quitting the running LegacyScribe…"
	osascript -e 'quit app "LegacyScribe"' >/dev/null 2>&1 || true
	for _ in $(seq 1 20); do pgrep -xq LegacyScribe || break; sleep 0.5; done
	pgrep -xq LegacyScribe && fail "LegacyScribe is still running; quit it and run this again."
fi

# Replace the old copy only once the new one is in place beside it.
ditto "$new" "$dest.new" || fail "couldn't copy into $dest_dir."
if [[ -d "$dest" ]]; then rm -rf "$dest"; fi
mv "$dest.new" "$dest"

version=$(defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "Installed LegacyScribe $version in $dest_dir. Opening it…"
open "$dest"
say "When asked, allow Microphone, Accessibility and Input Monitoring. Then hold Right ⌥, talk, and let go."
