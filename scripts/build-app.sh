#!/bin/bash
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
headroom_configuration="${1:-debug}"
export CLANG_MODULE_CACHE_PATH="$headroom_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$headroom_root/.build/module-cache"
swift build --package-path "$headroom_root" -c "$headroom_configuration"
headroom_bin="$(swift build --package-path "$headroom_root" -c "$headroom_configuration" --show-bin-path)"
headroom_app="$headroom_root/dist/Headroom.app"
rm -rf "$headroom_app"
mkdir -p "$headroom_app/Contents/MacOS" "$headroom_app/Contents/Resources"
cp "$headroom_bin/Headroom" "$headroom_app/Contents/MacOS/Headroom"
cp "$headroom_bin/headroom-cli" "$headroom_app/Contents/MacOS/headroom-cli"
cp "$headroom_root/LICENSE" "$headroom_root/NOTICE" "$headroom_app/Contents/Resources/"

# The icon is drawn by the app itself so it stays in step with the interface.
headroom_iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$headroom_iconset"
"$headroom_bin/Headroom" --render-icon "$headroom_iconset/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$headroom_iconset/icon_512x512@2x.png" --out "$headroom_iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$headroom_iconset/icon_512x512@2x.png" --out "$headroom_iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$headroom_iconset" -o "$headroom_app/Contents/Resources/AppIcon.icns"

cat > "$headroom_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Headroom</string>
<key>CFBundleIdentifier</key><string>local.headroom.development</string>
<key>CFBundleName</key><string>Headroom</string>
<key>CFBundleDisplayName</key><string>Headroom</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Headroom contributors. Apache-2.0.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$headroom_app"
printf 'Built %s\n' "$headroom_app"
