#!/bin/bash
# Build Jnobs.app — a double-clickable, menu-bar-only macOS app bundle.
# Usage: ./build_app.sh [--release] [--install] [--run]
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="debug"
DO_INSTALL=0
DO_RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --install) DO_INSTALL=1 ;;
    --run)     DO_RUN=1 ;;
  esac
done

# Regenerate app icon (.icns) — Swift-driven procedural rendering.
ICONSET="icon/Jnobs.iconset"
ICNS="icon/Jnobs.icns"
if [ ! -f "$ICNS" ] || [ icon/IconGen.swift -nt "$ICNS" ]; then
  echo "> Rendering app icon"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  swift icon/IconGen.swift "$ICONSET"
  iconutil -c icns -o "$ICNS" "$ICONSET"
  echo "OK Wrote $ICNS"
fi

echo "> Building ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
  swift build -c release
  BIN=".build/release/Jnobs"
else
  swift build
  BIN=".build/debug/Jnobs"
fi

APP="Jnobs.app"
echo "> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jnobs"
cp "$ICNS" "$APP/Contents/Resources/Jnobs.icns"

# Bundle the Lacquer display font used for the wordmark.
if [ -d "Resources/Fonts" ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Jnobs</string>
  <key>CFBundleDisplayName</key><string>Jnobs</string>
  <key>CFBundleIdentifier</key><string>net.jfound.jnobs</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Jnobs</string>
  <key>CFBundleIconFile</key><string>Jnobs</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSAudioCaptureUsageDescription</key><string>Jnobs taps app audio to control per-app volume and route it to different output devices.</string>
  <key>NSMicrophoneUsageDescription</key><string>Jnobs reads audio levels to control per-app volume.</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS will run it and Accessibility/Input-Monitoring grants stick.
echo "> Code-signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "OK Built $APP"

if [ "$DO_INSTALL" = "1" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/$APP"
  echo "OK Installed to $DEST/$APP"
fi

if [ "$DO_RUN" = "1" ]; then
  pkill -x Jnobs 2>/dev/null || true
  sleep 0.3
  if [ "$DO_INSTALL" = "1" ]; then
    open "$HOME/Applications/$APP"
  else
    open "$APP"
  fi
  echo "OK Launched"
fi
