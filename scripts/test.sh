#!/bin/bash
set -euo pipefail
burrow_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$burrow_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$burrow_root/.build/module-cache"
swift test --package-path "$burrow_root"
