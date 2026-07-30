#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

required_commands=(cargo rustc swift xcodebuild rg git)

for required_command in "${required_commands[@]}"; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "missing required command: $required_command" >&2
    exit 1
  fi
done

host_architecture="$(uname -m)"
if [[ "$host_architecture" != "arm64" ]]; then
  echo "Zulip Mac currently requires an arm64 host; found $host_architecture" >&2
  exit 1
fi

echo "toolchain"
xcodebuild -version
swift --version
cargo --version
rustc --version
echo "bootstrap checks passed"
