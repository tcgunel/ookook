#!/bin/bash
# Builds Ookook.app from the SwiftPM executable. Re-run after any source change.
set -euo pipefail
cd "$(dirname "$0")"

APP="Ookook"
BUNDLE="$APP.app"
CONTENTS="$BUNDLE/Contents"

echo "==> Building release binary"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH" "$CONTENTS/MacOS/$APP"
# The icon is committed as built art, not generated here: iconutil needs a full
# iconset and the source PNG, neither of which belongs in a build step.
if [[ -f "Resources/Ookook.icns" ]]; then
    cp "Resources/Ookook.icns" "$CONTENTS/Resources/Ookook.icns"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Ookook</string>
    <key>CFBundleDisplayName</key>        <string>Ookook</string>
    <key>CFBundleIdentifier</key>         <string>com.tolga.ookook</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleExecutable</key>         <string>Ookook</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>CFBundleIconFile</key>           <string>Ookook</string>
</dict>
PLIST
echo '</plist>' >> "$CONTENTS/Info.plist"

# Stable identity across rebuilds so macOS permission grants stick.
# NOTE: Ookook must NOT be sandboxed - a sandboxed app cannot spawn the user's
# shell or their dev tooling, which is the entire point of this program.
pick_identity() {
    local id
    id="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')"
    if [[ -n "$id" ]]; then echo "$id"; return; fi
    echo "-"
}
IDENTITY="$(pick_identity)"
echo "==> Signing with: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$BUNDLE" >/dev/null 2>&1 || \
    echo "   (codesign failed - the app will still run locally)"

echo ""
echo "Built ./$BUNDLE"
echo "Run it:  open -a \"\$PWD/$BUNDLE\" --args /path/to/your/project"
