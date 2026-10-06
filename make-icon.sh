#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p Resources /private/tmp/meld-icon.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" /private/tmp/meld-checks/icon.png --out "/private/tmp/meld-icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" /private/tmp/meld-checks/icon.png --out "/private/tmp/meld-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns /private/tmp/meld-icon.iconset -o Resources/Meld.icns
