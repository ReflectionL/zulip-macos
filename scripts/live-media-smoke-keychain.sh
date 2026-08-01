#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

server="${1:?usage: live-media-smoke-keychain.sh SERVER EMAIL}"
email="${2:?usage: live-media-smoke-keychain.sh SERVER EMAIL}"
account_id="${server%/}|${email}"
service="io.github.huahai.ZulipMac.api-key"

api_key="$(security find-generic-password -s "$service" -a "$account_id" -w)"
if [[ -z "$api_key" ]]; then
  echo "saved API key is empty" >&2
  exit 1
fi

printf '%s\n' "$api_key" | cargo run \
  --locked \
  --manifest-path "$repository_root/core/Cargo.toml" \
  -p zulip-core \
  --example live_media_smoke \
  -- \
  "$server" \
  "$email"

unset api_key
