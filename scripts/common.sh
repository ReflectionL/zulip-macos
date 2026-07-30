#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_build_root="$repository_root/app/.build"

export CLANG_MODULE_CACHE_PATH="$swift_build_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_build_root/ModuleCache"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

mkdir -p "$CLANG_MODULE_CACHE_PATH"
