#!/bin/bash
# Builds dist/Cairn.app (release build, icon, Info.plist, ad-hoc signed).
#
#   scripts/build-app.sh            build dist/Cairn.app
#   scripts/build-app.sh --install  also copy it to ~/Applications (no admin needed)
#
# Also puts the `cairn` CLI inside the bundle at Cairn.app/Contents/MacOS/cairn.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/Cairn.app"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CairnCore/Cairn.swift)"

echo "==> Building release binaries"
swift build -c release --product CairnApp
swift build -c release --product cairn
BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CairnApp" "$APP/Contents/MacOS/CairnApp"
cp "$BIN/cairn" "$APP/Contents/MacOS/cairn"

echo "==> Rendering icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN/CairnApp" --render-icon "$WORK/icon.png"
ICONSET="$WORK/Cairn.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Cairn.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cairn</string>
  <key>CFBundleDisplayName</key><string>Cairn</string>
  <key>CFBundleIdentifier</key><string>dev.cairn.Cairn</string>
  <key>CFBundleExecutable</key><string>CairnApp</string>
  <key>CFBundleIconFile</key><string>Cairn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, local use only)"
codesign --force --sign - "$APP/Contents/MacOS/cairn"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Cairn.app"
  cp -R "$APP" "$HOME/Applications/Cairn.app"
  echo "==> Installed to ~/Applications/Cairn.app"
fi

echo "Done: $APP"
