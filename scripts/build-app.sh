#!/bin/bash
set -euo pipefail
burrow_root="$(cd "$(dirname "$0")/.." && pwd)"
burrow_configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$burrow_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$burrow_root/.build/module-cache"
swift build --package-path "$burrow_root" -c "$burrow_configuration"
burrow_bin="$(swift build --package-path "$burrow_root" -c "$burrow_configuration" --show-bin-path)"
burrow_app="$burrow_root/dist/Burrow.app"
mkdir -p "$burrow_app/Contents/MacOS" "$burrow_app/Contents/Resources"
cp "$burrow_bin/Burrow" "$burrow_app/Contents/MacOS/Burrow"
cp "$burrow_bin/burrow-worker" "$burrow_app/Contents/MacOS/burrow-worker"
cp "$burrow_root/LICENSE" "$burrow_root/NOTICE" "$burrow_app/Contents/Resources/"
cat > "$burrow_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Burrow</string>
<key>CFBundleIdentifier</key><string>local.burrow.development</string>
<key>CFBundleName</key><string>Burrow</string>
<key>CFBundleDisplayName</key><string>Burrow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Burrow contributors. Apache-2.0.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$burrow_app"
printf 'Built %s\n' "$burrow_app"
