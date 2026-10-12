#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configuration="${1:-release}"
release_tag="${2:-v0.1.0-alpha.1}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "usage: $0 [debug|release] [vMAJOR.MINOR.PATCH-SUFFIX]" >&2
  exit 64
fi

if [[ ! "$release_tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "invalid release tag: $release_tag" >&2
  exit 64
fi

artifact_version="${release_tag#v}"
bundle_version="${artifact_version%%-*}"
bundle_path="$repository_root/dist/Zulip Mac.app"
binary_path="$bundle_path/Contents/MacOS/ZulipMac"
dmg_path="$repository_root/dist/Zulip-Mac-$artifact_version-arm64.dmg"
checksum_path="$dmg_path.sha256"
staging_directory="$(mktemp -d /tmp/zulip-mac-dmg.XXXXXX)"

cleanup() {
  case "$staging_directory" in
    /tmp/zulip-mac-dmg.*|/private/tmp/zulip-mac-dmg.*)
      rm -rf -- "$staging_directory"
      ;;
  esac
}
trap cleanup EXIT

"$repository_root/scripts/package-app.sh" "$configuration" "$release_tag"

actual_version="$(
  plutil -extract CFBundleShortVersionString raw \
    -o - "$bundle_path/Contents/Info.plist"
)"
if [[ "$actual_version" != "$bundle_version" ]]; then
  echo "bundle version $actual_version does not match release $bundle_version" >&2
  exit 1
fi

actual_tag="$(
  plutil -extract ZulipReleaseTag raw \
    -o - "$bundle_path/Contents/Info.plist"
)"
if [[ "$actual_tag" != "$artifact_version" ]]; then
  echo "bundle release tag $actual_tag does not match $artifact_version" >&2
  exit 1
fi

actual_architectures="$(lipo -archs "$binary_path")"
if [[ "$actual_architectures" != "arm64" ]]; then
  echo "expected an arm64-only app, found: $actual_architectures" >&2
  exit 1
fi

codesign --verify --deep --strict "$bundle_path"

cp -R "$bundle_path" "$staging_directory/Zulip Mac.app"
ln -s /Applications "$staging_directory/Applications"

rm -f -- "$dmg_path" "$checksum_path"
hdiutil create \
  -quiet \
  -volname "Zulip Mac" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$dmg_path"
hdiutil verify "$dmg_path"

checksum="$(shasum -a 256 "$dmg_path" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$checksum" "$(basename "$dmg_path")" >"$checksum_path"

echo "$dmg_path"
echo "$checksum_path"
