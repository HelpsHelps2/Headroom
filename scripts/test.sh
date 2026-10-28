#!/bin/bash
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$headroom_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$headroom_root/.build/module-cache"
swift test --package-path "$headroom_root"
