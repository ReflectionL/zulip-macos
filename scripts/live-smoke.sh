#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

restore_terminal() {
  if [[ -t 0 ]]; then
    stty echo
  fi
}

if [[ -t 0 ]]; then
  stty -echo
  trap restore_terminal EXIT
fi

cargo run \
  --locked \
  --manifest-path "$repository_root/core/Cargo.toml" \
  -p zulip-core \
  --example live_smoke
