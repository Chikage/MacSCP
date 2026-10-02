#!/bin/bash
# Adapted from the macos-spm-app-packaging package_app.sh template.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"
CONF=${1:-release}
export COPYFILE_DISABLE=1
swift build -c "$CONF" --arch arm64 -Xswiftc -warnings-as-errors
BIN_DIR=$(swift build -c "$CONF" --arch arm64 --show-bin-path)
APP="$ROOT/build/$APP_NAME.app"
mkdir -p "$ROOT/build"
rm -rf "$APP"
HELPER="$APP/Contents/Helpers/MacSCPAskPass.app"
mkdir -p "$APP/Contents/MacOS" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources" "$APP/Contents/Resources"
cp "$BIN_DIR/MacSCP" "$APP/Contents/MacOS/MacSCP"
cp "$BIN_DIR/MacSCPAskPass" "$HELPER/Contents/MacOS/MacSCPAskPass"
chmod +x "$APP/Contents/MacOS/MacSCP" "$HELPER/Contents/MacOS/MacSCPAskPass"
for binary in "$APP/Contents/MacOS/MacSCP" "$HELPER/Contents/MacOS/MacSCPAskPass"; do
    if [[ $(lipo -archs "$binary") != arm64 ]]; then
        echo "Unexpected architecture: $binary" >&2
        exit 1
    fi
done
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/Scripts/render_icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
    swift -swift-version 6 "$ROOT/Scripts/render_icon.swift" "$ROOT/build"
    iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/build/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE.txt"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacSCP</string>
<key>CFBundleDisplayName</key><string>MacSCP</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>MacSCP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>LSRequiresNativeExecution</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
<key>NSHumanReadableCopyright</key><string>MacSCP contributors. GPL-3.0. See bundled NOTICE.</string>
</dict></plist>
PLIST
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacSCP Authentication</string>
<key>CFBundleIdentifier</key><string>app.macscp.MacSCP.AskPass</string>
<key>CFBundleExecutable</key><string>MacSCPAskPass</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
find "$APP" -name '._*' -delete
SIGN_ARGS=(--force --sign "${APP_IDENTITY:--}")
if [[ -n "${APP_IDENTITY:-}" ]]; then SIGN_ARGS+=(--timestamp --options runtime); fi
codesign "${SIGN_ARGS[@]}" "$HELPER"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built arm64 app: $APP"
