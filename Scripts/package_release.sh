#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"
export COPYFILE_DISABLE=1
"$ROOT/Scripts/package_app.sh" release
mkdir -p "$ROOT/dist"
NAME="MacSCP-${MARKETING_VERSION}-arm64"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/MacSCP.app" "$ROOT/dist/$NAME.zip"
STAGE=$(mktemp -d "$ROOT/build/dmg.XXXXXX")
IMAGE_WORK=$(mktemp -d "$ROOT/build/image.XXXXXX")
trap 'rm -rf "$STAGE" "$IMAGE_WORK"' EXIT
ditto "$ROOT/build/MacSCP.app" "$STAGE/MacSCP.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/使用说明.md"
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName MacSCP --format UDZO "$STAGE" "$IMAGE_WORK/$NAME.dmg"
else
    hdiutil create -volname MacSCP -srcfolder "$STAGE" -ov -format UDZO "$IMAGE_WORK/$NAME.dmg"
fi
mv -f "$IMAGE_WORK/$NAME.dmg" "$ROOT/dist/$NAME.dmg"
SOURCE_STAGE=$(mktemp -d "$ROOT/build/source.XXXXXX")
trap 'rm -rf "$STAGE" "$SOURCE_STAGE" "$IMAGE_WORK"' EXIT
mkdir -p "$SOURCE_STAGE/MacSCP"
for item in Package.swift Sources Tests Scripts Docs LICENSE NOTICE README.md version.env .gitignore; do
    cp -R "$ROOT/$item" "$SOURCE_STAGE/MacSCP/"
done
ditto -c -k --keepParent "$SOURCE_STAGE/MacSCP" "$ROOT/dist/MacSCP-${MARKETING_VERSION}-source.zip"
(cd "$ROOT/dist" && shasum -a 256 "$NAME.dmg" "$NAME.zip" "MacSCP-${MARKETING_VERSION}-source.zip" > SHA256SUMS)
echo "Release artifacts: $ROOT/dist"
