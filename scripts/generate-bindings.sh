#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configuration="${1:-debug}"

if [[ "$configuration" == "release" ]]; then
  cargo_profile="release"
elif [[ "$configuration" == "debug" ]]; then
  cargo_profile="debug"
else
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

cargo_arguments=(
  build
  --locked \
  --manifest-path "$repository_root/core/Cargo.toml"
  -p zulip-ffi \
  --lib
)

if [[ "$configuration" == "release" ]]; then
  cargo_arguments+=(--release)
fi

cargo "${cargo_arguments[@]}"

library_path="$repository_root/core/target/$cargo_profile/libzulip_ffi.a"
generated_root="$repository_root/generated/uniffi"
swift_output="$generated_root/swift"
headers_output="$generated_root/headers"
swift_target="$repository_root/app/Sources/ZulipCoreBindings/Generated"
xcframework_target="$repository_root/app/Vendor/ZulipCoreFFI.xcframework"

rm -rf "$generated_root" "$swift_target" "$xcframework_target"
mkdir -p "$swift_output" "$headers_output" "$swift_target"

bindgen_command=(
  cargo run
  --locked
  --manifest-path "$repository_root/core/Cargo.toml"
  -p uniffi-bindgen-swift
  --
  --metadata-no-deps
  "$library_path"
)

cd "$repository_root/core"

"${bindgen_command[@]}" "$swift_output" --swift-sources
"${bindgen_command[@]}" "$headers_output" --headers
"${bindgen_command[@]}" \
  "$headers_output" \
  --modulemap \
  --module-name ZulipCoreFFI \
  --modulemap-filename module.modulemap

cp "$swift_output"/*.swift "$swift_target/"

mkdir -p "$(dirname "$xcframework_target")"
xcodebuild -create-xcframework \
  -library "$library_path" \
  -headers "$headers_output" \
  -output "$xcframework_target"

echo "generated Swift bindings and ZulipCoreFFI.xcframework"
