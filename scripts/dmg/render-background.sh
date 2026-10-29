#!/bin/bash
# Renders background.png and background@2x.png from background.html with headless Chrome.
# The PNGs are committed, so releases don't need Chrome or network access.
set -euo pipefail
cd "$(dirname "$0")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
for scale in 1 2; do
  out="background.png"; [[ $scale == 2 ]] && out="background@2x.png"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$scale \
    --window-size=640,400 --virtual-time-budget=5000 --screenshot="$PWD/$out" "file://$PWD/background.html" 2>/dev/null
  sips -g pixelWidth -g pixelHeight "$out" | tail -2 | tr -s ' ' | paste -sd' ' - | sed "s/^/$out:/"
done
