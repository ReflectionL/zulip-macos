#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configuration="${1:-debug}"
cargo_arguments=(build --locked --workspace --manifest-path "$repository_root/core/Cargo.toml")

if [[ "$configuration" == "release" ]]; then
  cargo_arguments+=(--release)
elif [[ "$configuration" != "debug" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

cargo "${cargo_arguments[@]}"
