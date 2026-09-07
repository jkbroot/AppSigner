#!/bin/bash
# Builds AppSigner and assembles a runnable macOS .app bundle (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "[+] Building ($CONFIG) …"
swift build -c "$CONFIG" >/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AppSigner"

APP="AppSigner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/AppSigner"

# App icon (generate if missing).
[ -f AppSigner.icns ] || { [ -f Scripts/make_icon.swift ] && swift Scripts/make_icon.swift >/dev/null && iconutil -c icns AppSigner.iconset -o AppSigner.icns; }
[ -f AppSigner.icns ] && cp AppSigner.icns "$APP/Contents/Resources/AppSigner.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AppSigner</string>
    <key>CFBundleDisplayName</key><string>AppSigner</string>
    <key>CFBundleIdentifier</key><string>com.jkbcoder.appsigner</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>AppSigner</string>
    <key>CFBundleIconFile</key><string>AppSigner</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "[+] Ad-hoc signing the app …"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "[*] Ready: $(pwd)/$APP"
