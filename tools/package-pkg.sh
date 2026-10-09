#!/bin/bash
# Builds the Release app (signed with the identity in Local.xcconfig) and wraps it in an installer
# package that puts LegacyScribe.app in /Applications.
#
# Usage: tools/package-pkg.sh [output-dir]      (default: ~/Downloads)
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-$HOME/Downloads}"
flags=(-scheme Hex -configuration Release -destination 'platform=macOS,arch=arm64'
	-skipMacroValidation -skipPackagePluginValidation)

xcodebuild "${flags[@]}" build | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)" || true
products=$(xcodebuild "${flags[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')
app="$products/LegacyScribe.app"
codesign --verify --strict "$app"
version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/root"
ditto "$app" "$stage/root/LegacyScribe.app"

# Not relocatable: otherwise Installer updates whichever copy with this bundle ID it finds first
# (such as the build in DerivedData) instead of installing to /Applications.
pkgbuild --analyze --root "$stage/root" "$stage/components.plist" >/dev/null
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" "$stage/components.plist" >/dev/null 2>&1; do
	/usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$stage/components.plist"
	i=$((i + 1))
done

mkdir -p "$out"
pkg="$out/LegacyScribe-$version.pkg"
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
	--install-location /Applications \
	--identifier com.genovamongalo.LegacyScribe.pkg --version "$version" \
	"$pkg"
echo "$pkg"
