#!/bin/zsh
# Regenerates the app icon: SwiftUI draws the layers into Meld.icon, then
# Xcode's actool compiles Assets.car (Liquid Glass, macOS 26+) and the
# Meld.icns fallback for earlier systems, plus a favicon. Requires Xcode;
# build.sh does not.
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift -module-cache-path /private/tmp/meld-swift-cache Resources/IconArt.swift Resources/Meld.icon/Assets
out=$(mktemp -d /private/tmp/meld-icon.XXXXXX)
xcrun actool Resources/Meld.icon --compile "$out" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon Meld --output-partial-info-plist "$out/partial.plist" >/dev/null
cp "$out/Assets.car" "$out/Meld.icns" Resources/
# Dark rendering for project lists such as T3 Code's favicon.
"$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool" Resources/Meld.icon --export-image \
    --output-file Resources/favicon.png --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1 >/dev/null
sips -Z 256 Resources/favicon.png >/dev/null
