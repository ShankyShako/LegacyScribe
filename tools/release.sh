#!/bin/bash
# Ships an update through Sparkle. The app's feed (SUFeedURL in Hex/Info.plist) is the appcast.xml
# attached to the latest GitHub release, so a release is: a signed zip of the app plus an appcast
# listing it, both uploaded to a release tagged v<version>.
#
# Usage: tools/release.sh <version>             bump, build, zip, write the appcast, commit and tag
#        tools/release.sh --publish <version>   push, then create the GitHub release (needs gh)
#
# Release notes are optional: write release-notes/<version>.md (see release-notes/TEMPLATE.md)
# before running; it may be left uncommitted, and goes into the release commit. The notes are
# shown in the app's update window and used as the GitHub release text.
#
# Updates are signed with the EdDSA key in the login Keychain (account below); its public half is
# SUPublicEDKey. Keep a copy (generate_keys --account <account> -x <file>): without the key, no
# installed copy will accept another update.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=ShankyShako/LegacyScribe
key_account=com.genovamongalo.LegacyScribe
feed="https://github.com/$repo/releases/latest/download/appcast.xml"
stage_root="$HOME/Library/Caches/LegacyScribe/releases"
pbxproj=Hex.xcodeproj/project.pbxproj

publish=false
if [[ "${1:-}" == "--publish" ]]; then
	publish=true
	shift
fi
version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 [--publish] <major.minor.patch>" >&2; exit 2; }
tag="v$version"
notes="release-notes/$version.md"
stage="$stage_root/$version"
zip="LegacyScribe-$version.zip"

if $publish; then
	command -v gh >/dev/null || { echo "gh is missing: brew install gh && gh auth login" >&2; exit 1; }
	git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "No tag $tag; run $0 $version first" >&2; exit 1; }
	[[ -f "$stage/$zip" && -f "$stage/appcast.xml" ]] || { echo "Nothing staged in $stage" >&2; exit 1; }
	git push origin HEAD "$tag"
	notes_args=(--notes "")
	[[ -f "$notes" ]] && notes_args=(--notes-file "$notes")
	# Created as a draft first, so "latest" never points at a release without its appcast.
	gh release create "$tag" "$stage/$zip" "$stage/appcast.xml" --repo "$repo" --verify-tag --draft \
		--title "LegacyScribe $version" "${notes_args[@]}"
	gh release edit "$tag" --repo "$repo" --draft=false --latest
	echo "Published. Feed: $feed"
	exit 0
fi

git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "Tag $tag already exists" >&2; exit 1; }
if [[ -n "$(git status --porcelain -- . ":(exclude)$notes")" ]]; then
	echo "Commit or stash your changes first (only $notes may be uncommitted)." >&2
	exit 1
fi
if [[ -f "$notes" && ! -s "$notes" ]]; then
	echo "$notes is empty; delete it to release without notes." >&2
	exit 1
fi

rm -rf "$stage"
mkdir -p "$stage"

# Start from the published appcast, so older entries keep their own download URLs.
status=$(curl -sL -o "$stage/appcast.xml" -w "%{http_code}" "$feed")
case "$status" in
	200) ;;
	404) rm -f "$stage/appcast.xml"; echo "No published appcast yet: this is the first release." ;;
	*) echo "Fetching $feed failed (HTTP $status)" >&2; exit 1 ;;
esac

# Sparkle compares CFBundleVersion, so the build number must go up on every release.
max_build() { grep -oE "$1" "$2" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }
build=$(max_build 'CURRENT_PROJECT_VERSION = [0-9]+' "$pbxproj")
published=$(max_build '<sparkle:version>[0-9]+' "$stage/appcast.xml" || true)
(( ${published:-0} > build )) && build=$published
build=$((build + 1))

trap 'git checkout -- "$pbxproj"' ERR
sed -i '' -E \
	-e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $build;/" \
	-e "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $version;/" \
	"$pbxproj"
echo "Building LegacyScribe $version ($build)…"

flags=(-scheme Hex -configuration Release -destination 'platform=macOS,arch=arm64'
	-skipMacroValidation -skipPackagePluginValidation)
xcodebuild "${flags[@]}" build | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)" || true
products=$(xcodebuild "${flags[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')
app="$products/LegacyScribe.app"
codesign --verify --deep --strict "$app"
[[ "$(defaults read "$app/Contents/Info" CFBundleVersion)" == "$build" ]] || { echo "Built app isn't build $build" >&2; false; }

sparkle_bin="${products%/Build/Products/*}/SourcePackages/artifacts/sparkle/Sparkle/bin"
public_key=$("$sparkle_bin/generate_keys" --account "$key_account" -p)
if [[ "$(defaults read "$app/Contents/Info" SUPublicEDKey)" != "$public_key" ]]; then
	echo "SUPublicEDKey in Hex/Info.plist doesn't match the Keychain key ($key_account)" >&2
	false
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$zip"
[[ -f "$notes" ]] && cp "$notes" "$stage/LegacyScribe-$version.md"
"$sparkle_bin/generate_appcast" --account "$key_account" --embed-release-notes --maximum-deltas 0 \
	--download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
	--link "https://github.com/$repo" "$stage"

# An unsigned entry would be rejected by every installed copy; catch it here instead.
item=$(awk -v b="<sparkle:version>$build</sparkle:version>" \
	'/<item>/ {buf = ""} {buf = buf $0 "\n"} /<\/item>/ && index(buf, b) {print buf}' "$stage/appcast.xml")
grep -q 'sparkle:edSignature=' <<<"$item" || { echo "The new appcast entry isn't signed" >&2; false; }
grep -q 'sparkle-signatures:' "$stage/appcast.xml" || { echo "The appcast itself isn't signed" >&2; false; }

trap - ERR
git add "$pbxproj"
[[ -f "$notes" ]] && git add "$notes"
git commit -q -m "LegacyScribe $version"
git tag -a "$tag" -m "LegacyScribe $version"
echo
echo "Staged in $stage. Install it here with: open \"$app\" (or tools/package-pkg.sh)."
echo "Publish with: $0 --publish $version"
