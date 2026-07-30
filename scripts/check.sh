#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

"$repository_root/scripts/check-docs.sh"

cargo fmt \
  --manifest-path "$repository_root/core/Cargo.toml" \
  --all \
  --check

cargo clippy \
  --locked \
  --workspace \
  --all-targets \
  --manifest-path "$repository_root/core/Cargo.toml" \
  -- \
  -D warnings

"$repository_root/scripts/test.sh"
