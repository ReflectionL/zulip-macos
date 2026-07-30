#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configuration="${1:-debug}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

"$repository_root/scripts/generate-bindings.sh" "$configuration"

swift build \
  --disable-sandbox \
  --package-path "$repository_root/app" \
  --configuration "$configuration" \
  --arch arm64
