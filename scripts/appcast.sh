#!/bin/bash
# Writes dist/appcast.xml for a notarized DMG: the Sparkle feed installed copies read from
# https://github.com/HelpsHelps2/Headroom/releases/latest/download/appcast.xml.
# The EdDSA signature comes from the "headroom" key in the login keychain (see docs/releasing.md).
#   scripts/appcast.sh dist/Headroom-x.y.z-arm64.dmg
set -euo pipefail
headroom_root="$(cd "$(dirname "$0")/.." && pwd)"
headroom_dmg="$1"
headroom_version="$(tr -d '[:space:]' < "$headroom_root/VERSION")"
headroom_build="$(defaults read "$headroom_root/dist/Headroom.app/Contents/Info" CFBundleVersion)"
headroom_tools="$headroom_root/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$headroom_tools/sign_update" ]] || swift package --package-path "$headroom_root" resolve >/dev/null
headroom_signature="$("$headroom_tools/sign_update" --account headroom "$headroom_dmg")"

python3 -I - "$headroom_root" "$headroom_version" "$headroom_build" "$headroom_dmg" "$headroom_signature" <<'PY'
import html, os, re, sys
from email.utils import formatdate
root, version, build, dmg, signature = sys.argv[1:]
match = re.fullmatch(r'sparkle:edSignature="([^"]+)" length="(\d+)"', signature.strip())
if not match:
    sys.exit(f"Unexpected sign_update output: {signature}")
ed, length = match.groups()

notes, on = [], False
for line in open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8"):
    if line.startswith("## "):
        on = line.strip() == f"## {version}"
        continue
    if on and line.strip():
        notes.append(line.rstrip())
if not notes:
    sys.exit(f'Add a "## {version}" section to CHANGELOG.md.')

def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)

body, items = [], []
for line in notes:
    if line.startswith("- "):
        items.append(f"<li>{inline(line[2:])}</li>")
        continue
    if items:
        body.append("<ul>" + "".join(items) + "</ul>"); items = []
    body.append(f"<p>{inline(line)}</p>")
if items:
    body.append("<ul>" + "".join(items) + "</ul>")

name = os.path.basename(dmg)
url = f"https://github.com/HelpsHelps2/Headroom/releases/download/v{version}/{name}"
xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Headroom</title>
    <link>https://github.com/HelpsHelps2/Headroom</link>
    <item>
      <title>Headroom {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/HelpsHelps2/Headroom/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{"".join(body)}]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{ed}"/>
    </item>
  </channel>
</rss>
"""
open(os.path.join(root, "dist", "appcast.xml"), "w", encoding="utf-8").write(xml)
print(os.path.join(root, "dist", "appcast.xml"))
PY
