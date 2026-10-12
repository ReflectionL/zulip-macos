#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configuration="${1:-debug}"
release_tag="${2:-}"
"$repository_root/scripts/build-app.sh" "$configuration"

binary_path="$repository_root/app/.build/arm64-apple-macosx/$configuration/ZulipMac"
bundle_path="$repository_root/dist/Zulip Mac.app"
contents_path="$bundle_path/Contents"

rm -rf "$bundle_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/ZulipMac"
cp "$repository_root/app/Resources/Info.plist" "$contents_path/Info.plist"
if [[ -n "$release_tag" ]]; then
  # The in-app updater compares this full tag, which CFBundleShortVersionString
  # cannot carry because it drops prerelease suffixes.
  plutil -insert ZulipReleaseTag -string "${release_tag#v}" "$contents_path/Info.plist"
fi
cp "$repository_root/app/Resources/AppIcon.icns" "$contents_path/Resources/AppIcon.icns"

codesign --force --sign - "$bundle_path"
echo "$bundle_path"
