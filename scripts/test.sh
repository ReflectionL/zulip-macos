#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

"$repository_root/scripts/generate-bindings.sh" debug

cargo test \
  --locked \
  --workspace \
  --manifest-path "$repository_root/core/Cargo.toml"

swift test \
  --disable-sandbox \
  --package-path "$repository_root/app" \
  --arch arm64
