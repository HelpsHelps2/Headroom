#!/bin/bash
# End-to-end update test: an older signed build finds, downloads, verifies, and installs a newer one from a local appcast.
# Uses a separate bundle ID and state folder, so an installed Headroom is untouched. Needs the Developer ID certificate
# and the "headroom" update key (docs/releasing.md). Briefly shows a Headroom window. The first run may ask to let codesign
# and sign_update use their keys; choose Always Allow.
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
headroom_identity="${HEADROOM_SIGNING_IDENTITY:-Developer ID Application}"
bundle_id="io.github.helpshelps2.headroom.updatetest"
work="$(mktemp -d)"
port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
server_pid=""; app_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  pkill -f "$work/Headroom.app/Contents/MacOS/Headroom" 2>/dev/null || true
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "$work" "$HOME/Library/Caches/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id"
}
trap cleanup EXIT

build() {  # build number, destination
  HEADROOM_BUILD="$1" HEADROOM_BUNDLE_ID="$bundle_id" bash "$headroom_root/scripts/build-app.sh" debug >/dev/null
  local app="$headroom_root/dist/Headroom.app" sparkle="$headroom_root/dist/Headroom.app/Contents/Frameworks/Sparkle.framework"
  for target in "$app/Contents/MacOS/headroom-cli" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$app"; do
    codesign --force --options runtime --timestamp=none --sign "$headroom_identity" "$target" 2>/dev/null
  done
  mkdir -p "$2"; ditto "$app" "$2/Headroom.app"
}

echo "Building old (1000) and new (1001) copies"
build 1000 "$work"
build 1001 "$work/new"
mkdir -p "$work/site"
hdiutil create -quiet -volname Headroom -srcfolder "$work/new" -fs HFS+ -format UDZO "$work/site/Headroom.dmg"
signature="$("$headroom_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" --account headroom "$work/site/Headroom.dmg")"
cat > "$work/site/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Headroom</title>
<item><title>Test</title><sparkle:version>1001</sparkle:version><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:$port/Headroom.dmg" type="application/octet-stream" $signature/></item></channel></rss>
XML
(cd "$work/site" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & server_pid=$!

# An old last-check time makes the scheduled check run right after launch.
defaults write "$bundle_id" SULastCheckTime -date "2020-01-01 00:00:00 +0000"
echo "Launching the old copy"
HEADROOM_FEED_URL="http://127.0.0.1:$port/appcast.xml" HEADROOM_STATE_DIR="$work/state" \
  "$work/Headroom.app/Contents/MacOS/Headroom" >"$work/app.log" 2>&1 & app_pid=$!

for _ in $(seq 1 90); do
  sleep 2
  build_now="$(defaults read "$work/Headroom.app/Contents/Info" CFBundleVersion 2>/dev/null || true)"
  if [[ "$build_now" == 1001 ]]; then
    codesign --verify --deep --strict "$work/Headroom.app"
    echo "Updated: the app on disk is build $build_now and its signature verifies."
    exit 0
  fi
  # Installing waits until Headroom is in the background, as it would for a person using it.
  open -a Finder
done
echo "No update after 3 minutes. App log:" >&2; tail -20 "$work/app.log" >&2
exit 1
