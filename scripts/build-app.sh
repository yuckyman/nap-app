#!/usr/bin/env bash
# Builds build/Nap.app (release, ad-hoc signed).
#   ./scripts/build-app.sh            build
#   ./scripts/build-app.sh --install  also copy to /Applications
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Nap.app"

cd "$root"
swift build -c release --product NapApp
swift build -c release --product nap-swift
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/NapApp" "$app/Contents/MacOS/Nap"

icon_key=""
hero="$root/assets/nimslo-suns.svg"
if [[ -f "$hero" ]]; then
  tmp="$(mktemp -d)"
  if command -v rsvg-convert >/dev/null; then
    rsvg-convert -w 1024 -h 1024 "$hero" -o "$tmp/square.png"
  elif command -v magick >/dev/null; then
    magick -background none -resize 1024x1024 "$hero" "$tmp/square.png"
  else
    echo "need rsvg-convert or magick to rasterize the icon" >&2
    exit 1
  fi
  mkdir -p "$tmp/Nap.iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$tmp/square.png" --out "$tmp/Nap.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$tmp/square.png" --out "$tmp/Nap.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/Nap.iconset" -o "$app/Contents/Resources/Nap.icns"
  rm -rf "$tmp"
  icon_key="<key>CFBundleIconFile</key><string>Nap</string>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>nap</string>
  <key>CFBundleDisplayName</key><string>nap</string>
  <key>CFBundleIdentifier</key><string>com.yuckyman.nap</string>
  <key>CFBundleExecutable</key><string>Nap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NapDotEnvPath</key><string>$root/.env</string>
  $icon_key
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "built $app"
echo "cli:  $bin/nap-swift"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Nap.app
  cp -R "$app" /Applications/Nap.app
  echo "installed /Applications/Nap.app"
fi
