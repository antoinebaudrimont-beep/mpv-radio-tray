#!/bin/sh
set -eu
MACOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RADIO_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/radio-native-build.XXXXXX")
trap 'rm -rf "$RADIO_BUILD_DIR"' EXIT
trap 'exit 130' HUP INT TERM
export CLANG_MODULE_CACHE_PATH="$RADIO_BUILD_DIR/clang-cache"
# Compile directly with Command Line Tools; no package dependencies or Xcode required.
swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library \
    -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$RADIO_BUILD_DIR/module-cache" \
    -emit-library -static -emit-module -module-name RadioCore \
    -emit-module-path "$RADIO_BUILD_DIR/RadioCore.swiftmodule" \
    "$MACOS_DIR"/Sources/RadioCore/*.swift -o "$RADIO_BUILD_DIR/libRadioCore.a"
swiftc -swift-version 5 -warnings-as-errors -O -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$RADIO_BUILD_DIR/module-cache" \
    -I "$RADIO_BUILD_DIR" -L "$RADIO_BUILD_DIR" -lRadioCore \
    "$MACOS_DIR"/Sources/RadioMenuBar/*.swift -o "$RADIO_BUILD_DIR/RadioMenuBar"
APP="$MACOS_DIR/dist/MPV Radio Tray.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Replace the executable atomically rather than modifying an existing signed inode.
cp "$RADIO_BUILD_DIR/RadioMenuBar" "$APP/Contents/MacOS/RadioMenuBar.new"
strip -S "$APP/Contents/MacOS/RadioMenuBar.new"
mv -f "$APP/Contents/MacOS/RadioMenuBar.new" "$APP/Contents/MacOS/RadioMenuBar"
cp "$MACOS_DIR/Resources/stations.txt" "$APP/Contents/Resources/stations.txt"
# Package the source artwork with native macOS tools at standard and Retina sizes.
RADIO_ICONSET="$RADIO_BUILD_DIR/AppIcon.iconset"
mkdir -p "$RADIO_ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MACOS_DIR/Resources/AppIcon.png" \
        --out "$RADIO_ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$MACOS_DIR/Resources/AppIcon.png" \
        --out "$RADIO_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$RADIO_ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
sips -s format tiff -z 18 18 "$MACOS_DIR/Resources/MenuBarIconTemplate.png" \
    --out "$RADIO_BUILD_DIR/menu.tiff" >/dev/null
sips -s format tiff -z 36 36 "$MACOS_DIR/Resources/MenuBarIconTemplate.png" \
    --out "$RADIO_BUILD_DIR/menu@2x.tiff" >/dev/null
tiffutil -cathidpicheck "$RADIO_BUILD_DIR/menu.tiff" "$RADIO_BUILD_DIR/menu@2x.tiff" \
    -out "$APP/Contents/Resources/MenuBarIconTemplate.tiff"
cp "$MACOS_DIR/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
