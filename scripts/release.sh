#!/bin/bash
# Builds a signed, notarized, stapled DMG in dist/. See docs/releasing.md.
#   scripts/release.sh            Developer ID signing and notarization
#   scripts/release.sh --unsigned ad-hoc DMG for testing the packaging only
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
headroom_version="$(tr -d '[:space:]' < "$headroom_root/VERSION")"
headroom_identity="${HEADROOM_SIGNING_IDENTITY:-Developer ID Application}"
headroom_profile="${HEADROOM_NOTARY_PROFILE:-headroom-notary}"
headroom_unsigned=false
[[ "${1:-}" == "--unsigned" ]] && headroom_unsigned=true

if ! $headroom_unsigned; then
  if ! security find-identity -v -p codesigning | grep -q "$headroom_identity"; then
    echo "No \"$headroom_identity\" certificate in the keychain. See docs/releasing.md, step 1." >&2; exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$headroom_profile" >/dev/null 2>&1; then
    echo "No notarytool keychain profile \"$headroom_profile\". See docs/releasing.md, step 2." >&2; exit 1
  fi
fi

bash "$headroom_root/scripts/build-app.sh" release
headroom_app="$headroom_root/dist/Headroom.app"
headroom_dmg="$headroom_root/dist/Headroom-$headroom_version-arm64.dmg"

if ! $headroom_unsigned; then
  # Inner code first, then the bundle. Hardened runtime and a secure timestamp are required for notarization.
  headroom_sparkle="$headroom_app/Contents/Frameworks/Sparkle.framework"
  for target in "$headroom_app/Contents/MacOS/headroom-cli" "$headroom_sparkle/Versions/B/Autoupdate" \
                "$headroom_sparkle/Versions/B/Updater.app" "$headroom_sparkle" "$headroom_app"; do
    codesign --force --options runtime --timestamp --sign "$headroom_identity" "$target"
  done
  codesign --verify --strict --verbose=2 "$headroom_app"
fi

# Branded installer window: background, icon layout, and volume icon come from scripts/dmg/.
headroom_venv="$headroom_root/.build/dmg-venv"
if [[ ! -x "$headroom_venv/bin/dmgbuild" ]]; then
  python3 -m venv "$headroom_venv"
  "$headroom_venv/bin/pip" install --quiet --disable-pip-version-check -r "$headroom_root/scripts/dmg/requirements.txt"
fi
rm -f "$headroom_dmg"
"$headroom_venv/bin/dmgbuild" -s "$headroom_root/scripts/dmg/settings.py" \
  -D app="$headroom_app" -D background="$headroom_root/scripts/dmg/background.png" \
  "Headroom $headroom_version" "$headroom_dmg" >/dev/null

if ! $headroom_unsigned; then
  codesign --force --timestamp --sign "$headroom_identity" "$headroom_dmg"
  xcrun notarytool submit "$headroom_dmg" --keychain-profile "$headroom_profile" --wait
  xcrun stapler staple "$headroom_dmg"
  xcrun stapler validate "$headroom_dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$headroom_dmg"
fi

(cd "$headroom_root/dist" && shasum -a 256 "$(basename "$headroom_dmg")" > "$(basename "$headroom_dmg").sha256")
# The update feed signs the final, stapled DMG.
$headroom_unsigned || bash "$headroom_root/scripts/appcast.sh" "$headroom_dmg" >/dev/null
printf 'Built %s\n' "$headroom_dmg"
