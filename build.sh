#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# Sign outside iCloud Documents; Finder can attach metadata while files sync.
stage=$(mktemp -d /private/tmp/meld-build.XXXXXX)
mkdir -p "$stage/Meld.app/Contents/MacOS" "$stage/Meld.app/Contents/Resources" /private/tmp/meld-swift-cache
swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/meld-swift-cache Sources/*.swift -o "$stage/Meld.app/Contents/MacOS/Meld"
cp Info.plist "$stage/Meld.app/Contents/Info.plist"
if [[ -f Resources/Meld.icns ]]; then cp Resources/Meld.icns "$stage/Meld.app/Contents/Resources/"; fi
codesign --force --sign - "$stage/Meld.app"
ditto --norsrc "$stage/Meld.app" Meld.app
echo "Signed app: $stage/Meld.app"
echo "Built Meld.app"
