#!/bin/bash
# Tags the current commit as v$(cat VERSION) and publishes the notarized DMG to GitHub Releases.
# Run scripts/release.sh first. Release notes come from the matching section of CHANGELOG.md.
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$headroom_root"
headroom_version="$(tr -d '[:space:]' < VERSION)"
headroom_tag="v$headroom_version"
headroom_dmg="dist/Headroom-$headroom_version-arm64.dmg"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first." >&2; exit 1; }
[[ -f "$headroom_dmg" ]] || { echo "Missing $headroom_dmg. Run scripts/release.sh." >&2; exit 1; }
grep -q "<sparkle:shortVersionString>$headroom_version<" dist/appcast.xml 2>/dev/null || { echo "dist/appcast.xml is missing or not for $headroom_version. Run scripts/release.sh." >&2; exit 1; }
xcrun stapler validate -q "$headroom_dmg" || { echo "$headroom_dmg is not notarized and stapled." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$headroom_tag" >/dev/null && { echo "$headroom_tag already exists." >&2; exit 1; }

headroom_notes="$(awk -v v="## $headroom_version" '$0 ~ "^## " { on = index($0, v) == 1; next } on' CHANGELOG.md)"
[[ -n "$headroom_notes" ]] || { echo "Add a \"## $headroom_version\" section to CHANGELOG.md." >&2; exit 1; }

git tag -a "$headroom_tag" -m "Headroom $headroom_version"
git push origin "$headroom_tag"
gh release create "$headroom_tag" "$headroom_dmg" "$headroom_dmg.sha256" dist/appcast.xml --title "Headroom $headroom_version" --notes "$headroom_notes"
